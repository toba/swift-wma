internal import Foundation

/// Decodes a WMA Pro stream, one ASF media object at a time.
///
/// This ports FFmpeg's `wmaprodec.c` without its XMA path. A frame may start in one packet and end
/// in the next, so the decoder holds the frame's bits in a reservoir until they are all present.
final class WMAProDecoder: WMAStreamDecoder, WMAReservoirDecoding {
    static let formatTag = 0x0162

    /// The most bytes one frame's reservoir holds.
    static let maximumFrameBytes = 32_768

    /// How many passes over one media object the decode allows, so a corrupt one cannot hang it.
    static let passLimit = 4_096

    let configuration: WMAProConfiguration
    let codes: WMAProCodeSet

    /// One transform and one sine window per block size, indexed by the block length's power of two
    /// less ``WMAProConfiguration/shortestBlockBits``.
    let transforms: [InverseMDCT?]
    let windows: [[Float]]

    /// What the transform's output is multiplied by, per block size index as above.
    let transformScales: [Float]

    var reservoir: WMAFrameReservoir

    /// The frame the current pass decoded, which the pass then trims and hands out.
    var pendingFrame: [Float]?

    // MARK: - The frame state

    var skipsFrame = true
    var parsedAllSubframes = false
    var trimStart = 0
    var trimEnd = 0

    var channels: [WMAProChannelState]
    var groups: [WMAProChannelGroup]
    var groupCount = 0

    /// Each channel's output run, ``outputStride`` apart.
    ///
    /// The first `samplesPerFrame` values of a run are the next frame out. The half frame behind
    /// them holds the coefficients and the transform output still to overlap.
    var outputs: [Float]
    let outputStride: Int

    /// The scaled coefficients the transform reads.
    var transformInput: [Float]

    // MARK: - The subframe state

    var channelsForSubframe: [Int] = []
    var subframeLength = 0
    var tableIndex = 0
    var bandCount = 0
    var escapeLength = 0
    var transmitsVectorCount = false

    // MARK: - Building

    init(format: WMAStreamFormat) throws(AudioReadError) {
        let configuration = try WMAProConfiguration(format: format)
        guard let codes = WMAProCodeSet.shared else { throw .malformed("WMA Pro code tables") }
        self.configuration = configuration
        self.codes = codes
        reservoir = .init(
            codec: .pro,
            blockAlign: format.blockAlign,
            log2FrameSize: configuration.log2FrameSize,
            hasLengthPrefix: configuration.hasLengthPrefix,
            maximumFrameBytes: Self.maximumFrameBytes
        )

        let frame = configuration.samplesPerFrame
        let shortest = WMAProConfiguration.shortestBlockBits
        let sizes = WMAProConfiguration.longestBlockBits - shortest + 1
        var transforms = [InverseMDCT?](repeating: nil, count: sizes)
        var windows = [[Float]](repeating: [], count: sizes)
        var scales = [Float](repeating: 0, count: sizes)

        for step in 0..<configuration.bandCounts.count {
            let length = frame >> step
            let index = WMAMath.floorLog2(length) - shortest
            guard let transform = InverseMDCT(count: length) else {
                throw .malformed("WMA Pro block size \(length)")
            }
            transforms[index] = transform
            windows[index] = SineWindow.make(count: length)
            scales[index] = Float(
                2.0 / Double(length) / Double(Int64(1) << (configuration.bitsPerSample - 1)))
        }
        self.transforms = transforms
        self.windows = windows
        transformScales = scales

        channels = .init(
            repeating: .init(previousBlockLength: frame), count: configuration.channelCount)
        groups = .init(repeating: .init(), count: configuration.channelCount)
        outputStride = frame + frame / 2
        outputs = .init(repeating: 0, count: outputStride * configuration.channelCount)
        transformInput = .init(repeating: 0, count: frame)
    }

    /// Returns the decoder to the state a fresh open leaves it in.
    func reset() {
        reservoir.reset()
        pendingFrame = nil
        skipsFrame = true
        trimStart = 0
        trimEnd = 0
        groupCount = 0

        let frame = configuration.samplesPerFrame
        channels = .init(repeating: .init(previousBlockLength: frame), count: channels.count)
        groups = .init(repeating: .init(), count: groups.count)
        for index in outputs.indices { outputs[index] = 0 }
    }

    // MARK: - One media object

    /// Decodes one media object into interleaved samples between minus one and one.
    ///
    /// The object is offered again from where each pass stopped, as FFmpeg's decode loop offers a
    /// packet, until every byte is read. A stream fault drops the rest of the object, as FFmpeg
    /// does.
    func decode(_ packet: Data) throws(AudioReadError) -> [Float] {
        let bytes = packet.span
        var samples: [Float] = []
        var start = 0
        var passes = 0

        while start < bytes.count, passes < Self.passLimit {
            passes += 1
            pendingFrame = nil
            guard let consumed = decodePacketPass(bytes, from: start) else { break }

            if var frame = pendingFrame, trim(&frame) { samples.append(contentsOf: frame) }
            // the header of the next frame states its own trims, so these never carry over
            trimStart = 0
            trimEnd = 0
            start += consumed
        }
        return samples
    }

    func decodeReservoirFrame() -> Bool { decodeFrame(into: &pendingFrame) }

    /// Takes the samples the frame header marked for trimming off the frame.
    ///
    /// - Returns: whether any frame remains
    private func trim(_ frame: inout [Float]) -> Bool {
        let channels = configuration.channelCount
        var count = configuration.samplesPerFrame
        var kept = true

        if trimStart > 0 {
            if trimStart < count {
                frame.removeFirst(trimStart * channels)
                count -= trimStart
            } else {
                kept = false
            }
        }
        if trimEnd > 0 {
            if trimEnd < count { frame.removeLast(trimEnd * channels) } else { kept = false }
        }
        return kept
    }
}

/// What one channel carries from one subframe to the next, as FFmpeg's `WMAProChannelCtx` does.
struct WMAProChannelState {
    var previousBlockLength: Int
    var transmitsCoefficients = false
    var subframeCount = 0
    var subframeLengths = [Int](repeating: 0, count: WMAProConfiguration.maximumSubframes)
    var currentSubframe = 0
    var decodedSamples = 0
    var grouped = false
    var quantizationStep = 0
    var reusesScaleFactors = false
    var scaleFactorStep = 0
    var maximumScaleFactor = 0

    /// The two scale factor lists, the one last sent and the one in use.
    var savedScaleFactors = [[Int]](
        repeating: .init(repeating: 0, count: WMAProConfiguration.maximumBands), count: 2)

    /// Which list holds the factors last sent. The other one is in use.
    var scaleFactorIndex = 0

    /// The block size index the factors in use were sent at.
    var tableIndex = 0

    /// Where the current subframe's coefficients start in the channel's output run.
    var coefficientStart = 0

    var vectorCoefficientCount = 0

    /// Which list the current subframe scales by.
    var activeScaleFactors = 0
}

/// A set of channels a subframe transforms together.
struct WMAProChannelGroup {
    var channelCount = 0
    var transforms = false
    var transformBands = [Bool](repeating: false, count: WMAProConfiguration.maximumBands)

    /// The decorrelation matrix, one row per member, `channelCount` wide.
    var matrix = [Float](
        repeating: 0,
        count: WMAProConfiguration.maximumChannels * WMAProConfiguration.maximumChannels)

    /// The channels whose coefficients the group holds, in stream order.
    var members: [Int] = []
}
