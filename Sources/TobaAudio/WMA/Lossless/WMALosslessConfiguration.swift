internal import Foundation

/// Everything a WMA Lossless stream's decode derives from its header, worked out once.
struct WMALosslessConfiguration: Equatable, Sendable {
    let channelCount: Int
    let sampleRate: Int

    /// The integer depth of a decoded sample, which is 16 or 24.
    let bitsPerSample: Int

    /// The encoder's feature word, at index 14 of the extra bytes.
    let decodeFlags: Int

    /// How many bytes one codec packet occupies.
    let blockAlign: Int

    let samplesPerFrame: Int

    /// How many bits state a frame length or the bits a packet adds to the frame before it.
    let log2FrameSize: Int

    let maximumSubframes: Int
    let minimumSubframeLength: Int

    /// Whether each frame states its own length in front of it.
    var hasLengthPrefix: Bool { decodeFlags & 0x40 != 0 }

    /// Whether each frame carries a dynamic range gain, which the decode reads and ignores.
    var hasDynamicRangeGain: Bool { decodeFlags & 0x80 != 0 }

    /// Whether the stream takes the later encoder's update rule and may carry LPC coefficients.
    var isVersion3RTM: Bool { decodeFlags & 0x100 != 0 }

    /// The largest frame the reservoir holds, in bytes.
    var maximumFrameSize: Int { 32_768 * channelCount }

    static let maximumChannels = 8
    static let maximumSubframeCount = 32
    static let maximumBlockLength = 1 << 14

    init(format: WMAStreamFormat) throws(AudioReadError) {
        guard format.codec == WMALosslessDecoder.formatTag else {
            throw .malformed("WMA codec \(format.codec)")
        }
        guard format.blockAlign > 0, format.blockAlign <= 1 << 21
        else { throw .malformed("WMA Lossless block align") }
        let extra = [UInt8](format.extra)
        guard extra.count >= 18 else { throw .malformed("WMA Lossless extra bytes") }

        let depth = Int(extra[0]) | Int(extra[1]) << 8
        let mask = UInt32(extra[2]) | UInt32(extra[3]) << 8 | UInt32(extra[4]) << 16
            | UInt32(extra[5]) << 24
        let flags = Int(extra[14]) | Int(extra[15]) << 8
        guard depth == 16 || depth == 24 else {
            throw .malformed("WMA Lossless bit depth \(depth)")
        }

        // a mask that counts differently from the header is refused, because the file surface
        // interleaves by the header's count
        let channels = mask != 0 ? mask.nonzeroBitCount : format.channelCount
        guard channels > 0,
              channels <= Self.maximumChannels,
              channels == format.channelCount,
              format.sampleRate > 0 else { throw .malformed("WMA Lossless stream format") }

        let frameBits = WMAMath.version3FrameLengthBits(
            sampleRate: format.sampleRate, decodeFlags: flags)
        let frameLength = 1 << frameBits
        guard frameLength <= Self.maximumBlockLength else {
            throw .malformed("WMA Lossless frame length \(frameLength)")
        }
        let subframes = 1 << ((flags & 0x38) >> 3)
        guard subframes <= Self.maximumSubframeCount else {
            throw .malformed("WMA Lossless subframe count \(subframes)")
        }

        channelCount = channels
        sampleRate = format.sampleRate
        bitsPerSample = depth
        decodeFlags = flags
        blockAlign = format.blockAlign
        samplesPerFrame = frameLength
        log2FrameSize = WMAMath.floorLog2(format.blockAlign) + 4
        maximumSubframes = subframes
        minimumSubframeLength = frameLength / subframes
    }
}

/// One value per channel, held inline so a per-frame or per-subframe step allocates nothing.
typealias ChannelValues<Element> = InlineArray<8, Element>
