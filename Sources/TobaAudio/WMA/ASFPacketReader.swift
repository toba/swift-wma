internal import Foundation

/// One codec packet of an ASF stream, reassembled from the payloads that carry it.
struct ASFMediaObject: Equatable, Sendable {
    /// The object's number within its stream, which counts up and wraps at 256.
    var number: Int

    /// When the object presents, in milliseconds from the start of the file.
    var presentationTime: Int

    var bytes: Data

    /// The packet the object's first payload sits in, which a walk resumes at to reach it again.
    var start = ASFPacketPosition(offset: 0, index: 0)
}

/// Where one data packet starts, and its number among the data packets.
struct ASFPacketPosition: Equatable, Sendable {
    var offset: Int
    var index: Int
}

/// Walks the data packets of an ASF file and answers the media objects of one stream.
///
/// A packet carries one or more payloads, and a payload carries a whole media object or a fragment
/// of one. A fragmented object is held until its bytes are contiguous, so a caller always receives
/// a complete codec packet.
struct ASFPacketReader {
    private let bytes: Data
    private let header: ASFHeaderInfo

    /// Where the next packet starts.
    private var offset: Int

    /// How many packets the walk has read.
    private var packetsRead = 0

    /// The objects the last packet completed, oldest first.
    private var completed: [ASFMediaObject] = []

    /// The object still short of some of its payloads.
    private var partial: Partial?

    init(bytes: Data, header: ASFHeaderInfo) {
        self.bytes = bytes
        self.header = header
        offset = header.firstPacketOffset
    }

    /// Opens the walk at a packet an earlier walk reported, which drops the object it opens inside.
    init(bytes: Data, header: ASFHeaderInfo, resumingAt start: ASFPacketPosition) {
        self.bytes = bytes
        self.header = header
        offset = start.offset
        packetsRead = start.index
    }

    /// The next media object of the audio stream, or `nil` past the last packet.
    mutating func next() throws(AudioReadError) -> ASFMediaObject? {
        while completed.isEmpty {
            guard packetsRead < header.packetCount else { return nil }
            try readPacket()
            packetsRead += 1
        }
        return completed.removeFirst()
    }

    // MARK: - One packet

    private mutating func readPacket() throws(AudioReadError) {
        var reader = ByteReader(bytes, offset: offset)
        var flags = try reader.readUInt8("ASF packet flags")

        // the leading byte belongs to the error correction data when it marks that data present,
        // and the payload parsing information then starts behind it
        if flags & 0x80 != 0 {
            guard flags & 0x60 == 0 else { throw .malformed("ASF error correction length type") }
            try reader.skip(Int(flags & 0x0F), "ASF error correction data")
            flags = try reader.readUInt8("ASF packet flags")
        }

        let properties = try reader.readUInt8("ASF packet property flags")
        let stated = try reader.readField((flags >> 5).asfFieldWidth, "ASF packet length")
        _ = try reader.readField((flags >> 1).asfFieldWidth, "ASF packet sequence")
        let padding = try reader.readField((flags >> 3).asfFieldWidth, "ASF packet padding length")
        try reader.skip(6, "ASF packet send time and duration")

        let size = stated > 0 ? stated : header.packetSize
        guard size > 0, offset + size <= bytes.count else { throw .malformed("ASF packet length") }
        let end = offset + size - padding
        guard end >= reader.offset else { throw .malformed("ASF packet padding length") }

        var count = 1
        var lengthWidth = 0

        if flags & 0x01 != 0 {
            let payloadFlags = try reader.readUInt8("ASF payload flags")
            count = Int(payloadFlags & 0x3F)
            lengthWidth = (payloadFlags >> 6).asfFieldWidth
        }

        var index = 0

        while index < count, reader.offset < end {
            try readPayload(&reader, properties, lengthWidth, end)
            index += 1
        }
        offset += size
    }

    // MARK: - One payload

    /// - Parameters:
    ///   - lengthWidth: how many bytes state the payload's own length, which is zero when the
    ///     packet carries a single payload that runs to the padding
    ///   - end: where the payload data stops, which is the packet's end less its padding
    private mutating func readPayload(
        _ reader: inout ByteReader,
        _ properties: UInt8,
        _ lengthWidth: Int,
        _ end: Int
    ) throws(AudioReadError) {
        guard (properties >> 6).asfFieldWidth == 1 else {
            throw .malformed("ASF stream number width")
        }
        let numbered = try reader.readUInt8("ASF payload stream number")
        let number = try reader.readField(
            (properties >> 4).asfFieldWidth, "ASF media object number")
        let start = try reader.readField((properties >> 2).asfFieldWidth, "ASF media object offset")
        let replicated = try reader.readField(
            properties.asfFieldWidth, "ASF replicated data length")

        // a replicated run of one byte marks a payload holding several compressed objects at once,
        // which an audio stream never writes
        guard replicated >= 8 else { throw .malformed("ASF replicated data length") }

        let total = try Int(reader.readUInt32(.little, "ASF media object size"))
        let time = try Int(reader.readUInt32(.little, "ASF media object presentation time"))
        try reader.skip(replicated - 8, "ASF replicated data")

        var length = end - reader.offset

        if lengthWidth > 0 { length = try reader.readField(lengthWidth, "ASF payload length") }
        guard length >= 0, reader.offset + length <= end
        else { throw .malformed("ASF payload length") }
        let body = try reader.read(length, "ASF payload data")

        guard Int(numbered & 0x7F) == header.streamNumber else { return }
        append(body, number: number, at: start, of: total, presentingAt: time)
    }

    /// Files one payload against the object it belongs to, and completes that object once its last
    /// fragment arrives.
    ///
    /// A fragment whose start matches no held object drops the hold. That happens when a walk opens
    /// partway through an object, which a seek into the middle of the data does.
    private mutating func append(
        _ body: Data,
        number: Int,
        at start: Int,
        of total: Int,
        presentingAt time: Int
    ) {
        if start == 0 {
            partial = Partial(
                number: number, presentationTime: time, total: total, bytes: body,
                start: .init(offset: offset, index: packetsRead))
        } else if var held = partial, held.number == number, held.bytes.count == start {
            held.bytes.append(body)
            partial = held
        } else {
            partial = nil
            return
        }

        guard let held = partial, held.bytes.count >= held.total else { return }
        completed.append(.init(
            number: held.number, presentationTime: held.presentationTime, bytes: held.bytes,
            start: held.start))
        partial = nil
    }

    /// A media object whose payloads have not all arrived.
    private struct Partial {
        let number: Int
        let presentationTime: Int
        let total: Int
        var bytes: Data
        let start: ASFPacketPosition
    }
}

// MARK: - The ASF length types

private extension UInt8 {
    /// The byte width the low two bits name, which ASF calls a length type.
    ///
    /// A caller shifts the flags byte down so the type it wants lands in those two bits.
    var asfFieldWidth: Int {
        switch self & 0x03 {
            case 1: 1
            case 2: 2
            case 3: 4
            default: 0
        }
    }
}

private extension ByteReader {
    /// Reads a little-endian field of one, two or four bytes.
    ///
    /// A width of zero reads nothing and answers zero, which is what an absent field means.
    mutating func readField(_ width: Int, _ part: String) throws(AudioReadError) -> Int {
        guard width > 0 else { return 0 }
        return try Int(readUInt(width: width, .little, part))
    }
}
