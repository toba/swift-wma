internal import Foundation

/// Reads a big-endian bit stream, which is how WMA writes every field.
///
/// The reader borrows its bytes and keeps an integer bit cursor, so nothing here allocates or
/// retains. A read refills a 64-bit window with one unaligned load, which makes a field of up to 32
/// bits cost a shift and a mask.
///
/// ```swift
/// var reader = BitReader(frame.span)
/// let blockSize = reader.read(2)
/// ```
///
/// A read past the end answers zero rather than trapping. A caller checks ``isOverrun`` once it
/// finishes a frame, because a corrupt stream is otherwise indistinguishable from a short one.
struct BitReader: ~Copyable, ~Escapable {
    private let bytes: Span<UInt8>

    /// How many bits the reader has consumed.
    private(set) var cursor: Int

    /// The bit the cursor never moves past, so every read beyond it answers the same bits.
    private let limit: Int

    /// The reader inherits the input's own lifetime rather than borrowing the parameter, which dies
    /// at the end of this initializer.
    ///
    /// - Parameter limit: where the cursor stops, as FFmpeg's checked reader stops 8 bits past the
    ///   end it was given. The default never stops.
    @_lifetime(copy input)
    init(_ input: Span<UInt8>, cursor: Int = 0, limit: Int = .max) {
        bytes = copy input
        self.cursor = cursor
        self.limit = limit
    }

    /// How many bits the bytes hold.
    var count: Int { @inline(always) get { bytes.count &* 8 } }

    /// How many bits sit in front of the cursor, which is negative once a read runs past the end.
    var remaining: Int { @inline(always) get { count &- cursor } }

    /// Whether a read ran past the last bit, so every field behind it is zero rather than decoded.
    var isOverrun: Bool { @inline(always) get { cursor > count } }

    // MARK: - Moving

    @inline(always)
    @_lifetime(self: copy self)
    mutating func skip(_ width: Int) { cursor = min(cursor &+ width, limit) }

    @inline(always)
    @_lifetime(self: copy self)
    mutating func seek(toBit bit: Int) { cursor = min(bit, limit) }

    /// Moves the cursor to the next byte boundary.
    @inline(always)
    @_lifetime(self: copy self)
    mutating func align() { cursor = min((cursor &+ 7) & ~7, limit) }

    // MARK: - Reading

    /// Reads `width` bits, most significant first.
    ///
    /// - Parameter width: zero to 32. A wider field reads in two calls.
    @inline(always)
    @_lifetime(self: copy self)
    mutating func read(_ width: Int) -> UInt32 {
        let value = peek(width)
        cursor = min(cursor &+ width, limit)
        return value
    }

    /// The next `width` bits, leaving the cursor where it sits.
    @inline(always)
    func peek(_ width: Int) -> UInt32 {
        guard width > 0 else { return 0 }
        let window = window(at: cursor &>> 3)
        return .init(truncatingIfNeeded: (window &<< (cursor & 7)) &>> (64 &- width))
    }

    @inline(always)
    @_lifetime(self: copy self)
    mutating func readBit() -> Bool {
        let index = cursor &>> 3
        let bit = 7 &- (cursor & 7)
        cursor = min(cursor &+ 1, limit)
        guard index < bytes.count else { return false }
        return (bytes[index] &>> bit) & 1 == 1
    }

    /// Counts the ones in front of the next zero, and consumes that zero.
    ///
    /// - Parameter limit: how many ones to count before answering. It stops a corrupt stream
    ///   running to the end of the frame.
    @inline(always)
    @_lifetime(self: copy self)
    mutating func readUnary(limit: Int) -> Int {
        var length = 0

        while length < limit, readBit() { length &+= 1 }
        return length
    }

    // MARK: - The window

    /// Eight bytes starting at `index`, most significant byte first.
    ///
    /// The load is unaligned and unconditional, which is what keeps a read branch free. The bytes
    /// behind the last one read as zero.
    @inline(always)
    private func window(at index: Int) -> UInt64 {
        guard index &+ 8 <= bytes.count else { return tail(at: index) }

        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = unsafe UnsafeRawPointer(buffer.baseAddress) else { return 0 }
            return unsafe UInt64(bigEndian: base.loadUnaligned(
                fromByteOffset: index, as: UInt64.self))
        }
    }

    /// The window over the last bytes, where a wide load would run past the end.
    ///
    /// This sits out of line because it runs once per frame and inlining it would double the size
    /// of every read.
    @inline(never)
    private func tail(at index: Int) -> UInt64 {
        guard index < bytes.count else { return 0 }
        let available = min(8, bytes.count &- index)
        var window: UInt64 = 0

        for step in 0..<available { window |= UInt64(bytes[index &+ step]) &<< (56 &- (step &* 8)) }
        return window
    }
}
