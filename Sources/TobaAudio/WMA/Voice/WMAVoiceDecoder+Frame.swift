internal import Foundation

/// The superframe, its three frames and the blocks each frame splits into.
///
/// A frame builds an excitation from an adaptive codebook and a fixed codebook of pulses, and the
/// LPC synthesis filter turns it into speech. The arrays carry their history in front of the
/// samples a frame writes.
extension WMAVoiceDecoder {
    // MARK: - The superframe

    /// Decodes one superframe of three frames and appends the samples it states.
    @_lifetime(reader: copy reader)
    func synthesizeSuperframe(
        _ reader: inout BitReader,
        limit: Int,
        into output: inout [Float]
    ) throws(AudioReadError) {
        let lsps = lspCount
        let size = Self.maximumLSPs
        var work = scratch.take() ?? WMAVoiceScratch()
        defer { scratch = work }

        for i in work.synthesis.indices { work.synthesis[i] = 0 }
        for i in work.excitation.indices { work.excitation[i] = 0 }
        for i in work.samples.indices { work.samples[i] = 0 }
        for i in work.frameLSPs.indices { work.frameLSPs[i] = 0 }
        for i in 0..<lsps { work.synthesis[i] = synthesisHistory[i] }
        for i in 0..<historyCount { work.excitation[i] = excitationHistory[i] }

        // a superframe that clears this bit carries WMA Pro, which no known file does
        guard reader.readBit() else { throw .malformed("WMA Voice music superframe") }
        var sampleCount = Self.superframeSize

        if reader.readBit() {
            sampleCount = Int(reader.read(12))
            guard sampleCount <= Self.superframeSize else {
                throw .malformed("WMA Voice superframe length")
            }
        }

        let mean = meanLSF

        if hasResidualLSPs {
            for n in 0..<lsps { work.residualPrevious[n] = previousLSPs[n] - mean[n] }

            if lsps == 10 {
                Self.readLSP10Residual(
                    &reader, into: &work.frameLSPs, at: 2 * size,
                    previous: work.residualPrevious, mode: lspQuantizerMode,
                    first: &work.residualFirst, second: &work.residualSecond)
            } else {
                Self.readLSP16Residual(
                    &reader, into: &work.frameLSPs, at: 2 * size,
                    previous: work.residualPrevious, mode: lspQuantizerMode,
                    first: &work.residualFirst, second: &work.residualSecond)
            }

            for n in 0..<lsps {
                work.frameLSPs[n] = mean[n] + (work.residualFirst[n] - work.residualSecond[n * 2])
                work.frameLSPs[size + n] = mean[n]
                    + (work.residualFirst[lsps + n] - work.residualSecond[n * 2 + 1])
                work.frameLSPs[2 * size + n] += mean[n]
            }
            for n in 0..<3 { Self.stabilize(&work.frameLSPs, at: n * size, count: lsps) }
        }

        for n in 0..<3 {
            if !hasResidualLSPs {
                if lsps == 10 {
                    Self.readLSP10(&reader, into: &work.frameLSPs, at: n * size)
                } else {
                    Self.readLSP16(&reader, into: &work.frameLSPs, at: n * size)
                }
                for m in 0..<lsps { work.frameLSPs[n * size + m] += mean[m] }
                Self.stabilize(&work.frameLSPs, at: n * size, count: lsps)
            }

            for m in 0..<lsps {
                work.lsps[m] = work.frameLSPs[n * size + m]
                work.previous[m] = n == 0 ? previousLSPs[m] : work.frameLSPs[(n - 1) * size + m]
            }
            try synthesizeFrame(&reader, index: n, work: &work)
        }

        // the encoder's statistics, which no step reads
        if reader.readBit() {
            let count = Int(reader.read(4))
            reader.skip(10 * (count + 1))
        }
        guard limit - reader.cursor >= 0 else {
            flush()
            throw .malformed("WMA Voice superframe ran short")
        }
        output.append(contentsOf: work.samples[0..<sampleCount])

        for i in 0..<lsps { previousLSPs[i] = work.frameLSPs[2 * size + i] }
        for i in 0..<lsps { synthesisHistory[i] = work.synthesis[Self.superframeSize + i] }

        let history = historyCount
        excitationHistory.withExclusiveAccess { past in
            for i in 0..<history { past[i] = work.excitation[Self.superframeSize + i] }
        }

        if usesPostfilter {
            zeroExcitation.withExclusiveAccess { zero in
                for i in 0..<history { zero[i] = zero[Self.superframeSize + i] }
            }
        }
    }

    // MARK: - One frame

    /// Decodes one frame of 160 samples into `work.samples` at `160 * index`, between the LSFs in
    /// `work.previous` and `work.lsps`.
    @_lifetime(reader: copy reader)
    private func synthesizeFrame(
        _ reader: inout BitReader,
        index frame: Int,
        work: inout WMAVoiceScratch
    ) throws(AudioReadError) {
        let row = frameTypes[WMAVoiceFrameType.readCode(&reader)]
        guard row >= 0 else { throw .malformed("WMA Voice frame type") }
        let type = WMAVoiceFrameType.all[row]
        let blockSize = Self.frameSize / type.blocks
        let unset = Int(Int32.max)
        var pitch = InlineArray<8, Int>(repeating: unset)
        var currentPitch = 0

        if type.adaptive == .asymmetric {
            let doubled = type.blocks << 1
            let logDoubled = type.logBlocks + 1
            currentPitch = min(minimumPitch + Int(reader.read(pitchWidth)), maximumPitch - 1)

            if lastAdaptiveType == .none
                || 20 * abs(currentPitch - lastPitch) > currentPitch + lastPitch {
                lastPitch = currentPitch
            }

            for n in 0..<type.blocks {
                let weight = n * 2 + 1
                pitch[n] =
                    (weight * currentPitch + (doubled - weight) * lastPitch + type.blocks)
                    >> logDoubled
            }
            pitchDifference = (currentPitch - lastPitch) * (1 << 16) / Self.frameSize
        }

        switch type.fixed {
            case .silence: silenceGain = WMAVoiceTables.silenceGain[Int(reader.read(8))]
            case .adaptiveWindowPulses: readPulseCoordinates(&reader, pitch: pitch[0], pitch[1])
            default: break
        }

        var lastBlockPitch = 0

        for n in 0..<type.blocks {
            var blockPitch = 0

            switch type.adaptive {
                case .hamming:
                    blockPitch = readBlockPitch(&reader, block: n, last: &lastBlockPitch)
                    pitch[n] = blockPitch >> 2
                case .asymmetric: blockPitch = pitch[n] << 2
                case .none: break
            }
            synthesizeBlock(
                &reader,
                block: n,
                size: blockSize,
                pitch: blockPitch,
                type: type,
                work: &work,
                excitationAt: historyCount + frame * Self.frameSize + n * blockSize,
                synthesisAt: lspCount + frame * Self.frameSize + n * blockSize
            )
        }

        let sampleStart = frame * Self.frameSize
        let synthesisStart = lspCount + frame * Self.frameSize

        if usesPostfilter {
            if type.fixed >= .adaptiveWindowPulses, pitch[0] == unset {
                throw .malformed("WMA Voice pitch")
            }

            for n in 0..<lspCount {
                work.lspCosines[n] = cos(0.5 * (work.previous[n] + work.lsps[n]))
            }
            CELPFilters.lpc(fromLSP: work.lspCosines, halfOrder: lspCount >> 1, into: &work.lpcs)
            postfilter(
                work: &work, synthesisAt: synthesisStart, sampleAt: sampleStart,
                zeroStart: historyCount + Self.frameSize * frame, fixed: type.fixed,
                pitch: pitch[0])

            for n in 0..<lspCount { work.lspCosines[n] = cos(work.lsps[n]) }
            CELPFilters.lpc(fromLSP: work.lspCosines, halfOrder: lspCount >> 1, into: &work.lpcs)
            postfilter(
                work: &work, synthesisAt: synthesisStart + 80, sampleAt: sampleStart + 80,
                zeroStart: historyCount + Self.frameSize * frame + 80, fixed: type.fixed,
                pitch: pitch[0])
        } else {
            for i in 0..<Self.frameSize {
                work.samples[sampleStart + i] = work.synthesis[synthesisStart + i]
            }
        }

        frameCounter += 1
        if frameCounter >= 0xFFFF { frameCounter -= 0xFFFF }
        lastAdaptiveType = type.adaptive

        switch type.adaptive {
            case .none: lastPitch = 0
            case .asymmetric: lastPitch = currentPitch
            case .hamming: lastPitch = pitch[type.blocks - 1]
        }
    }

    /// Reads one block's pitch, stated absolutely for the first block and as a delta after it.
    ///
    /// The coded value runs on a semi-logarithmic scale, and the answer is the pitch times four.
    @_lifetime(reader: copy reader)
    private func readBlockPitch(_ reader: inout BitReader, block: Int, last: inout Int) -> Int {
        let table = blockConversion
        let t1 = (table[1] - table[0]) << 2
        let t2 = (table[2] - table[1]) << 1
        let t3 = table[3] - table[2] + 1
        var value = block == 0
            ? Int(reader.read(blockPitchWidth))
            : last - blockDeltaPitchHalfRange + Int(reader.read(blockDeltaPitchWidth))

        last = max(blockDeltaPitchHalfRange, min(value, blockPitchRange - blockDeltaPitchHalfRange))

        if value < t1 { return (table[0] << 2) + value }
        value -= t1
        if value < t2 { return (table[1] << 2) + (value << 1) }
        value -= t2
        return value < t3 ? (table[2] + value) << 2 : table[3] << 2
    }

    // MARK: - One block

    @_lifetime(reader: copy reader)
    private func synthesizeBlock(
        _ reader: inout BitReader,
        block: Int,
        size: Int,
        pitch: Int,
        type: WMAVoiceFrameType,
        work: inout WMAVoiceScratch,
        excitationAt excitationStart: Int,
        synthesisAt synthesisStart: Int
    ) {
        if type.adaptive == .none {
            fillHardcoded(
                &reader, block: block, size: size, type: type, into: &work.excitation,
                at: excitationStart)
        } else {
            fillCodebooks(
                &reader, block: block, size: size, pitch: pitch, type: type, work: &work,
                at: excitationStart)
        }

        let fraction = Float((Double(block) + 0.5) / Double(type.blocks))

        for n in 0..<lspCount {
            let previous = work.previous[n]
            work.lspCosines[n] = cos(previous + Double(fraction) * (work.lsps[n] - previous))
        }
        CELPFilters.lpc(fromLSP: work.lspCosines, halfOrder: lspCount >> 1, into: &work.lpcs)
        CELPFilters.synthesize(
            &work.synthesis, at: synthesisStart, coefficients: work.lpcs, input: work.excitation,
            from: excitationStart, count: size, order: lspCount)
    }

    /// Fills a block from the fixed 1000-entry codebook, at a pseudo-random or a coded start.
    @_lifetime(reader: copy reader)
    private func fillHardcoded(
        _ reader: inout BitReader,
        block: Int,
        size: Int,
        type: WMAVoiceFrameType,
        into excitation: inout [Float],
        at start: Int
    ) {
        let index: Int
        let gain: Float

        if type.fixed == .silence {
            index = WMAVoiceFrameType.codebookStart(frame: frameCounter, block: block, size: size)
            gain = silenceGain
        } else {
            index = Int(reader.read(8))
            gain = WMAVoiceTables.universalGain[Int(reader.read(6))]
        }
        for i in gainPredictionError.indices { gainPredictionError[i] = 0 }

        for n in 0..<size {
            excitation[start + n] = WMAVoiceTables.standardCodebook[index + n] * gain
        }
    }

    /// The weights the gain prediction applies to the last six errors.
    private static let gainWeights: [Float] = [0.8169, -0.06545, 0.1726, 0.0185, -0.0359, 0.0458]

    /// Fills a block from the adaptive codebook and the fixed pulses, weighted by their gains.
    @_lifetime(reader: copy reader)
    private func fillCodebooks(
        _ reader: inout BitReader,
        block: Int,
        size: Int,
        pitch blockPitch: Int,
        type: WMAVoiceFrameType,
        work: inout WMAVoiceScratch,
        at start: Int
    ) {
        for i in 0..<size { work.pulses[i] = 0 }
        var fixed = FixedPulses()
        fixed.pitchLag = blockPitch >> 2

        if type.fixed == .adaptiveWindowPulses {
            readFirstPulses(&reader, block: block, into: &fixed)

            guard readSecondPulse(&reader, block: block, into: &fixed) else {
                // conceal the block as silence, and skip the gain the block still carries
                let index = WMAVoiceFrameType.codebookStart(
                    frame: frameCounter, block: block, size: size)

                for n in 0..<size {
                    work.excitation[start + n] = WMAVoiceTables.standardCodebook[index + n]
                        * silenceGain
                }
                reader.skip(7 + 1)
                return
            }
        } else {
            let width = 5 - type.logBlocks
            fixed.noRepeatMask = -1

            for n in 0..<5 {
                let sign: Float = reader.readBit() ? 1 : -1
                let first = Int(reader.read(width))
                fixed.add(n + 5 * first, sign)

                if n < type.doublePulses {
                    let second = Int(reader.read(width))
                    fixed.add(n + 5 * second, first < second ? -sign : sign)
                }
            }
        }
        fixed.place(into: &work.pulses, count: size)

        let index = Int(reader.read(7))
        let predicted = CELPFilters.dot(gainPredictionError, 0, Self.gainWeights, 0, 6)
        let fixedLog = WMAVoiceTables.fixedGainLog[index]
        let fixedGain = expf(Float(Double(predicted) - 5.2409161640 + Double(fixedLog)))
        let adaptiveGain = WMAVoiceTables.adaptiveGain[index]
        let error = max(Float(-2.9957322736), min(fixedLog, Float(1.6094379124)))
        let weight = 8 >> type.logBlocks

        for i in stride(from: 5, through: weight, by: -1) {
            gainPredictionError[i] = gainPredictionError[i - weight]
        }
        for i in 0..<weight { gainPredictionError[i] = error }

        if type.adaptive == .asymmetric {
            var n = 0

            while n < size {
                let pitchScaled = (lastPitch << 16) + pitchDifference * (block * size + n)
                let pitch = (pitchScaled + 0x6FFF) >> 16
                let phaseScaled = ((pitch << 16) - pitchScaled) * 8 + 0x58000
                var length = size

                if pitchDifference != 0 {
                    let next = pitchDifference > 0
                        ? phaseScaled & ~0xFFFF
                        : (phaseScaled + 0x10000) & ~0xFFFF
                    length = max(1, min((phaseScaled - next) / pitchDifference / 8, size - n))
                }
                CELPFilters.interpolate(
                    &work.excitation, into: start + n, from: start + n - pitch,
                    filter: WMAVoiceTables.asymmetricInterpolation, precision: 17,
                    phase: phaseScaled >> 16, taps: 9, count: length)
                n += length
            }
        } else {
            let pitch = blockPitch >> 2
            let phase = blockPitch & 3

            if phase != 0 {
                CELPFilters.interpolate(
                    &work.excitation, into: start, from: start - pitch,
                    filter: WMAVoiceTables.hammingInterpolation, precision: 4, phase: phase,
                    taps: 8, count: size)
            } else {
                for i in 0..<size {
                    work.excitation[start + i] = work.excitation[start + i - pitch]
                }
            }
        }

        for i in 0..<size {
            work.excitation[start + i] = adaptiveGain * work.excitation[start + i] + fixedGain
                * work.pulses[i]
        }
    }

    // MARK: - The line spectral pairs

    private static let lsp10Sizes = [256, 64, 32, 32]
    private static let lsp10Multipliers = [
        5.2187144800e-3, 1.4626986422e-3, 9.6179549166e-4, 1.1325736225e-3,
    ]
    private static let lsp10Bases = [-2.15522e-1, -6.1646e-2, -3.3486e-2, -5.7408e-2]
        .map { Double.pi * $0 }

    private static let lsp16Sizes = [256, 64, 128, 64, 128]
    private static let lsp16Multipliers = [
        3.3439586280e-3, 6.9908173703e-4, 3.3216608306e-3, 1.0334960326e-3, 3.1899104283e-3,
    ]
    private static let lsp16Bases = [-1.27576e-1, -2.4292e-2, -1.28094e-1, -3.2128e-2, -1.29816e-1]
        .map { Double.pi * $0 }

    private static let lsp10ResidualSizes = [128, 64, 64]
    private static let lsp10ResidualMultipliers = [
        2.5807601174e-3, 1.2354460219e-3, 1.1763821673e-3,
    ]
    private static let lsp10ResidualBases = [-1.07448e-1, -5.2706e-2, -5.1634e-2]
        .map { Double.pi * $0 }

    private static let lsp16ResidualSizes = [128, 128, 128]
    private static let lsp16ResidualMultipliers = [
        1.2232979501e-3, 1.4062241527e-3, 1.6114744851e-3,
    ]
    private static let lsp16ResidualBases = [-5.5830e-2, -5.2908e-2, -5.4776e-2]
        .map { Double.pi * $0 }

    /// Adds the codebook row of each stage in `stages` to `lsps`, FFmpeg's `dequant_lsps`.
    private static func dequantize(
        _ lsps: inout [Double],
        at start: Int,
        count: Int,
        values: InlineArray<5, Int>,
        stages: Range<Int>,
        sizes: [Int],
        table: [UInt8],
        multipliers: [Double],
        bases: [Double]
    ) {
        for m in 0..<count { lsps[start + m] = 0 }
        var offset = 0

        for n in stages {
            let row = offset + values[n] * count

            for m in 0..<count {
                lsps[start + m] += bases[n] + multipliers[n] * Double(table[row + m])
            }
            offset += sizes[n] * count
        }
    }

    /// Reads ten independently coded LSPs, 24 bits, into `lsps` at `start`.
    @_lifetime(reader: copy reader)
    static func readLSP10(_ reader: inout BitReader, into lsps: inout [Double], at start: Int) {
        var values = InlineArray<5, Int>(repeating: 0)
        values[0] = Int(reader.read(8))
        values[1] = Int(reader.read(6))
        values[2] = Int(reader.read(5))
        values[3] = Int(reader.read(5))

        dequantize(
            &lsps, at: start, count: 10, values: values, stages: 0..<4, sizes: lsp10Sizes,
            table: WMAVoiceTables.lsp10i, multipliers: lsp10Multipliers, bases: lsp10Bases)
    }

    /// Reads sixteen independently coded LSPs, 34 bits, into `lsps` at `start`.
    @_lifetime(reader: copy reader)
    static func readLSP16(_ reader: inout BitReader, into lsps: inout [Double], at start: Int) {
        var values = InlineArray<5, Int>(repeating: 0)
        values[0] = Int(reader.read(8))
        values[1] = Int(reader.read(6))
        values[2] = Int(reader.read(7))
        values[3] = Int(reader.read(6))
        values[4] = Int(reader.read(7))

        dequantize(
            &lsps, at: start, count: 5, values: values, stages: 0..<2, sizes: lsp16Sizes,
            table: WMAVoiceTables.lsp16i1, multipliers: lsp16Multipliers, bases: lsp16Bases)
        dequantize(
            &lsps, at: start + 5, count: 5, values: values, stages: 2..<4, sizes: lsp16Sizes,
            table: WMAVoiceTables.lsp16i2, multipliers: lsp16Multipliers, bases: lsp16Bases)
        dequantize(
            &lsps, at: start + 10, count: 6, values: values, stages: 4..<5, sizes: lsp16Sizes,
            table: WMAVoiceTables.lsp16i3, multipliers: lsp16Multipliers, bases: lsp16Bases)
    }

    /// Reads ten LSPs coded once per superframe into `lsps` at `start`, and writes the two tables
    /// the other frames derive theirs from.
    @_lifetime(reader: copy reader)
    static func readLSP10Residual(
        _ reader: inout BitReader,
        into lsps: inout [Double],
        at start: Int,
        previous: [Double],
        mode: Bool,
        first: inout [Double],
        second: inout [Double]
    ) {
        readLSP10(&reader, into: &lsps, at: start)
        let interpolation = Int(reader.read(5))
        var values = InlineArray<5, Int>(repeating: 0)
        values[0] = Int(reader.read(7))
        values[1] = Int(reader.read(6))
        values[2] = Int(reader.read(6))
        let weights = mode
            ? WMAVoiceTables.lsp10InterpolationB
            : WMAVoiceTables.lsp10InterpolationA

        for n in 0..<10 {
            let lsp = lsps[start + n]
            let delta = previous[n] - lsp
            first[n] = Double(weights[interpolation * 20 + n]) * delta + lsp
            first[10 + n] = Double(weights[interpolation * 20 + 10 + n]) * delta + lsp
        }
        dequantize(
            &second, at: 0, count: 20, values: values, stages: 0..<3,
            sizes: lsp10ResidualSizes, table: WMAVoiceTables.lsp10r,
            multipliers: lsp10ResidualMultipliers, bases: lsp10ResidualBases)
    }

    /// Reads sixteen LSPs coded once per superframe into `lsps` at `start`, and writes the two
    /// tables the other frames derive theirs from.
    @_lifetime(reader: copy reader)
    static func readLSP16Residual(
        _ reader: inout BitReader,
        into lsps: inout [Double],
        at start: Int,
        previous: [Double],
        mode: Bool,
        first: inout [Double],
        second: inout [Double]
    ) {
        readLSP16(&reader, into: &lsps, at: start)
        let interpolation = Int(reader.read(5))
        var values = InlineArray<5, Int>(repeating: 0)
        values[0] = Int(reader.read(7))
        values[1] = Int(reader.read(7))
        values[2] = Int(reader.read(7))
        let weights = mode
            ? WMAVoiceTables.lsp16InterpolationB
            : WMAVoiceTables.lsp16InterpolationA

        for n in 0..<16 {
            let lsp = lsps[start + n]
            let delta = previous[n] - lsp
            first[n] = Double(weights[interpolation * 32 + n]) * delta + lsp
            first[16 + n] = Double(weights[interpolation * 32 + 16 + n]) * delta + lsp
        }
        dequantize(
            &second, at: 0, count: 10, values: values, stages: 0..<1,
            sizes: lsp16ResidualSizes, table: WMAVoiceTables.lsp16r1,
            multipliers: lsp16ResidualMultipliers, bases: lsp16ResidualBases)
        dequantize(
            &second, at: 10, count: 10, values: values, stages: 1..<2,
            sizes: lsp16ResidualSizes, table: WMAVoiceTables.lsp16r2,
            multipliers: lsp16ResidualMultipliers, bases: lsp16ResidualBases)
        dequantize(
            &second, at: 20, count: 12, values: values, stages: 2..<3,
            sizes: lsp16ResidualSizes, table: WMAVoiceTables.lsp16r3,
            multipliers: lsp16ResidualMultipliers, bases: lsp16ResidualBases)
    }

    /// Holds the `count` LSFs at `start` apart and in order, FFmpeg's `stabilize_lsps`.
    static func stabilize(_ lsps: inout [Double], at start: Int = 0, count: Int) {
        lsps[start] = max(lsps[start], 0.0015 * Double.pi)

        for n in 1..<count {
            lsps[start + n] = max(lsps[start + n], lsps[start + n - 1] + 0.0125 * Double.pi)
        }
        lsps[start + count - 1] = min(lsps[start + count - 1], 0.9985 * Double.pi)

        for n in 1..<count where lsps[start + n] < lsps[start + n - 1] {
            for m in 1..<count {
                let value = lsps[start + m]
                var l = m - 1

                while l >= 0, lsps[start + l] > value {
                    lsps[start + l + 1] = lsps[start + l]
                    l -= 1
                }
                lsps[start + l + 1] = value
            }
            break
        }
    }
}
