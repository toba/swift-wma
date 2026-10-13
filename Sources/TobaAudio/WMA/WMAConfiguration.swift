internal import Foundation

/// Everything a WMA v1 or v2 stream's decode derives from its header, worked out once.
///
/// A block size index counts down from the full frame, so index zero is the longest block and each
/// step halves it. Every array here is indexed that way.
struct WMAConfiguration {
    let channelCount: Int
    let sampleRate: Int
    let options: WMAEncodeOptions

    let version: WMAVersion

    /// A full frame holds `1 << frameLengthBits` samples.
    let frameLengthBits: Int

    /// How many block sizes a frame may split into.
    let blockSizeCount: Int

    /// How many bits state where the bit reservoir's first whole frame starts.
    let byteOffsetBits: Int

    /// Whether the stream codes its high bands as noise rather than as coefficients.
    let usesNoiseCoding: Bool

    /// The amplitude the noise generator runs at.
    let noiseMultiplier: Float

    /// The exponent band widths, per block size.
    let exponentBands: [[Int]]

    /// One past the last coefficient each block size codes.
    let coefficientEnds: [Int]

    /// Where the high band starts, per block size.
    let highBandStarts: [Int]

    /// The high band widths, per block size.
    let highBands: [[Int]]

    /// Which pair of coefficient tables the bit rate picks.
    let coefficientClass: Int

    var frameLength: Int { 1 << frameLengthBits }

    /// The shortest block a frame may split into.
    static let shortestBlockBits = 7

    init(format: WMAStreamFormat) throws(AudioReadError) {
        guard let version = WMAVersion(rawValue: format.codec) else {
            throw .malformed("WMA codec \(format.codec)")
        }
        self.version = version
        guard format.sampleRate > 0,
              format.sampleRate <= 50_000,
              format.channelCount > 0,
              format.channelCount <= 2,
              format.bitRate > 0 else { throw .malformed("WMA stream format") }

        channelCount = format.channelCount
        sampleRate = format.sampleRate
        let options = try WMAEncodeOptions(extra: format.extra, version: version)
        self.options = options

        let lengthBits = Self.frameLengthBits(sampleRate: format.sampleRate, version: version)
        frameLengthBits = lengthBits
        let frameLength = 1 << lengthBits

        blockSizeCount = Self.blockSizeCount(
            options: options, bitRate: format.bitRate, channels: format.channelCount,
            frameLengthBits: lengthBits)

        let bits = Double(format.bitRate) / Double(format.channelCount * format.sampleRate)
        let reservoir = Int(bits * Double(frameLength) / 8 + 0.5)
        byteOffsetBits = WMAMath.floorLog2(reservoir) + 2

        // a stereo stream spends more of its budget per channel than the plain ratio suggests
        let weighted = format.channelCount == 2 ? bits * 1.6 : bits
        let cutoff = Self.highFrequency(
            sampleRate: format.sampleRate, version: version, bits: bits, weighted: weighted)
        usesNoiseCoding = cutoff.usesNoiseCoding
        noiseMultiplier = options.usesExponentVLC ? 0.02 : 0.04

        var bands: [[Int]] = []
        var ends: [Int] = []
        var starts: [Int] = []
        var high: [[Int]] = []

        for index in 0..<blockSizeCount {
            let blockLength = frameLength >> index
            let width =
                switch version {
                    case .one:
                        Self.version1Bands(blockLength: blockLength, sampleRate: format.sampleRate)
                    case .two:
                        Self.exponentBands(
                            blockSizeIndex: index, frameLengthBits: lengthBits,
                            blockLength: blockLength, sampleRate: format.sampleRate)
                }
            // the last nine percent of the spectrum is never coded
            let end = (frameLength - frameLength * 9 / 100) >> index
            let start = Int(
                Double(blockLength * 2) * cutoff.frequency / Double(format.sampleRate) + 0.5)

            bands.append(width)
            ends.append(end)
            starts.append(start)
            high.append(Self.highBands(over: width, from: start, to: end))
        }
        exponentBands = bands
        coefficientEnds = ends
        highBandStarts = starts
        highBands = high

        var table = 2

        if format.sampleRate >= 32_000 {
            if weighted < 0.72 { table = 0 } else if weighted < 1.16 { table = 1 }
        }
        coefficientClass = table
    }

    // MARK: - The frame

    /// How many samples a frame holds, as a power of two.
    static func frameLengthBits(sampleRate: Int, version: WMAVersion) -> Int {
        if sampleRate <= 16_000 { return 9 }
        return sampleRate <= version.shortFrameLimit ? 10 : 11
    }

    /// How many block sizes a frame may split into.
    ///
    /// The stream states a step count, the bit rate raises it, and the shortest block the format
    /// allows caps it.
    static func blockSizeCount(
        options: WMAEncodeOptions,
        bitRate: Int,
        channels: Int,
        frameLengthBits: Int
    ) -> Int {
        guard options.usesVariableBlockLength else { return 1 }
        var steps = options.blockSizeSteps
        if bitRate / channels >= 32_000 { steps += 2 }
        return min(steps, frameLengthBits - shortestBlockBits) + 1
    }

    // MARK: - The spectrum

    /// Where the high band starts, and whether the stream codes it as noise.
    ///
    /// A stream with enough bits per sample codes every band, and the cutoff then stays at the
    /// Nyquist frequency where it has no effect.
    static func highFrequency(
        sampleRate: Int,
        version: WMAVersion,
        bits: Double,
        weighted: Double
    ) -> (frequency: Double, usesNoiseCoding: Bool) {
        let nyquist = Double(sampleRate) * 0.5
        let rounded = version.roundsSampleRate
            ? [44_100, 22_050, 16_000, 11_025, 8_000].first { sampleRate >= $0 } ?? 0
            : sampleRate

        switch rounded {
            case 44_100: return weighted >= 0.61 ? (nyquist, false) : (nyquist * 0.4, true)
            case 22_050:
                return weighted >= 1.16
                    ? (nyquist, false)
                    : (nyquist * (weighted >= 0.72 ? 0.7 : 0.6), true)
            case 16_000: return (nyquist * (bits > 0.5 ? 0.5 : 0.3), true)
            case 11_025: return (nyquist * 0.7, true)
            case 8_000:
                return bits > 0.75
                    ? (nyquist, false)
                    : (nyquist * (bits <= 0.625 ? 0.5 : 0.65), true)
            default:
                return bits >= 0.8
                    ? (nyquist * 0.75, true)
                    : (nyquist * (bits >= 0.6 ? 0.6 : 0.5), true)
        }
    }

    /// The exponent band widths of one block size.
    ///
    /// A short block takes a written table. A longer one computes its bands off the Bark scale,
    /// rounded to a multiple of four coefficients.
    static func exponentBands(
        blockSizeIndex: Int,
        frameLengthBits: Int,
        blockLength: Int,
        sampleRate: Int
    ) -> [Int] {
        let step = frameLengthBits - shortestBlockBits - blockSizeIndex

        if step >= 0, step < 3, let written = writtenBands(step: step, sampleRate: sampleRate) {
            return written
        }
        var widths: [Int] = []
        var last = 0

        for edge in WMATables.criticalFrequencies {
            let scaled = blockLength * 2 * Int(edge) + sampleRate * 2
            var position = (scaled / (4 * sampleRate)) << 2
            if position > blockLength { position = blockLength }
            if position > last { widths.append(position - last) }
            if position >= blockLength { break }
            last = position
        }
        return widths
    }

    /// The exponent band widths of a version 1 block, off the Bark scale to the nearest
    /// coefficient.
    ///
    /// A band may be empty, because version 1 keeps a band edge that rounds onto the one before it.
    static func version1Bands(blockLength: Int, sampleRate: Int) -> [Int] {
        var widths: [Int] = []
        var last = 0

        for edge in WMATables.criticalFrequencies {
            let position = min(
                (blockLength * 2 * Int(edge) + sampleRate / 2) / sampleRate, blockLength)
            widths.append(position - last)
            if position >= blockLength { break }
            last = position
        }
        return widths
    }

    /// The band widths written for a short block, which the Bark computation does not reproduce.
    static func writtenBands(step: Int, sampleRate: Int) -> [Int]? {
        let table: [[UInt8]]

        if sampleRate >= 44_100 {
            table = WMATables.exponentBands44100
        } else if sampleRate >= 32_000 {
            table = WMATables.exponentBands32000
        } else if sampleRate >= 22_050 {
            table = WMATables.exponentBands22050
        } else {
            return nil
        }
        guard step < table.count else { return nil }
        let row = table[step]
        guard let count = row.first.map(Int.init), count < row.count else { return nil }
        return row[1...count].map(Int.init)
    }

    /// The part of each exponent band that sits inside the high band.
    static func highBands(over widths: [Int], from start: Int, to end: Int) -> [Int] {
        var bands: [Int] = []
        var position = 0

        for width in widths {
            let lower = max(position, start)
            position += width
            let upper = min(position, end)
            if upper > lower { bands.append(upper - lower) }
        }
        return bands
    }

    /// How many bits an escaped coefficient level occupies, which the frame's own gain decides.
    static func escapeBits(totalGain: Int) -> Int {
        switch totalGain {
            case ..<15: 13
            case ..<32: 12
            case ..<40: 11
            case ..<45: 10
            default: 9
        }
    }
}
