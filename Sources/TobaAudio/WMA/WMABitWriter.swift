internal import Foundation

/// Writes bits most significant first, as FFmpeg's `PutBitContext` does, into bytes a ``BitReader``
/// reads back.
///
/// The bits below the last one written read as zero, so the bytes always form a whole stream.
struct WMABitWriter {
    /// Whether a reset keeps the bytes behind the next write, as FFmpeg's WMA Lossless `frame_data`
    /// does, which no save clears.
    let retainsBytes: Bool

    private(set) var bytes: [UInt8] = []

    /// How many bits the writer holds.
    private(set) var count = 0

    mutating func reset() {
        if !retainsBytes { bytes.removeAll(keepingCapacity: true) }
        count = 0
    }

    /// Writes the low `width` bits of `value`, zero to 32.
    mutating func write(_ value: UInt32, width: Int) {
        guard width > 0 else { return }
        var left = width
        let used = count & 7

        if used != 0 {
            let taken = min(8 - used, left)
            let chunk = (value >> (left - taken)) & ((1 << taken) - 1)
            bytes[count >> 3] |= UInt8(truncatingIfNeeded: chunk << (8 - used - taken))
            left -= taken
        }
        var index = (count + 7) >> 3

        while left >= 8 {
            left -= 8
            put(UInt8(truncatingIfNeeded: value >> left), at: index)
            index += 1
        }
        if left > 0 { put(UInt8(truncatingIfNeeded: value << (8 - left)), at: index) }
        count += width
    }

    /// Copies `length` bits of `source` from the byte at `start`, reading zero past its end.
    ///
    /// Each whole byte lands in one step, and a byte that straddles the writer's boundary splits
    /// across two.
    mutating func copy(_ source: Span<UInt8>, fromByte start: Int, bits length: Int) {
        guard length > 0 else { return }
        let whole = length >> 3
        let shift = count & 7
        var index = (count + 7) >> 3
        bytes.reserveCapacity(index + whole + 1)

        for offset in start..<(start + whole) {
            let byte = Self.byte(source, offset)

            if shift == 0 {
                put(byte, at: index)
            } else {
                bytes[index - 1] |= byte >> shift
                put(byte << (8 - shift), at: index)
            }
            index += 1
        }
        count += whole * 8

        let rest = length & 7
        if rest > 0 { write(UInt32(Self.byte(source, start + whole) >> (8 - rest)), width: rest) }
    }

    /// Starts the byte at `index`, which is either the next one the storage holds or one past it.
    private mutating func put(_ byte: UInt8, at index: Int) {
        if index < bytes.count { bytes[index] = byte } else { bytes.append(byte) }
    }

    private static func byte(_ source: Span<UInt8>, _ index: Int) -> UInt8 {
        index >= 0 && index < source.count ? source[index] : 0
    }
}

extension WMABitWriter {
    init(retainsBytes: Bool = false) { self.retainsBytes = retainsBytes }
}
