internal import Foundation

/// The frame bits a WMA Pro or Lossless stream carries from one packet into the next.
///
/// A frame may start in one packet and end in the next. This holds the part FFmpeg's `wmaprodec.c`
/// and `wmalosslessdec.c` share: the packet state `decode_packet` keeps and the copy `save_bits`
/// makes.
struct WMAFrameReservoir {
    /// Which of the two FFmpeg decoders a stream follows where their packet walks part.
    enum Codec { case pro, lossless }

    let codec: Codec
    let blockAlign: Int
    let log2FrameSize: Int
    let hasLengthPrefix: Bool
    let maximumFrameBytes: Int

    // MARK: - The packet state

    var packetSequenceNumber = 0

    /// The bit position within its first byte where the next pass resumes the packet.
    var packetOffset = 0

    /// How many bytes of the media object lie past the packet a header pass opened.
    var nextPacketStart = 0

    var packetLoss = true
    var packetDone = false

    // MARK: - The frame bits

    /// The frame bits, which the frame reader reads from ``cursor``.
    ///
    /// A Lossless writer keeps what an earlier save left behind the current one. A frame the stream
    /// cuts short reads into those bytes, and FFmpeg's output for that frame depends on them.
    private(set) var bits: WMABitWriter

    /// How many bits of ``bits`` the frames still to decode hold, FFmpeg's `num_saved_bits`.
    var savedBits = 0

    /// How many bits the frame reader holds, which a save sets and a drain leaves alone.
    var readerSize = 0

    /// Where the frame starts, within the first byte of ``bits``.
    private(set) var frameOffset = 0

    /// The frame reader's position, which outlives one packet.
    var cursor = 0

    init(
        codec: Codec,
        blockAlign: Int,
        log2FrameSize: Int,
        hasLengthPrefix: Bool,
        maximumFrameBytes: Int
    ) {
        self.codec = codec
        self.blockAlign = blockAlign
        self.log2FrameSize = log2FrameSize
        self.hasLengthPrefix = hasLengthPrefix
        self.maximumFrameBytes = maximumFrameBytes
        bits = WMABitWriter(retainsBytes: codec == .lossless)
    }

    /// Returns to the state a fresh open leaves, which waits for the next packet header.
    mutating func reset() {
        packetSequenceNumber = 0
        packetOffset = 0
        nextPacketStart = 0
        packetLoss = true
        packetDone = false
        bits.reset()
        savedBits = 0
        readerSize = 0
        frameOffset = 0
        cursor = 0
    }

    /// Moves `count` bits from the packet into the reservoir, as FFmpeg's `save_bits` does.
    ///
    /// A fresh save copies from the byte holding the cursor, so the frame starts at the cursor's
    /// bit within that byte. An appended run first reaches the packet's next byte boundary.
    @_lifetime(reader: copy reader)
    mutating func save(
        _ reader: inout BitReader,
        from data: Span<UInt8>,
        count: Int,
        appending: Bool
    ) {
        if !appending {
            frameOffset = reader.cursor & 7
            savedBits = frameOffset
            bits.reset()
        }
        let needed =
            switch codec {
                case .pro: ((appending ? bits.count : savedBits) + count + 7) >> 3
                case .lossless: (savedBits + count + 8) >> 3
            }
        guard count > 0, needed <= maximumFrameBytes else {
            packetLoss = true
            if codec == .lossless { savedBits = 0 }
            return
        }
        savedBits += count
        var left = count

        if appending {
            let align = min(8 - (reader.cursor & 7), count)
            bits.write(reader.read(align), width: align)
            left -= align
            bits.copy(data, fromByte: reader.cursor >> 3, bits: left)
        } else {
            bits.copy(data, fromByte: reader.cursor >> 3, bits: savedBits)
        }
        reader.skip(left)
        readerSize = savedBits
        cursor = frameOffset
    }
}

/// A WMA Pro or Lossless decoder, whose frames run over a ``WMAFrameReservoir``.
protocol WMAReservoirDecoding: AnyObject {
    var reservoir: WMAFrameReservoir { get set }

    /// Decodes the frame at the reservoir's cursor, FFmpeg's `decode_frame`, and answers whether
    /// that returned nonzero.
    func decodeReservoirFrame() -> Bool
}

extension WMAReservoirDecoding {
    /// One call of FFmpeg's `decode_packet` over the bytes from `start`, which decodes at most one
    /// frame.
    ///
    /// - Returns: how many bytes the pass read, or `nil` when the pass lost the packet
    func decodePacketPass(_ bytes: Span<UInt8>, from start: Int) -> Int? {
        let available = bytes.count - start
        let headerPass = reservoir.packetDone || reservoir.packetLoss
        let limit: Int

        if headerPass {
            reservoir.packetDone = false

            if reservoir.codec == .pro, available < reservoir.blockAlign {
                reservoir.packetLoss = true
                return nil
            }
            limit = min(reservoir.blockAlign, available)
            reservoir.nextPacketStart = available - limit
        } else {
            guard available >= reservoir.nextPacketStart else {
                reservoir.packetLoss = true
                return nil
            }
            limit = available - reservoir.nextPacketStart
        }
        let data = bytes.extracting(start..<(start + limit))
        let end = limit * 8
        var reader = BitReader(data)

        if headerPass {
            readPacketHeader(&reader, data, end: end)
        } else {
            reader.skip(reservoir.packetOffset)
            readPacketBody(&reader, data, end: end)
        }

        let left = end - reader.cursor
        if left < 0 { reservoir.packetLoss = true }

        if reservoir.packetDone, !reservoir.packetLoss, left > 0 {
            reservoir.save(&reader, from: data, count: left, appending: false)
        }
        reservoir.packetOffset = reader.cursor & 7
        return reservoir.packetLoss ? nil : reader.cursor >> 3
    }

    /// Reads a packet's header and finishes the frame the packet before it began.
    @_lifetime(reader: copy reader)
    private func readPacketHeader(_ reader: inout BitReader, _ data: Span<UInt8>, end: Int) {
        let sequence = Int(reader.read(4))
        // the seekable frame flag and the splice flag, which no decode step reads
        reader.skip(2)
        var carried = Int(reader.read(reservoir.log2FrameSize))

        if !reservoir.packetLoss, (reservoir.packetSequenceNumber + 1) & 0xF != sequence {
            reservoir.packetLoss = true
        }
        reservoir.packetSequenceNumber = sequence

        if carried > 0 {
            let remaining = end - reader.cursor

            if carried >= remaining {
                carried = remaining
                reservoir.packetDone = true
            }
            reservoir.save(&reader, from: data, count: carried, appending: true)

            // Lossless decodes the joined frame only when this packet finishes it
            if !reservoir.packetLoss, reservoir.codec == .pro || carried < remaining {
                _ = decodeReservoirFrame()
            }
        }
        if reservoir.packetLoss {
            // a frame the loss cut short never decodes, so its bits leave the reservoir
            reservoir.savedBits = 0
            reservoir.packetLoss = false
            if reservoir.codec == .lossless { reservoir.dropBits() }
        }
    }

    /// Decodes the next whole frame the packet carries.
    @_lifetime(reader: copy reader)
    private func readPacketBody(_ reader: inout BitReader, _ data: Span<UInt8>, end: Int) {
        let lengthBits = reservoir.log2FrameSize

        if reservoir.hasLengthPrefix, end - reader.cursor > lengthBits {
            let length = Int(reader.peek(lengthBits))

            if length > 0, length <= end - reader.cursor {
                reservoir.save(&reader, from: data, count: length, appending: false)
                guard !reservoir.packetLoss else { return }
                let more = decodeReservoirFrame()
                reservoir.packetDone = !more
                return
            }
        } else if !reservoir.hasLengthPrefix, reservoir.savedBits > reservoir.cursor {
            let more = decodeReservoirFrame()
            reservoir.packetDone = !more
            return
        }
        reservoir.packetDone = true
    }
}

extension WMAFrameReservoir {
    /// Empties the frame bits without touching the packet state.
    mutating func dropBits() { bits.reset() }
}
