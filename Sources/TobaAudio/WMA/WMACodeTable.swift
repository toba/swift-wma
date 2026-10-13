internal import Foundation

/// A variable length code table, read most significant bit first, which every WMA codec reads.
///
/// A lookup walks one table level at a time, and a code no entry owns answers minus one, as
/// FFmpeg's `get_vlc2` does. The table builds from explicit codes or from lengths in FFmpeg's
/// order.
struct WMACodeTable: Sendable {
    /// How many bits the first level indexes.
    static let levelBits = 9

    /// Each slot's symbol above its length, one byte wide.
    ///
    /// A negative length is the width of a next level, whose slots start at the symbol. A length of
    /// zero marks a code no entry owns, and its symbol is minus one.
    private let entries: [Int32]

    private let rootBits: Int

    /// Builds the table from a code per entry.
    ///
    /// - Parameters:
    ///   - codes: each code right aligned within its own length
    ///   - lengths: each code's length, zero for an entry the table omits
    ///   - symbols: what each code decodes to before `offset`. The entry's index stands in for
    ///     `nil`.
    ///   - offset: what every symbol takes on, which FFmpeg applies at build time
    init?(
        codes: [UInt32],
        lengths: [UInt8],
        symbols: [Int]? = nil,
        offset: Int = 0,
        rootBits: Int = WMACodeTable.levelBits
    ) {
        guard codes.count == lengths.count, lengths.allSatisfy({ $0 <= 32 }) else { return nil }
        let aligned = zip(codes, lengths).map { code, length in
            length == 0 ? 0 : code << (32 - UInt32(length))
        }
        self.init(
            aligned: aligned, lengths: lengths, symbols: symbols, offset: offset,
            rootBits: rootBits)
    }

    /// Builds the table from lengths alone, each entry in list order taking the next code of its
    /// length, as FFmpeg's `ff_vlc_init_from_lengths` does.
    init?(
        lengths: [UInt8],
        symbols: [Int]? = nil,
        offset: Int = 0,
        rootBits: Int = WMACodeTable.levelBits
    ) {
        guard let codes = Self.codes(lengths: lengths) else { return nil }
        self.init(
            aligned: codes, lengths: lengths, symbols: symbols, offset: offset, rootBits: rootBits)
    }

    private init?(
        aligned codes: [UInt32],
        lengths: [UInt8],
        symbols: [Int]?,
        offset: Int,
        rootBits: Int
    ) {
        guard lengths.contains(where: { $0 > 0 }),
              symbols.map({ $0.count == lengths.count }) ?? true else { return nil }
        var entries: [Entry] = []

        for index in lengths.indices where lengths[index] > 0 {
            let symbol = (symbols?[index] ?? index) + offset
            entries.append(.init(code: codes[index], length: Int(lengths[index]), symbol: symbol))
        }
        entries.sort { $0.code < $1.code }

        var built: [Int32] = []
        guard Self.build(entries[...], bits: rootBits, into: &built) else { return nil }
        self.entries = built
        self.rootBits = rootBits
    }

    /// The code each length takes, left aligned in 32 bits, or `nil` when the lengths overfill the
    /// code space.
    static func codes(lengths: [UInt8]) -> [UInt32]? {
        var codes = [UInt32](repeating: 0, count: lengths.count)
        var next: UInt64 = 0

        for (index, length) in lengths.enumerated() where length > 0 {
            let width = Int(length)
            guard width <= 32, next & ((1 << (32 - width)) - 1) == 0 else { return nil }
            codes[index] = UInt32(truncatingIfNeeded: next)
            next += 1 << (32 - width)
            guard next <= 1 << 32 else { return nil }
        }
        return codes
    }

    // MARK: - Reading

    /// The symbol the bits at the cursor name, or minus one when they name none.
    @inline(always)
    @_lifetime(reader: copy reader)
    func symbol(from reader: inout BitReader) -> Int {
        var width = rootBits
        var entry = entries[Int(reader.peek(width))]
        var length = Int(Int8(truncatingIfNeeded: entry))

        while length < 0 {
            reader.skip(width)
            width = -length
            entry = entries[Int(entry >> 8) + Int(reader.peek(width))]
            length = Int(Int8(truncatingIfNeeded: entry))
        }
        reader.skip(length)
        return Int(entry >> 8)
    }

    // MARK: - Building

    private struct Entry {
        var code: UInt32
        var length: Int
        let symbol: Int
    }

    private static func entry(symbol: Int, length: Int) -> Int32 {
        Int32(truncatingIfNeeded: symbol) << 8 | Int32(UInt8(bitPattern: Int8(length)))
    }

    /// Appends one level of `1 << bits` slots and every level under it.
    ///
    /// A code longer than the level shares a next level with each code of the same prefix, which
    /// FFmpeg sizes to the longest remainder and never wider than the level itself.
    private static func build(
        _ codes: ArraySlice<Entry>,
        bits: Int,
        into entries: inout [Int32]
    ) -> Bool {
        let base = entries.count
        entries.append(contentsOf: repeatElement(entry(symbol: -1, length: 0), count: 1 << bits))
        var index = codes.startIndex

        while index < codes.endIndex {
            let code = codes[index]
            let slot = Int(code.code >> (32 - bits))

            if code.length <= bits {
                let filled = entry(symbol: code.symbol, length: code.length)
                for step in 0..<(1 << (bits - code.length)) { entries[base + slot + step] = filled }
                index += 1
                continue
            }
            var group: [Entry] = []
            var widest = 0

            while index < codes.endIndex {
                let member = codes[index]
                guard member.length > bits, Int(member.code >> (32 - bits)) == slot else { break }
                let rest = member.length - bits
                group.append(.init(code: member.code << bits, length: rest, symbol: member.symbol))
                widest = max(widest, rest)
                index += 1
            }
            let width = min(widest, bits)
            entries[base + slot] = entry(symbol: entries.count, length: -width)
            guard build(group[...], bits: width, into: &entries) else { return false }
        }
        return true
    }
}
