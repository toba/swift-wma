internal import Foundation

/// Everything a WMA Pro stream's decode derives from its header, worked out once.
///
/// A block size index counts down from the full frame, so index zero is the frame itself and each
/// step halves it. Every per-size array here is indexed that way.
struct WMAProConfiguration: Equatable {
    /// The most channels a stream carries, and the most subframes a channel splits into.
    static let maximumChannels = 8
    static let maximumSubframes = 32

    /// The most scale factor bands one block holds.
    static let maximumBands = 29

    /// The shortest and the longest block, as powers of two.
    static let shortestBlockBits = 6
    static let longestBlockBits = 13

    let channelCount: Int

    /// The sample depth the encoder read, which scales the transform to minus one and one.
    let bitsPerSample: Int

    let samplesPerFrame: Int

    /// How many bits state a frame's length and the bits a packet carries over.
    let log2FrameSize: Int

    let hasLengthPrefix: Bool
    let hasDynamicRangeCompression: Bool

    let maximumSubframeCount: Int

    /// How many bits state a subframe's length.
    let subframeLengthBits: Int

    /// Whether a leading one bit marks a subframe shorter than the frame.
    let hasShortSubframeFlag: Bool

    let minimumSubframeLength: Int

    /// How many scale factor bands each block size holds.
    let bandCounts: [Int]

    /// Where each band of each block size starts, with the block length closing the list.
    ///
    /// Each list holds ``maximumBands`` entries, zero past the last band, as FFmpeg's does.
    let bandOffsets: [[Int]]

    /// Which band of the block size a scale factor was sent at covers each band of this size.
    ///
    /// Indexed by the current size, the size the factors were sent at, and the current band.
    let scaleFactorBands: [[[Int]]]

    init(format: WMAStreamFormat) throws(AudioReadError) {
        let extra = [UInt8](format.extra)
        guard extra.count >= 18 else { throw .malformed("WMA Pro extra bytes") }

        let bits = Int(extra[0]) | Int(extra[1]) << 8
        let mask = (2...5).reduce(0) { $0 | Int(extra[$1]) << (8 * ($1 - 2)) }
        let flags = Int(extra[14]) | Int(extra[15]) << 8
        guard (1...32).contains(bits) else { throw .malformed("WMA Pro bits per sample \(bits)") }
        bitsPerSample = bits

        // a mask that counts differently from the header is refused, because the file surface
        // interleaves by the header's count
        let channels = mask != 0 ? mask.nonzeroBitCount : format.channelCount
        guard channels > 0, channels <= Self.maximumChannels, channels == format.channelCount
        else { throw .malformed("WMA Pro channel count \(channels)") }
        channelCount = channels

        guard format.blockAlign > 0, format.sampleRate > 0
        else { throw .malformed("WMA Pro stream format") }
        log2FrameSize = WMAMath.floorLog2(format.blockAlign) + 4
        guard log2FrameSize <= 25 else { throw .malformed("WMA Pro block align") }

        hasLengthPrefix = flags & 0x40 != 0
        hasDynamicRangeCompression = flags & 0x80 != 0

        let frameBits = WMAMath.version3FrameLengthBits(
            sampleRate: format.sampleRate, decodeFlags: flags)
        guard frameBits <= Self.longestBlockBits else { throw .malformed("WMA Pro frame length") }
        samplesPerFrame = 1 << frameBits

        let log2Subframes = (flags & 0x38) >> 3
        maximumSubframeCount = 1 << log2Subframes
        hasShortSubframeFlag = maximumSubframeCount == 16 || maximumSubframeCount == 4
        subframeLengthBits = WMAMath.floorLog2(log2Subframes) + 1
        minimumSubframeLength = samplesPerFrame / maximumSubframeCount
        guard maximumSubframeCount <= Self.maximumSubframes,
              minimumSubframeLength >= 1 << Self.shortestBlockBits
        else { throw .malformed("WMA Pro subframe count") }

        let sizes = log2Subframes + 1
        var offsets: [[Int]] = []
        var counts: [Int] = []

        for size in 0..<sizes {
            let bands = Self.bandOffsets(
                subframeLength: samplesPerFrame >> size, sampleRate: format.sampleRate)
            guard bands.count > 1 else { throw .malformed("WMA Pro band count") }
            counts.append(bands.count - 1)
            offsets.append(bands + repeatElement(0, count: Self.maximumBands - bands.count))
        }
        bandCounts = counts
        bandOffsets = offsets
        scaleFactorBands = Self.scaleFactorBands(offsets: offsets, counts: counts)
    }

    // MARK: - The rules

    /// Where each scale factor band of one block size starts, closed by the block length.
    static func bandOffsets(subframeLength: Int, sampleRate: Int) -> [Int] {
        var offsets = [0]

        for frequency in WMAProTables.criticalFrequencies.prefix(maximumBands - 1) {
            guard offsets[offsets.count - 1] < subframeLength else { break }
            let offset = ((subframeLength * 2 * frequency) / sampleRate + 2) & ~3
            if offset > offsets[offsets.count - 1] { offsets.append(offset) }
            if offset >= subframeLength { break }
        }
        offsets[offsets.count - 1] = subframeLength
        return offsets
    }

    /// The band of each other block size whose centre covers each band's centre.
    static func scaleFactorBands(offsets: [[Int]], counts: [Int]) -> [[[Int]]] {
        offsets.indices.map { size in
            offsets.indices.map { other in
                (0..<counts[size]).map { band in
                    let centre = ((offsets[size][band] + offsets[size][band + 1] - 1) << size) >> 1
                    var covering = 0

                    while covering + 1 < maximumBands,
                          offsets[other][covering + 1] << other < centre
                    { covering += 1 }
                    return covering
                }
            }
        }
    }
}
