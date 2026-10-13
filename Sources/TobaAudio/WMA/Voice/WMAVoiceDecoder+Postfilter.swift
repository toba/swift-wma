internal import Foundation

/// The averaging projection filter a stream that sets its first flag runs over each half frame.
///
/// It turns the speech back into its excitation, smooths that toward the pitch period,
/// resynthesizes it, runs a Wiener denoise filter in the frequency domain, matches the gain to the
/// unfiltered speech, and removes a DC offset.
extension WMAVoiceDecoder {
    /// Where the postfilter's synthesis output starts, behind its history.
    private static let outputStart = maximumLSPs

    /// Filters the 80 samples of `work.synthesis` at `synthesisStart` through the LPCs in
    /// `work.lpcs`, into `work.samples` at `sampleStart`.
    func postfilter(
        work: inout WMAVoiceScratch,
        synthesisAt synthesisStart: Int,
        sampleAt sampleStart: Int,
        zeroStart: Int,
        fixed: WMAVoiceFrameType.Fixed,
        pitch: Int
    ) {
        let size = 80
        let start = Self.outputStart

        CELPFilters.excite(
            &zeroExcitation, at: zeroStart, coefficients: work.lpcs, input: work.synthesis,
            from: synthesisStart, count: size, order: lspCount)

        if fixed >= .adaptiveWindowPulses,
           smooth(pitch: pitch, at: zeroStart, count: size, into: &work.smoothed)
        {
            CELPFilters.synthesize(
                &postfilterOutput, at: start, coefficients: work.lpcs, input: work.smoothed,
                from: 0, count: size, order: lspCount)
        } else {
            CELPFilters.synthesize(
                &postfilterOutput, at: start, coefficients: work.lpcs, input: zeroExcitation,
                from: zeroStart, count: size, order: lspCount)
        }

        let order = lspCount
        postfilterOutput.withExclusiveAccess { output in
            for i in 0..<order { output[start - order + i] = output[start + size - order + i] }
        }

        denoise(fixed: fixed, count: size, work: &work)
        controlGain(
            into: &work.samples, at: sampleStart, speech: work.synthesis, at: synthesisStart,
            count: size)

        if dcLevel > 8 {
            CELPFilters.secondOrder(
                &work.samples, at: sampleStart, zeros: (-1.99997, 1.0),
                poles: (-1.9330735188, 0.93589198496), gain: 0.93980580475,
                memory: &dcFilterMemory, count: size)
        }
    }

    /// Scales the filtered samples toward the energy of the speech before the filter.
    ///
    /// The energy is a sum of magnitudes rather than of squares, and the scale moves smoothly.
    private func controlGain(
        into samples: inout [Float],
        at sampleStart: Int,
        speech: [Float],
        at speechStart: Int,
        count: Int
    ) {
        let alpha: Float = 0.99
        var speechEnergy: Float = 0
        var filteredEnergy: Float = 0

        for i in 0..<count {
            speechEnergy += abs(speech[speechStart + i])
            filteredEnergy += abs(postfilterOutput[Self.outputStart + i])
        }
        let scale = filteredEnergy == 0
            ? 0
            : Float((1.0 - Double(alpha)) * Double(speechEnergy) / Double(filteredEnergy))
        var gain = postfilterGain

        for i in 0..<count {
            gain = alpha * gain + scale
            samples[sampleStart + i] = postfilterOutput[Self.outputStart + i] * gain
        }
        postfilterGain = gain
    }

    /// Blends the excitation toward the stretch of its own past one pitch period back that best
    /// matches it, FFmpeg's `kalman_smoothen`, and answers false when nothing matches.
    private func smooth(
        pitch: Int,
        at start: Int,
        count: Int,
        into smoothed: inout [Float]
    ) -> Bool {
        var best: Int?
        var optimal: Float = 0
        var candidate = start - max(minimumPitch, pitch - 3)
        let end = start - min(maximumPitch, pitch + 3)

        repeat {
            let product = CELPFilters.dot(zeroExcitation, start, zeroExcitation, candidate, count)

            if product > optimal {
                optimal = product
                best = candidate
            }
            candidate -= 1
        } while candidate >= end

        guard optimal > 0, let best else { return false }
        var weight = CELPFilters.dot(zeroExcitation, best, zeroExcitation, best, count)
        guard weight > 0 else { return false }
        weight = optimal <= weight
            ? Float(Double(weight) / (Double(weight) + 0.6 * Double(optimal)))
            : 0.625

        for n in 0..<count {
            smoothed[n] = zeroExcitation[best + n] + weight
                * (zeroExcitation[start + n] - zeroExcitation[best + n])
        }
        return true
    }

    /// The first reflection of an LPC filter's response over its zeroth.
    private static func tilt(_ lpcs: [Float], count: Int) -> Float {
        let zeroth = Float(1.0 + Double(CELPFilters.dot(lpcs, 0, lpcs, 0, count)))
        let first = lpcs[0] + CELPFilters.dot(lpcs, 0, lpcs, 1, count - 1)
        return first / zeroth
    }

    // MARK: - The Wiener filter

    /// Denoises the postfilter output in the frequency domain, carrying the filter's tail into the
    /// next half frame.
    private func denoise(
        fixed: WMAVoiceFrameType.Fixed,
        count size: Int,
        work: inout WMAVoiceScratch
    ) {
        let start = Self.outputStart
        var remainder = 0

        if fixed != .silence {
            let lpcs = work.lpcs
            let order = lspCount
            tiltedLPCs.withExclusiveAccess { tilted in
                tilted[0] = 1
                for i in 0..<order { tilted[1 + i] = lpcs[i] }
                for i in (order + 1)..<128 { tilted[i] = 0 }
            }
            var memory: Float = 0
            CELPFilters.compensateTilt(
                &tiltedLPCs, at: 0, tilt: Float(0.7 * Double(Self.tilt(lpcs, count: lspCount))),
                memory: &memory, count: lspCount + 2)

            remainder = min(127 - size, size - 1)
            computeResponse(fixed: fixed, remainder: remainder, work: &work)

            postfilterOutput.withExclusiveAccess { output in
                for i in size..<128 { output[start + i] = 0 }
            }
            transform.forward(postfilterOutput, from: start, into: &work.speech)
            transform.forward(denoiseCoefficients, into: &work.filter)
            work.speech[0] *= work.filter[0]
            work.speech[1] *= work.filter[1]

            for n in 1...64 {
                let (a, b) = (work.speech[n * 2], work.speech[n * 2 + 1])
                let (c, d) = (work.filter[n * 2], work.filter[n * 2 + 1])
                work.speech[n * 2] = a * c - b * d
                work.speech[n * 2 + 1] = b * c + a * d
            }
            inverseTransform.inverse(&work.speech, into: &work.filtered)
            postfilterOutput.withExclusiveAccess { output in
                for i in 0..<128 { output[start + i] = work.filtered[i] }
            }
        }

        if denoiseCacheCount > 0 {
            let limit = min(denoiseCacheCount, size)
            postfilterOutput.withExclusiveAccess { output in
                for n in 0..<limit { output[start + n] += denoiseCache[n] }
            }
            denoiseCacheCount -= limit
            let kept = denoiseCacheCount

            denoiseCache.withExclusiveAccess { cache in
                for n in 0..<kept where size + n < cache.count { cache[n] = cache[size + n] }
            }
        }

        if fixed != .silence {
            let limit = min(remainder, denoiseCacheCount)
            denoiseCache.withExclusiveAccess { cache in
                for n in 0..<limit { cache[n] += postfilterOutput[start + size + n] }
                if limit < remainder {
                    for n in limit..<remainder { cache[n] = postfilterOutput[start + size + n] }
                }
            }
            if limit < remainder { denoiseCacheCount = remainder }
        }
    }

    /// Derives the denoise filter's coefficients from the spectrum of the tilted LPCs, FFmpeg's
    /// `calc_input_response`.
    private func computeResponse(
        fixed: WMAVoiceFrameType.Fixed,
        remainder: Int,
        work: inout WMAVoiceScratch
    ) {
        transform.forward(tiltedLPCs, into: &work.spectrum)
        var spectrum: [Float] = []
        var coefficients: [Float] = []
        swap(&spectrum, &work.spectrum)
        swap(&coefficients, &work.response)

        defer {
            swap(&spectrum, &work.spectrum)
            swap(&coefficients, &work.response)
        }
        var lowest: Float = 15
        var highest: Float = -15

        func logRange(_ value: Float) -> Float {
            let power = log10f(value)
            highest = max(highest, power)
            lowest = min(lowest, power)
            return power
        }

        let lastLevel = logRange(spectrum[64] * spectrum[64])

        for n in 1..<64 {
            spectrum[n] = logRange(
                spectrum[n * 2] * spectrum[n * 2]
                    + spectrum[n * 2 + 1] * spectrum[n * 2 + 1])
        }
        spectrum[0] = logRange(spectrum[0] * spectrum[0])
        let range = highest - lowest
        spectrum[64] = lastLevel

        let inverseRange = Float(64.0 / Double(range))
        let gainScale = Float(Double(range) * (fixed == .hardcoded ? 5.0 / 13.0 : 5.0 / 14.7))
        let angleScale = Float(Double(gainScale) * (8.0 * M_LN10 / Double.pi))
        let powers = WMAVoiceTables.denoisePower
        let energy = WMAVoiceTables.energy

        for n in 0...64 {
            let level = Double((highest - spectrum[n]) * inverseRange - 1)
            let row = max(0, min(63, level.isFinite ? Int(level.rounded(.toNearestOrEven)) : 0))
            let power = powers[denoiseStrength * 64 + row]
            spectrum[n] = angleScale * power

            let scaled = (Double(power * gainScale) - 0.0295) * 70.570526123
            let step = scaled.isNaN ? 0 : Int(max(0, min(scaled, Double(Int32.max / 2))))

            coefficients[n] = step > 127
                ? energy[127] * powf(1.0331663, Float(step - 127))
                : energy[step]
        }

        dcst.cosineTransform(spectrum, into: &work.cosine, mirrored: &work.mirrored)
        dcst.sineTransform(work.cosine, into: &work.phases, mirrored: &work.mirrored)
        let phases = work.phases
        coefficients[0] *= cosines[Self.angle(phases[64])]
        let lastCoefficient = coefficients[64] * cosines[Self.angle(phases[64] - 2 * phases[63])]
        var n = 63

        while true {
            var index = Self.angle(-phases[64] - 2 * phases[n - 1])
            coefficients[n * 2 + 1] = coefficients[n] * sines[index]
            coefficients[n * 2] = coefficients[n] * cosines[index]

            n -= 1
            if n == 0 { break }

            index = Self.angle(phases[64] - 2 * phases[n - 1])
            coefficients[n * 2 + 1] = coefficients[n] * sines[index]
            coefficients[n * 2] = coefficients[n] * cosines[index]
            n -= 1
        }
        coefficients[64] = lastCoefficient

        inverseTransform.inverse(&coefficients, into: &work.filtered)
        denoiseCoefficients.withExclusiveAccess { denoise in
            for i in 0..<128 { denoise[i] = work.filtered[i] }
            for i in remainder..<128 { denoise[i] = 0 }
        }

        if correctsDenoiseTilt {
            var memory: Float = 0
            denoiseCoefficients[remainder - 1] = 0
            let tilt = Self.tilt(denoiseCoefficients, count: remainder - 1)
            CELPFilters.compensateTilt(
                &denoiseCoefficients, at: 0, tilt: Float(-1.8 * Double(tilt)), memory: &memory,
                count: remainder)
        }

        let energySum = CELPFilters.dot(denoiseCoefficients, 0, denoiseCoefficients, 0, remainder)
        let normal = Float((1.0 / 64.0) * Double(sqrtf(1 / energySum)))
        denoiseCoefficients.withExclusiveAccess { denoise in
            for i in 0..<remainder { denoise[i] *= normal }
        }
    }

    /// The index into the 511-entry windows that a phase names, which C truncates to an integer and
    /// clips to plus or minus 255.
    private static func angle(_ phase: Float) -> Int {
        guard phase.isFinite else { return 255 }
        return 255 + Int(max(-255, min(255, phase.rounded(.towardZero))))
    }
}
