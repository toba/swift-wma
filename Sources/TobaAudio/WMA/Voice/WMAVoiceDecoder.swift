internal import Foundation

/// Decodes a WMA Voice stream, a CELP speech codec, into mono samples.
///
/// A codec packet is `blockAlign` bytes and carries superframes of 480 samples, the last of which
/// runs into the packet behind it. The decoder holds that tail and decodes the superframe once the
/// next packet arrives, so ``drain()`` answers the one a stream ends on.
final class WMAVoiceDecoder: WMAStreamDecoder {
    static let formatTag = 0x000A

    static let frameSize = 160
    static let superframeSize = 480
    static let maximumLSPs = 16
    static let maximumHistory = 416
    static let cacheCapacity = 256

    // MARK: - The stream header

    let blockAlign: Int

    /// How many bits state the spillover length in a packet header.
    let spilloverWidth: Int

    /// How many past excitation samples the adaptive codebook reaches back through.
    let historyCount: Int

    let usesPostfilter: Bool
    let denoiseStrength: Int
    let correctsDenoiseTilt: Bool
    let dcLevel: Int

    /// Ten or sixteen.
    let lspCount: Int
    let lspQuantizerMode: Bool
    let lspDefaultMode: Int

    let minimumPitch: Int
    let maximumPitch: Int
    let pitchWidth: Int
    let blockPitchWidth: Int
    let blockPitchRange: Int
    let blockDeltaPitchWidth: Int
    let blockDeltaPitchHalfRange: Int
    let blockConversion: [Int]

    /// Maps a frame type code to a row of ``WMAVoiceFrameType/all``, or to minus one.
    let frameTypes: [Int]

    /// The mean LSFs the coded values are offsets from.
    let meanLSF: [Double]

    // MARK: - The packet state

    var spilloverCount = 0
    var hasResidualLSPs = false
    var skipBitsNext = 0
    var superframeCount = 0

    /// The bits of a superframe that runs into the next packet.
    var cache = WMABitWriter()
    var cacheBits = 0

    // MARK: - The frame state

    var previousLSPs: [Double]
    var lastPitch = 40
    var lastAdaptiveType = WMAVoiceFrameType.Adaptive.none
    var pitchDifference = 0
    var silenceGain: Float = 0
    var pulseIndexExtended = false
    var pulseRange = 0
    var pulseCounts = [0, 0]
    var firstPulseOffsets = [0, 0]
    var nextPulseOffset = 0
    var frameCounter = 0
    var gainPredictionError = [Float](repeating: 0, count: 6)
    var excitationHistory = [Float](repeating: 0, count: WMAVoiceDecoder.maximumHistory)
    var synthesisHistory = [Float](repeating: 0, count: WMAVoiceDecoder.maximumLSPs)

    // MARK: - The postfilter state

    let transform = WMAVoiceTransform(length: 128, inverse: false, scale: 1)
    let inverseTransform = WMAVoiceTransform(length: 128, inverse: true, scale: 1)
    let dcst = WMAVoiceDCST(count: 64, scale: 1.0 / 64)

    /// A sine window over the half circle, extended to the whole circle, 511 entries each.
    let sines: [Float]
    let cosines: [Float]

    var postfilterGain: Float = 0
    var dcFilterMemory: (Float, Float) = (0, 0)
    var zeroExcitation = [Float](
        repeating: 0, count: WMAVoiceDecoder.maximumHistory + WMAVoiceDecoder.superframeSize)
    var denoiseCache = [Float](repeating: 0, count: WMAVoiceDecoder.frameSize)
    var denoiseCacheCount = 0
    var tiltedLPCs = [Float](repeating: 0, count: 0x82)
    var denoiseCoefficients = [Float](repeating: 0, count: 0x82)

    /// The postfilter's synthesis output, with sixteen samples of history in front of it.
    var postfilterOutput = [Float](repeating: 0, count: 0x80 + WMAVoiceDecoder.maximumLSPs)

    /// The buffers a superframe decodes through, lent out for the length of one superframe.
    var scratch: WMAVoiceScratch? = WMAVoiceScratch()

    // MARK: - Building

    init(format: WMAStreamFormat) throws(AudioReadError) {
        let extra = [UInt8](format.extra)
        guard extra.count == 46 else { throw .malformed("WMA Voice extra data length") }
        guard format.blockAlign > 0, format.blockAlign <= 1 << 22
        else { throw .malformed("WMA Voice block alignment") }
        blockAlign = format.blockAlign

        let flags = Int(extra[18]) | Int(extra[19]) << 8 | Int(extra[20]) << 16
            | Int(extra[21]) << 24
        spilloverWidth = 3 + WMAMath.ceilLog2(format.blockAlign)
        usesPostfilter = flags & 0x1 != 0
        denoiseStrength = (flags >> 2) & 0xF
        guard denoiseStrength < 12 else { throw .malformed("WMA Voice denoise strength") }
        correctsDenoiseTilt = flags & 0x40 != 0
        dcLevel = (flags >> 7) & 0xF
        lspQuantizerMode = flags & 0x2000 != 0
        let defaultMode = flags & 0x4000 != 0 ? 1 : 0
        lspDefaultMode = defaultMode
        let lsps = flags & 0x1000 != 0 ? 16 : 10
        lspCount = lsps
        let means = lsps == 16 ? WMAVoiceTables.meanLSF16 : WMAVoiceTables.meanLSF10
        meanLSF = Array(means[(defaultMode * lsps)..<((defaultMode + 1) * lsps)])
        previousLSPs = (0..<WMAVoiceDecoder.maximumLSPs).map {
            Double.pi * (Double($0) + 1) / (Double(lsps) + 1)
        }
        frameTypes = try WMAVoiceDecoder.frameTypeTree(Array(extra[22...]))

        let rate = format.sampleRate
        guard rate > 0, rate < Int(Int32.max) / (256 * 37)
        else { throw .malformed("WMA Voice sample rate") }
        minimumPitch = ((rate << 8) / 400 + 50) >> 8
        maximumPitch = ((rate << 8) * 37 / 2000 + 50) >> 8
        let range = maximumPitch - minimumPitch
        guard range > 0 else { throw .malformed("WMA Voice pitch range") }
        pitchWidth = WMAMath.ceilLog2(range)
        historyCount = maximumPitch + 8
        guard minimumPitch >= 1, historyCount <= WMAVoiceDecoder.maximumHistory
        else { throw .malformed("WMA Voice sample rate \(rate)") }

        let conversion = [minimumPitch, (range * 25) >> 6, (range * 44) >> 6, maximumPitch - 1]
        blockConversion = conversion
        blockDeltaPitchHalfRange = (range >> 3) & ~0xF
        guard blockDeltaPitchHalfRange > 0 else { throw .malformed("WMA Voice delta pitch range") }
        blockDeltaPitchWidth = 1 + WMAMath.ceilLog2(blockDeltaPitchHalfRange)
        blockPitchRange = conversion[2] + conversion[3] + 1
            + 2 * (conversion[1] - 2 * minimumPitch)
        blockPitchWidth = WMAMath.ceilLog2(blockPitchRange)

        var window = [Float](repeating: 0, count: 511)
        var cosine = [Float](repeating: 0, count: 511)

        for i in 0..<256 { cosine[i] = sinf(Float((Double(i) + 0.5) * (Double.pi / 512))) }
        for i in 0..<256 { window[255 + i] = cosine[i] }

        for i in 0..<255 {
            window[i] = -window[510 - i]
            cosine[510 - i] = cosine[i]
        }
        sines = window
        cosines = cosine
    }

    /// Reads the 17 three-bit groups that map a frame type code to its row.
    private static func frameTypeTree(_ bytes: [UInt8]) throws(AudioReadError) -> [Int] {
        var tree = [Int](repeating: -1, count: 25)
        var counts = [Int](repeating: 0, count: 8)
        var reader = BitReader(bytes.span)

        for row in 0..<17 {
            let group = Int(reader.read(3))
            guard counts[group] <= 3 else { throw .malformed("WMA Voice frame type tree") }
            tree[group * 3 + counts[group]] = row
            counts[group] += 1
        }
        return tree
    }

    // MARK: - Decoding

    func decode(_ packet: Data) throws(AudioReadError) -> [Float] {
        let bytes = packet.span
        var samples: [Float] = []
        var offset = 0

        // a media object holds whole codec packets, and each call below consumes at most one
        // superframe, the way FFmpeg's decode loop feeds the rest of a packet back in
        while offset < bytes.count {
            guard let consumed = step(bytes, from: offset, into: &samples), consumed > 0
            else { break }
            offset += consumed
        }
        return samples
    }

    /// Decodes the superframe the last packet left in the cache.
    func drain() -> [Float] {
        let empty: [UInt8] = []
        var samples: [Float] = []
        _ = step(empty.span, from: 0, into: &samples)
        return samples
    }

    /// Restores every value the stream started with, so a replay from the first packet decodes what
    /// the first pass decoded.
    func reset() {
        flush()
        spilloverCount = 0
        hasResidualLSPs = false
        superframeCount = 0
        cache.reset()

        for n in 0..<Self.maximumLSPs {
            previousLSPs[n] = Double.pi * (Double(n) + 1) / (Double(lspCount) + 1)
        }
        lastPitch = 40
        lastAdaptiveType = .none
        pitchDifference = 0
        silenceGain = 0
        pulseIndexExtended = false
        pulseRange = 0
        pulseCounts = [0, 0]
        firstPulseOffsets = [0, 0]
        nextPulseOffset = 0
        frameCounter = 0

        dcFilterMemory = (0, 0)
        denoiseCacheCount = 0
        for i in zeroExcitation.indices { zeroExcitation[i] = 0 }
        for i in denoiseCache.indices { denoiseCache[i] = 0 }
        for i in tiltedLPCs.indices { tiltedLPCs[i] = 0 }
        for i in denoiseCoefficients.indices { denoiseCoefficients[i] = 0 }
        for i in postfilterOutput.indices { postfilterOutput[i] = 0 }
    }

    /// Clears what a damaged superframe leaves, FFmpeg's `wmavoice_flush`.
    func flush() {
        postfilterGain = 0
        cacheBits = 0
        skipBitsNext = 0

        for n in 0..<lspCount {
            previousLSPs[n] = Double.pi * (Double(n) + 1) / (Double(lspCount) + 1)
        }
        for i in excitationHistory.indices { excitationHistory[i] = 0 }
        for i in synthesisHistory.indices { synthesisHistory[i] = 0 }
        for i in gainPredictionError.indices { gainPredictionError[i] = 0 }

        if usesPostfilter {
            for i in (Self.maximumLSPs - lspCount)..<Self.maximumLSPs { postfilterOutput[i] = 0 }
            dcFilterMemory = (0, 0)
            for i in 0..<historyCount { zeroExcitation[i] = 0 }
            for i in denoiseCache.indices { denoiseCache[i] = 0 }
        }
    }

    // MARK: - One call of FFmpeg's decode loop

    /// Decodes at most one superframe from the bytes at `start`, and answers how many it consumed.
    ///
    /// The bytes up to the next `blockAlign` boundary are the current codec packet, and one that
    /// starts at that boundary opens with its header. `nil` drops the rest of the object.
    private func step(_ bytes: Span<UInt8>, from start: Int, into samples: inout [Float]) -> Int? {
        let total = bytes.count - start
        var size = total

        while size > blockAlign { size -= blockAlign }
        let data = bytes.extracting(start..<(start + size))
        var reader = BitReader(data)
        let limit = size * 8

        if size % blockAlign == 0 {
            if size == 0 {
                spilloverCount = 0
                superframeCount = 0
            } else {
                guard let count = readHeader(&reader, limit: limit) else { return nil }
                superframeCount = count
            }

            if cacheBits > 0 {
                let counted = reader.cursor
                if counted + spilloverCount > total * 8 { spilloverCount = total * 8 - counted }
                copyBits(&reader, from: data, limit: limit, count: spilloverCount)

                if synthesizeCached(into: &samples) {
                    let consumed = counted + spilloverCount
                    skipBitsNext = consumed & 7
                    return consumed >> 3
                }
                reader.skip(spilloverCount - counted + reader.cursor)
            } else if spilloverCount > 0 { reader.skip(spilloverCount) }
        } else if skipBitsNext > 0 { reader.skip(skipBitsNext) }

        cacheBits = 0
        skipBitsNext = 0
        let position = limit - reader.cursor
        let remaining = superframeCount
        superframeCount -= 1

        if remaining == 0 { return size }

        if superframeCount > 0 {
            do {
                try synthesizeSuperframe(&reader, limit: limit, into: &samples)
            } catch {
                return nil
            }
            let consumed = reader.cursor
            skipBitsNext = consumed & 7
            return consumed >> 3
        }

        if position > 0 {
            cache.reset()
            copyBits(&reader, from: data, limit: limit, count: position)
        }
        return size
    }

    /// Reads the packet header, and answers how many superframes start in the packet.
    @_lifetime(reader: copy reader)
    private func readHeader(_ reader: inout BitReader, limit: Int) -> Int? {
        reader.skip(4)
        hasResidualLSPs = reader.readBit()
        var count = 0
        var field = 0

        repeat {
            guard limit - reader.cursor >= 6 + spilloverWidth else { return nil }
            field = Int(reader.read(6))
            count += field
        } while field == 0x3F

        spilloverCount = Int(reader.read(spilloverWidth))
        return limit - reader.cursor >= 0 ? count : nil
    }

    /// Decodes the superframe held in the cache, and answers whether it produced one.
    private func synthesizeCached(into samples: inout [Float]) -> Bool {
        let held = cache.bytes
        let limit = cacheBits
        cacheBits = 0
        var reader = BitReader(held.span)

        do {
            try synthesizeSuperframe(&reader, limit: limit, into: &samples)
            return true
        } catch {
            return false
        }
    }

    // MARK: - The spillover cache

    /// Copies `count` bits from the reader into the cache, or nothing when either side is short,
    /// and sets `cacheBits` to what the cache then holds.
    ///
    /// The reader then sits past the bits up to the next byte boundary alone, because FFmpeg's
    /// `copy_bits` copies the whole bytes behind them straight from the packet.
    @_lifetime(reader: copy reader)
    func copyBits(_ reader: inout BitReader, from data: Span<UInt8>, limit: Int, count: Int) {
        defer { cacheBits = cache.count }
        let start = reader.cursor
        guard count >= 0,
              limit - start >= count,
              count <= Self.cacheCapacity * 8 - cache.count else { return }
        let partial = min((limit - start) & 7, count)
        cache.write(reader.read(partial), width: partial)
        cache.copy(data, fromByte: reader.cursor >> 3, bits: count - partial)
    }
}
