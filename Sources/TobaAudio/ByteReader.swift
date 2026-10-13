import Foundation

/// Which end of a multi-byte integer the file writes first.
enum ByteOrder: Sendable {
    /// Most significant byte first. FLAC, ID3 and MP4 write this way.
    case big
    /// Least significant byte first. ASF writes this way.
    case little
}

/// What a container walk does with a length the bytes cannot hold.
///
/// A read stops and keeps the structure it already has, because a partial tag beats none. A write
/// refuses, because rebuilding a file from a partial walk would drop every byte behind the length
/// that failed.
enum WalkStrictness: Sendable {
    case lenient
    case strict

    /// Throws in the strict case and answers false in the lenient one, so a walk writes the
    /// decision as one guard.
    func refuse(_ part: String) throws(AudioReadError) -> Bool {
        guard self == .strict else { return false }
        throw .malformed(part)
    }
}

extension String.Encoding {
    /// How many bytes one code unit takes, which is also the width of a null terminator.
    var unitWidth: Int {
        switch self {
            case .utf16, .utf16LittleEndian, .utf16BigEndian: 2
            default: 1
        }
    }
}

/// Reads integers and byte runs out of a buffer, refusing every read past its end.
///
/// The four container parsers sit on this. A truncated or hostile file throws
/// ``AudioReadError/malformed(_:)`` naming the structure that ran short, rather than trapping on an
/// index the buffer does not hold.
///
/// Every `part` argument is a string literal, so the label costs no allocation on the read path.
struct ByteReader {
    let bytes: Data

    /// How far into the buffer the next read starts.
    private(set) var offset: Int

    init(_ bytes: Data, offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var count: Int { bytes.count }

    var remaining: Int { max(0, count - offset) }

    var isAtEnd: Bool { remaining == 0 }

    // MARK: - Moving

    mutating func skip(_ distance: Int, _ part: String) throws(AudioReadError) {
        try seek(to: offset + distance, part)
    }

    mutating func seek(to target: Int, _ part: String) throws(AudioReadError) {
        guard target >= 0, target <= count else { throw .malformed(part) }
        offset = target
    }

    // MARK: - Reading

    mutating func read(_ length: Int, _ part: String) throws(AudioReadError) -> Data {
        guard length >= 0, length <= remaining else { throw .malformed(part) }
        let start = bytes.startIndex + offset
        offset += length
        return bytes[start..<(start + length)]
    }

    mutating func readUInt8(_ part: String) throws(AudioReadError) -> UInt8 {
        guard remaining >= 1 else { throw .malformed(part) }
        let byte = bytes[bytes.startIndex + offset]
        offset += 1
        return byte
    }

    mutating func readUInt16(
        _ order: ByteOrder,
        _ part: String
    ) throws(AudioReadError) -> UInt16 { try UInt16(readUInt(width: 2, order, part)) }

    mutating func readUInt32(
        _ order: ByteOrder,
        _ part: String
    ) throws(AudioReadError) -> UInt32 { try UInt32(readUInt(width: 4, order, part)) }

    mutating func readUInt64(
        _ order: ByteOrder,
        _ part: String
    ) throws(AudioReadError) -> UInt64 { try readUInt(width: 8, order, part) }

    /// Reads an integer of one to eight bytes, which FLAC and MP4 both need at odd widths.
    mutating func readUInt(
        width: Int,
        _ order: ByteOrder,
        _ part: String
    ) throws(AudioReadError) -> UInt64 {
        guard width > 0, width <= 8, width <= remaining else { throw .malformed(part) }
        let start = bytes.startIndex + offset
        var value: UInt64 = 0

        for step in 0..<width {
            let byte = UInt64(bytes[start + step])

            switch order {
                case .big: value = value << 8 | byte
                case .little: value |= byte << (8 * UInt64(step))
            }
        }
        offset += width
        return value
    }

    // MARK: - Text

    /// Reads `length` bytes as text, dropping the nulls and whitespace around it.
    mutating func readString(
        length: Int,
        encoding: String.Encoding,
        _ part: String
    ) throws(AudioReadError) -> String { try Self.string(read(length, part), encoding: encoding) }

    /// Reads text up to and past the null code unit that closes it.
    ///
    /// An ASF picture descriptor terminates its two strings rather than stating their lengths, so
    /// the read has to find each end itself.
    mutating func readTerminatedString(
        encoding: String.Encoding,
        _ part: String
    ) throws(AudioReadError) -> String {
        let width = encoding.unitWidth
        let start = bytes.startIndex + offset

        while remaining >= width {
            let unit = bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + width)]
            offset += width
            guard unit.allSatisfy({ $0 == 0 }) else { continue }
            return Self.string(
                bytes[start..<(bytes.startIndex + offset - width)], encoding: encoding)
        }
        throw .malformed(part)
    }

    /// Decodes `data` as text and trims the nulls and whitespace around it.
    ///
    /// A tagger pads a fixed-width field with nulls and terminates a variable-width one, so both
    /// arrive here carrying bytes no reader wants in a title. An undecodable run reads as empty.
    static func string(_ data: Data, encoding: String.Encoding) -> String {
        let read = resolve(encoding, in: data)
        let body = trimmingPadding(read.body, read.encoding)
        return String(data: body, encoding: read.encoding) ?? ""
    }

    /// Resolves an encoding that carries a byte-order mark into the explicit one it names.
    ///
    /// ID3 writes a mark in front of a UTF-16 frame. Reading it here lets the trim below work one
    /// code unit at a time, and it keeps the mark out of the decoded value.
    private static func resolve(
        _ encoding: String.Encoding,
        in data: Data
    ) -> (encoding: String.Encoding, body: Data) {
        guard encoding == .utf16, data.count >= 2 else { return (encoding, data) }
        let start = data.startIndex

        switch (data[start], data[start + 1]) {
            case (0xFF, 0xFE): return (.utf16LittleEndian, data[(start + 2)...])
            case (0xFE, 0xFF): return (.utf16BigEndian, data[(start + 2)...])
            // a run with no mark is big-endian, which is what the encoding names on its own
            default: return (.utf16BigEndian, data)
        }
    }

    /// Drops the nulls a tagger pads with and the ASCII whitespace around a value.
    ///
    /// Every tag value of every file reaches this, so the trim runs over the bytes. Trimming the
    /// decoded text costs a `CharacterSet` membership test per character, and it costs a second
    /// string whenever the decode leaves the text in the foreign representation.
    private static func trimmingPadding(_ data: Data, _ encoding: String.Encoding) -> Data {
        let width = encoding.unitWidth
        // an odd tail holds no code unit, and the decode refuses the whole run anyway
        guard data.count % width == 0 else { return data }
        let value = encoding == .utf16BigEndian ? 1 : 0

        var start = data.startIndex
        var end = data.endIndex

        while start < end, isPadding(data, at: end - width, width, value) { end -= width }
        while start < end, isPadding(data, at: start, width, value) { start += width }
        return data[start..<end]
    }

    /// Whether the code unit at `index` is padding a tagger wrote rather than part of the value.
    ///
    /// - Parameter value: which byte of a two-byte unit carries the value, which the endianness
    ///   decides
    private static func isPadding(_ data: Data, at index: Int, _ width: Int, _ value: Int) -> Bool {
        if width == 2, data[index + 1 - value] != 0 { return false }

        switch data[index + value] {
            case 0, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20: return true
            default: return false
        }
    }
}
