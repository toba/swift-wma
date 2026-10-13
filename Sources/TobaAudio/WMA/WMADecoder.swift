internal import Foundation

/// Decodes a WMA v1 or v2 stream, one super frame at a time.
///
/// A super frame is one ASF media object. It carries whole frames, plus the tail of the frame the
/// packet before it began. The decoder holds that tail so the frame spanning the join decodes once,
/// in order.
///
/// ```swift
/// let decoder = try WMADecoder(format: header.format)
/// let samples = try decoder.decode(object.bytes)
/// ```
final class WMADecoder {
    let configuration: WMAConfiguration

    /// What the transform's own output is multiplied by to reach the range a sample takes.
    static let outputScale: Float = 1.0 / 32768

    /// One transform and one window per block size, longest first.
    let transforms: [InverseMDCT]
    let windows: [[Float]]

    /// The same windows read backward, which is what a falling edge folds with.
    ///
    /// Storing the reversal costs a few kilobytes once and lets every overlap add walk both arrays
    /// forward, which is what a vector multiply needs.
    let fallingWindows: [[Float]]

    let exponentTable: WMACodeTable

    /// The two coefficient tables. A mid-side channel reads the second.
    let coefficientTables: [WMACodeTable]
    let coefficientRuns: [[Int]]
    let coefficientLevels: [[Int]]

    let powers = WMATables.powers

    /// The noise a sparse stream fills its uncoded high bands with, empty for a dense stream.
    let noise: [Float]

    /// The gain step of each noise band behind the first, which states its own gain in seven bits.
    let highGainTable: WMACodeTable

    /// How many high bands a channel holds at most, which spaces the per-channel band state.
    let highBandLimit: Int

    // MARK: - The running state

    /// One channel after another, `configuration.frameLength` apart.
    ///
    /// The per-channel runs sit in one array rather than in an array of arrays. A nested element
    /// write runs a uniqueness check on the inner array, and the loops below write one per sample.
    var exponents: [Float]
    var maximumExponent: [Float]
    var exponentBlockSize: [Int]
    var exponentsReady: [Bool]

    /// The coefficients as the bitstream codes them, before the exponents scale them.
    var coded: [Float]

    /// The coefficients the transform reads.
    var scaled: [Float]

    /// Two frames of windowed output per channel, the second half overlapping the frame to come.
    ///
    /// This one is `configuration.frameLength * 2` apart, because a channel holds two frames.
    var frameOut: [Float]

    /// One block's transform output, which is twice the block length.
    var output: [Float]

    var blockLengthBits: Int
    var previousBlockLengthBits: Int
    var nextBlockLengthBits: Int
    var resetBlockLengths = true
    var blockPosition = 0

    var isMidSide = false
    var channelCoded: [Bool]

    /// How many coefficients each channel's run codes, which a noise band shortens by its width.
    var coefficientCounts: [Int]

    /// Which high bands take noise, per channel, `highBandLimit` apart.
    var highBandNoise: [Bool]
    var highBandGains: [Int]
    var highBandPower: [Float]

    /// The next noise value a coefficient takes. It runs on across blocks and frames.
    var noiseIndex = 0

    /// The tail of the last super frame, which the frame spanning the join starts in.
    private var reservoir: [UInt8] = []

    /// How many bits of the reservoir's first byte the frame before it already used.
    private var reservoirBitOffset = 0

    // MARK: - Building

    init(format: WMAStreamFormat) throws(AudioReadError) {
        let configuration = try WMAConfiguration(format: format)
        guard configuration.version.decodesVariableBlockLength
            || !configuration.options.usesVariableBlockLength
        else { throw .malformed("WMA v1 variable block length") }
        // no file in the reference library codes its exponents as line spectral pairs
        guard configuration.options.usesExponentVLC else {
            throw .malformed("WMA line spectral pair exponents")
        }
        self.configuration = configuration

        var built: [InverseMDCT] = []
        var shapes: [[Float]] = []

        for index in 0..<configuration.blockSizeCount {
            let length = configuration.frameLength >> index
            guard let transform = InverseMDCT(count: length) else {
                throw .malformed("WMA block size \(length)")
            }
            built.append(transform)
            shapes.append(SineWindow.make(count: length))
        }
        transforms = built
        windows = shapes
        fallingWindows = shapes.map { $0.reversed() }

        guard let exponentTable = WMACodeTable(
            codes: WMATables.exponentCodes, lengths: WMATables.exponentLengths)
        else { throw .malformed("WMA exponent table") }
        self.exponentTable = exponentTable

        var tables: [WMACodeTable] = []
        var runs: [[Int]] = []
        var levels: [[Int]] = []

        for step in 0..<2 {
            let index = configuration.coefficientClass * 2 + step
            guard index < WMATables.coefficientCodes.count else {
                throw .malformed("WMA coefficient table \(index)")
            }
            let codes = WMATables.coefficientCodes[index]
            guard let table = WMACodeTable(
                codes: codes, lengths: WMATables.coefficientLengths[index])
            else { throw .malformed("WMA coefficient table \(index)") }

            let expanded = WMATables.runsAndLevels(
                levels: WMATables.coefficientLevels[index], count: codes.count)
            tables.append(table)
            runs.append(expanded.runs)
            levels.append(expanded.levels)
        }
        coefficientTables = tables
        coefficientRuns = runs
        coefficientLevels = levels

        guard let highGainTable = WMACodeTable(
            lengths: WMATables.highGainLengths,
            symbols: WMATables.highGainSymbols.map(Int.init),
            offset: -18)
        else { throw .malformed("WMA high band gain table") }
        self.highGainTable = highGainTable

        if configuration.usesNoiseCoding {
            // the low, the coded, the noise and the very high runs have to tile the block
            let first = configuration.version.coefficientStart
            let tiled = zip(configuration.highBandStarts, configuration.coefficientEnds)
                .allSatisfy { $0 >= first && $0 <= $1 }
            guard tiled else { throw .malformed("WMA high band start") }
            noise = WMATables.noise(multiplier: configuration.noiseMultiplier)
        } else {
            noise = []
        }
        highBandLimit = configuration.highBands.map(\.count).max() ?? 0

        let channels = configuration.channelCount
        let frameLength = configuration.frameLength
        exponents = .init(repeating: 0, count: frameLength * channels)
        maximumExponent = .init(repeating: 1, count: channels)
        exponentBlockSize = .init(repeating: 0, count: channels)
        exponentsReady = .init(repeating: false, count: channels)
        coded = .init(repeating: 0, count: frameLength * channels)
        scaled = .init(repeating: 0, count: frameLength * channels)
        frameOut = .init(repeating: 0, count: frameLength * 2 * channels)
        output = .init(repeating: 0, count: frameLength * 2)
        channelCoded = .init(repeating: false, count: channels)
        coefficientCounts = .init(repeating: 0, count: channels)
        highBandNoise = .init(repeating: false, count: highBandLimit * channels)
        highBandGains = .init(repeating: 0, count: highBandLimit * channels)
        highBandPower = .init(repeating: 0, count: highBandLimit)

        blockLengthBits = configuration.frameLengthBits
        previousBlockLengthBits = configuration.frameLengthBits
        nextBlockLengthBits = configuration.frameLengthBits
    }

    /// Drops every frame the decoder holds, which a seek needs before it decodes elsewhere.
    func reset() {
        reservoir.removeAll(keepingCapacity: true)
        reservoirBitOffset = 0
        resetBlockLengths = true

        for index in frameOut.indices { frameOut[index] = 0 }
        for channel in exponentsReady.indices { exponentsReady[channel] = false }
    }

    // MARK: - One super frame

    /// Decodes one codec packet into interleaved samples between minus one and one.
    ///
    /// A packet that only extends the reservoir answers no samples. That is the normal state of a
    /// file's first packet rather than a fault.
    func decode(_ packet: Data) throws(AudioReadError) -> [Float] {
        let bytes = [UInt8](packet)
        guard !bytes.isEmpty else { return [] }
        guard configuration.options.usesBitReservoir else {
            var samples = [Float](
                repeating: 0, count: configuration.frameLength * configuration.channelCount)
            var reader = BitReader(bytes.span)
            try decodeFrame(&reader, into: &samples, at: 0)
            return samples
        }
        return try decodeReservoir(bytes)
    }

    /// The bit reservoir route, where one frame starts in the packet before this one.
    private func decodeReservoir(_ bytes: [UInt8]) throws(AudioReadError) -> [Float] {
        // the super frame index, the frame count and the offset the first whole frame starts at
        let preamble = 8 + configuration.byteOffsetBits + 3
        var reader = BitReader(bytes.span)
        reader.skip(4)
        var frames = Int(reader.read(4))
        if reservoir.isEmpty { frames -= 1 }

        guard frames > 0 else {
            // every bit of this packet continues the held frame, so the packet joins the reservoir
            reservoir.append(contentsOf: bytes.dropFirst())
            return []
        }
        let offset = Int(reader.read(configuration.byteOffsetBits + 3))
        guard offset >= 0, offset <= reader.remaining
        else { throw .malformed("WMA reservoir offset") }
        let perFrame = configuration.frameLength * configuration.channelCount
        var samples = [Float](repeating: 0, count: frames * perFrame)
        var written = 0

        if !reservoir.isEmpty {
            try decodeJoin(bytes, preamble: preamble, offset: offset, into: &samples)
            written = perFrame
            frames -= 1
        }
        let start = offset + preamble
        var whole = BitReader(bytes.span, cursor: (start >> 3) * 8)
        whole.skip(start & 7)
        resetBlockLengths = true

        for _ in 0..<frames {
            try decodeFrame(&whole, into: &samples, at: written)
            written += perFrame
        }
        let consumed = whole.cursor
        guard consumed >> 3 <= bytes.count else { throw .malformed("WMA reservoir tail") }
        reservoirBitOffset = consumed & 7
        reservoir = Array(bytes[(consumed >> 3)...])
        return samples
    }

    /// Decodes the frame that starts in the held packet and finishes in this one.
    ///
    /// - Parameters:
    ///   - preamble: how many bits the super frame's own header occupies
    ///   - offset: how many bits of this packet finish the held frame
    private func decodeJoin(
        _ bytes: [UInt8],
        preamble: Int,
        offset: Int,
        into samples: inout [Float]
    ) throws(AudioReadError) {
        var joined = reservoir
        var source = BitReader(bytes.span)
        source.skip(preamble)
        var left = offset

        while left >= 8 {
            joined.append(UInt8(truncatingIfNeeded: source.read(8)))
            left -= 8
        }
        if left > 0 {
            // the last byte is part of a byte, so it sits at the top and the rest reads as zero
            joined.append(UInt8(truncatingIfNeeded: source.read(left) << (8 - left)))
        }
        guard !source.isOverrun else { throw .malformed("WMA reservoir join") }

        let assembled = joined
        var held = BitReader(assembled.span)
        held.skip(reservoirBitOffset)
        try decodeFrame(&held, into: &samples, at: 0)
    }
}
