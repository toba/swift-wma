internal import Foundation

/// Decodes a WMA Lossless stream, one ASF media object at a time.
///
/// The port follows FFmpeg's `wmalosslessdec.c`. A packet carries the tail of the frame the packet
/// before it began, then whole frames, then the head of the next one, which a bit reservoir joins.
final class WMALosslessDecoder: WMAStreamDecoder, WMAReservoirDecoding {
    static let formatTag = 0x0163

    let configuration: WMALosslessConfiguration

    var reservoir: WMAFrameReservoir

    // MARK: - The frame

    /// One channel after another, `samplesPerFrame` apart, as FFmpeg's planar frame holds them.
    var frameSamples: [Int32]
    var writePositions: [Int]

    /// How many samples per channel the current frame answers, which zero marks as none.
    var frameSampleCount = 0

    var subframes: [LosslessChannelTiling]
    var parsedAllSubframes = false
    var channelsForSubframe: [Int] = []

    // MARK: - The filters

    var seekableTile = false
    var usesACFilter = false
    var usesInterChannel = false
    var usesMCLMS = false
    var usesLPC = false

    var acOrder = 0
    var acScaling = 0
    var acCoefficients = [Int16](repeating: 0, count: 16)

    /// Sixteen per channel.
    var acHistory: [Int32]

    var mclmsOrder = 0
    var mclmsScaling = 0
    var mclmsCoefficients = [Int16](repeating: 0, count: 2048)
    var mclmsCurrent = [Int16](repeating: 0, count: 64)
    var mclmsHistory = [Int32](repeating: 0, count: 512)
    var mclmsUpdates = [Int32](repeating: 0, count: 512)
    var mclmsRecent = 0

    /// How many CDLMS filters each channel runs, at most nine.
    var cdlmsCount: [Int]

    /// One entry per filter, nine per channel.
    var cdlmsOrder: [Int]
    var cdlmsScaling: [Int]
    var cdlmsRecent: [Int]

    /// One run per filter, ``cdlmsCoefficientStride`` or ``cdlmsHistoryStride`` apart.
    var cdlmsCoefficients: [Int16]
    var cdlmsHistory: [Int32]
    var cdlmsUpdates: [Int16]

    var movingAverageScaling = 0
    var quantStep = 1

    var isChannelCoded: [Bool]
    var updateSpeed: [Int]
    var transient: [Bool]
    var transientPosition: [Int]
    var transientCounter: [Int]
    var averageSum: [UInt32]

    /// One channel after another, `samplesPerFrame` apart.
    var channelResidues: [Int32]

    var lpcOrder = 0
    var lpcScaling = 0
    var lpcIntegerBits = 0

    /// Forty per channel.
    var lpcCoefficients: [Int32]

    static let filtersPerChannel = 9
    static let cdlmsCoefficientStride = 256 + 8
    static let cdlmsHistoryStride = 256 * 2 + 8

    // MARK: - Building

    init(format: WMAStreamFormat) throws(AudioReadError) {
        let configuration = try WMALosslessConfiguration(format: format)
        self.configuration = configuration
        reservoir = .init(
            codec: .lossless,
            blockAlign: configuration.blockAlign,
            log2FrameSize: configuration.log2FrameSize,
            hasLengthPrefix: configuration.hasLengthPrefix,
            maximumFrameBytes: configuration.maximumFrameSize
        )
        let channels = configuration.channelCount
        let frameLength = configuration.samplesPerFrame
        let filters = channels * Self.filtersPerChannel

        frameSamples = .init(repeating: 0, count: channels * frameLength)
        writePositions = .init(repeating: 0, count: channels)
        subframes = .init(repeating: LosslessChannelTiling(), count: channels)
        acHistory = .init(repeating: 0, count: channels * 16)
        cdlmsCount = .init(repeating: 0, count: channels)
        cdlmsOrder = .init(repeating: 0, count: filters)
        cdlmsScaling = .init(repeating: 0, count: filters)
        cdlmsRecent = .init(repeating: 0, count: filters)
        cdlmsCoefficients = .init(repeating: 0, count: filters * Self.cdlmsCoefficientStride)
        cdlmsHistory = .init(repeating: 0, count: filters * Self.cdlmsHistoryStride)
        cdlmsUpdates = .init(repeating: 0, count: filters * Self.cdlmsHistoryStride)
        isChannelCoded = .init(repeating: false, count: channels)
        updateSpeed = .init(repeating: 0, count: channels)
        transient = .init(repeating: false, count: channels)
        transientPosition = .init(repeating: 0, count: channels)
        transientCounter = .init(repeating: 0, count: channels)
        averageSum = .init(repeating: 0, count: channels)
        channelResidues = .init(repeating: 0, count: channels * frameLength)
        lpcCoefficients = .init(repeating: 0, count: channels * 40)
    }

    /// Drops the reservoir and waits for the next seekable tile, as FFmpeg's flush does.
    func reset() {
        reservoir.reset()
        cdlmsOrder[0] = 0
        frameSampleCount = 0
    }

    // MARK: - Decoding

    func decode(_ packet: Data) throws(AudioReadError) -> [Float] {
        var samples: [Float] = []
        decodeCalls(packet) { appendSamples(to: &samples) }
        return samples
    }

    /// Decodes the frames the reservoir still holds once the packets run out.
    func drain() -> [Float] {
        var samples: [Float] = []
        drainCalls { appendSamples(to: &samples) }
        return samples
    }

    /// The frames one media object yields, each as interleaved integer samples.
    func decodeFrames(_ packet: Data) -> [[Int32]] {
        var frames: [[Int32]] = []
        decodeCalls(packet) { frames.append(interleavedFrame()) }
        return frames
    }

    /// The frames FFmpeg's drain calls yield, which decode what the reservoir holds past the last
    /// packet.
    func drainFrames() -> [[Int32]] {
        var frames: [[Int32]] = []
        drainCalls { frames.append(interleavedFrame()) }
        return frames
    }

    /// Runs FFmpeg's packet decode on the same bytes until the calls consume them all.
    ///
    /// Each call yields one frame at most, and `frame` runs once for each. A call that reports a
    /// packet loss drops its frame and the rest of the object.
    private func decodeCalls(_ packet: Data, frame: () -> Void) {
        let bytes = packet.span
        var start = 0
        // a call that consumes no byte still moves the state, so the bound only stops a corrupt
        // loop
        var calls = 0

        while start < bytes.count, calls <= bytes.count + 16 {
            calls += 1
            frameSampleCount = 0
            guard let consumed = decodePacketPass(bytes, from: start) else { break }
            if frameSampleCount > 0 { frame() }
            if consumed >= bytes.count - start { break }
            start += consumed
        }
    }

    private func drainCalls(frame: () -> Void) {
        while reservoir.savedBits > reservoir.cursor {
            frameSampleCount = 0
            reservoir.packetDone = false
            if decodeFrame() == 0 { reservoir.savedBits = 0 }
            guard !reservoir.packetLoss, frameSampleCount > 0 else { break }
            frame()
        }
    }

    func decodeReservoirFrame() -> Bool { decodeFrame() != 0 }

    // MARK: - The output

    /// The finished frame, interleaved and cut to the samples it answers.
    private func interleavedFrame() -> [Int32] {
        let channels = configuration.channelCount
        let stride = configuration.samplesPerFrame
        let count = min(frameSampleCount, stride)
        var interleaved = [Int32](repeating: 0, count: count * channels)

        for channel in 0..<channels {
            let base = channel * stride

            for index in 0..<count {
                interleaved[index * channels + channel] = frameSamples[base + index]
            }
        }
        return interleaved
    }

    /// Appends the finished frame, interleaved and scaled to one by its container.
    ///
    /// A 16-bit sample holds its own value and a 24-bit one sits in the top of 32 bits.
    private func appendSamples(to samples: inout [Float]) {
        let channels = configuration.channelCount
        let stride = configuration.samplesPerFrame
        let count = min(frameSampleCount, stride)
        let scale: Float = configuration.bitsPerSample == 16 ? 1.0 / 32_768 : 1.0 / 2_147_483_648
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: count * channels))
        let frame = frameSamples
        let source = frame.span
        var output = samples.mutableSpan

        for channel in 0..<channels {
            let base = channel * stride

            for index in 0..<count {
                output[start + index * channels + channel] = Float(source[base + index]) * scale
            }
        }
    }
}

/// How one channel's share of a frame splits into subframes.
struct LosslessChannelTiling {
    var count = 0

    /// One more slot than a frame holds, because FFmpeg reads the entry past the last subframe.
    var lengths = [Int](repeating: 0, count: WMALosslessConfiguration.maximumSubframeCount + 1)
    var current = 0
    var decodedSamples = 0
}
