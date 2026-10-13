internal import Foundation

/// The media objects a fresh WMA v1 or v2 decoder can open a stream at, each with the frame a
/// straight read reaches there.
///
/// A super frame states how many frames it finishes, and each frame answers `frameLength` samples,
/// so a walk over the packet headers places every object exactly without decoding any audio.
struct WMASeekTable {
    struct Entry: Equatable {
        /// How many frames a straight read answers before this object.
        let position: Int64

        let start: ASFPacketPosition

        /// How many objects a walk resumed at `start` answers before this one.
        let skip: Int
    }

    let frameLength: Int
    let entries: [Entry]

    /// Walks every packet header. A noise-coded stream and one with no bit reservoir answer `nil`,
    /// because each carries state across frames that no header states.
    init?(bytes: Data, header: ASFHeaderInfo, decoder: WMADecoder) {
        let configuration = decoder.configuration
        guard configuration.options.usesBitReservoir, !configuration.usesNoiseCoding
        else { return nil }
        frameLength = configuration.frameLength

        var packets = ASFPacketReader(bytes: bytes, header: header)
        var found: [Entry] = []
        var position: Int64 = 0
        var empty = true
        var last: ASFPacketPosition?
        var skip = 0

        while let object = try? packets.next() {
            skip = object.start == last ? skip + 1 : 0
            last = object.start
            guard !object.bytes.isEmpty else { continue }
            guard let count = decoder.superFrameCount(object.bytes) else { break }
            // the encoder always leaves a frame's start in the tail, so only the first packet meets
            // an empty reservoir
            let frames = count - (empty ? 1 : 0)

            guard frames > 0 else {
                // the whole packet joins the reservoir
                empty = empty && object.bytes.count <= 1
                continue
            }
            // a fresh decoder holds a packet stating one frame as reservoir, so it opens nothing
            if !empty, count >= 2 {
                found.append(.init(position: position, start: object.start, skip: skip))
            }
            position += Int64(frames * frameLength)
            empty = false
        }
        entries = found
    }

    /// The last entry a fresh decode reaches `target` from. Its output starts one frame past the
    /// entry, and that first frame lacks the overlap of the frame before it, so it drops too.
    func entry(reaching target: Int64) -> Entry? {
        let reach = Int64(frameLength * 2)
        var low = 0
        var high = entries.count

        while low < high {
            let middle = (low + high) / 2

            if entries[middle].position + reach <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? entries[low - 1] : nil
    }
}

extension WMADecoder {
    /// The frame count a super frame's header states, or `nil` when the header does not fit the
    /// packet, which the decode refuses too.
    func superFrameCount(_ packet: Data) -> Int? {
        let offsetBits = configuration.byteOffsetBits + 3
        let headerBits = 8 + offsetBits
        guard packet.count * 8 >= headerBits else { return nil }
        let bytes = [UInt8](packet.prefix((headerBits + 7) / 8))
        var reader = BitReader(bytes.span)
        reader.skip(4)
        let count = Int(reader.read(4))
        let offset = Int(reader.read(offsetBits))
        return offset <= packet.count * 8 - headerBits ? count : nil
    }
}
