/// The prediction filters that turn residues back into samples, each run in the order FFmpeg runs
/// them: the CDLMS cascade per channel, then the MCLMS across channels, the inter-channel step and
/// the AC filter.
///
/// Every sum wraps at 32 bits and every coefficient store truncates to 16, as the C code does, so
/// the output stays bit-exact.
extension WMALosslessDecoder {
    // MARK: - The tile reset

    /// Zeroes the filter state a seekable tile starts from.
    func clearCodecBuffers() {
        Self.zero(&acCoefficients)
        Self.zero(&acHistory)
        Self.zero(&lpcCoefficients)
        Self.zero(&mclmsCoefficients)
        Self.zero(&mclmsCurrent)
        Self.zero(&mclmsHistory)
        Self.zero(&mclmsUpdates)

        for channel in 0..<configuration.channelCount {
            let first = channel * Self.filtersPerChannel

            for filter in first..<(first + cdlmsCount[channel]) {
                let coefficients = filter * Self.cdlmsCoefficientStride
                let history = filter * Self.cdlmsHistoryStride

                for index in coefficients..<(coefficients + Self.cdlmsCoefficientStride) {
                    cdlmsCoefficients[index] = 0
                }
                for index in history..<(history + Self.cdlmsHistoryStride) {
                    cdlmsHistory[index] = 0
                    cdlmsUpdates[index] = 0
                }
            }
            averageSum[channel] = 0
        }
    }

    /// Rewinds each filter's history and opens a transient zone one frame long.
    func resetCodec() {
        mclmsRecent = mclmsOrder * configuration.channelCount

        for channel in 0..<configuration.channelCount {
            let first = channel * Self.filtersPerChannel

            for filter in first..<(first + cdlmsCount[channel]) {
                cdlmsRecent[filter] = cdlmsOrder[filter]
            }
            transientCounter[channel] = configuration.samplesPerFrame
            transient[channel] = true
            transientPosition[channel] = 0
        }
    }

    // MARK: - The update speed

    func useHighUpdateSpeed(_ channel: Int) {
        setUpdateSpeed(channel, to: 16) { Int16(truncatingIfNeeded: Int32($0) * 2) }
    }

    func useNormalUpdateSpeed(_ channel: Int) { setUpdateSpeed(channel, to: 8) { $0 / 2 } }

    /// Rescales each filter's pending updates when the speed moves.
    ///
    /// A version 3 stream rescales the updates behind the filter's recent position, and an older
    /// one rescales the run from the start, as FFmpeg does.
    private func setUpdateSpeed(_ channel: Int, to speed: Int, _ rescale: (Int16) -> Int16) {
        let first = channel * Self.filtersPerChannel

        for filter in stride(from: first + cdlmsCount[channel] - 1, through: first, by: -1)
            where updateSpeed[channel] != speed
        {
            let start = filter * Self.cdlmsHistoryStride
                + (configuration.isVersion3RTM ? cdlmsRecent[filter] : 0)

            for index in start..<(start + cdlmsOrder[filter]) {
                cdlmsUpdates[index] = rescale(cdlmsUpdates[index])
            }
        }
        updateSpeed[channel] = speed
    }

    // MARK: - CDLMS

    /// Runs one channel's filters from the last to the first, each over the whole subframe.
    ///
    /// The four arrays move out of the decoder for the run, so the sample loop reads spans rather
    /// than class properties.
    func revertCDLMS(_ channel: Int, count: Int) {
        var state = CDLMSState()
        swap(&state.coefficients, &cdlmsCoefficients)
        swap(&state.history, &cdlmsHistory)
        swap(&state.updates, &cdlmsUpdates)
        swap(&state.residues, &channelResidues)

        let first = channel * Self.filtersPerChannel
        let residues = channel * configuration.samplesPerFrame

        for filter in stride(from: first + cdlmsCount[channel] - 1, through: first, by: -1) {
            let order = cdlmsOrder[filter]
            let isShort = configuration.bitsPerSample <= 16
            cdlmsRecent[filter] = state.run(
                order: order,
                // the 16-bit product runs over a multiple of 16 and the 32-bit one over a multiple
                // of 8
                width: isShort ? (order + 15) & ~15 : (order + 7) & ~7,
                scaling: cdlmsScaling[filter],
                coefficients: filter * Self.cdlmsCoefficientStride,
                history: filter * Self.cdlmsHistoryStride,
                recent: cdlmsRecent[filter],
                residues: residues..<(residues + count),
                range: Int32(1) << (configuration.bitsPerSample - 1),
                speed: Int32(truncatingIfNeeded: updateSpeed[channel])
            )
        }
        swap(&state.coefficients, &cdlmsCoefficients)
        swap(&state.history, &cdlmsHistory)
        swap(&state.updates, &cdlmsUpdates)
        swap(&state.residues, &channelResidues)
    }

    // MARK: - MCLMS

    /// Predicts each channel from the history of every channel and from the channels in front of it
    /// at the same sample.
    ///
    /// The arrays move out of the decoder for the run, as the CDLMS ones do.
    func revertMCLMS(_ count: Int) {
        var state = MCLMSState(
            channels: configuration.channelCount,
            order: mclmsOrder,
            scaling: mclmsScaling,
            frameLength: configuration.samplesPerFrame,
            range: Int32(1) << (configuration.bitsPerSample - 1),
            coded: isChannelCoded,
            recent: mclmsRecent
        )
        swap(&state.coefficients, &mclmsCoefficients)
        swap(&state.current, &mclmsCurrent)
        swap(&state.history, &mclmsHistory)
        swap(&state.updates, &mclmsUpdates)
        swap(&state.residues, &channelResidues)

        state.run(count)

        swap(&state.coefficients, &mclmsCoefficients)
        swap(&state.current, &mclmsCurrent)
        swap(&state.history, &mclmsHistory)
        swap(&state.updates, &mclmsUpdates)
        swap(&state.residues, &channelResidues)
        mclmsRecent = state.recent
    }

    // MARK: - The channel steps

    /// Undoes the stereo decorrelation, which codes the left channel as a difference.
    func revertInterChannel(_ count: Int) {
        guard configuration.channelCount == 2, isChannelCoded[0] || isChannelCoded[1]
        else { return }
        let right = configuration.samplesPerFrame

        channelResidues.withExclusiveAccess { residues in
            for index in 0..<count {
                residues[index] &-= residues[right + index] &>> 1
                residues[right + index] &+= residues[index]
            }
        }
    }

    /// Runs the short fixed predictor each channel shares, carrying its history across subframes.
    func revertACFilter(_ count: Int) {
        let order = acOrder
        let scaling = Int32(acScaling)
        let frameLength = configuration.samplesPerFrame
        let coefficients = acCoefficients

        for channel in 0..<configuration.channelCount {
            let base = channel * frameLength
            let history = channel * 16

            channelResidues.withExclusiveAccess { residues in
                for index in 0..<max(order, count) {
                    var sum: Int32 = 0

                    for step in 0..<order {
                        let coefficient = Int32(coefficients[step])
                        sum &+= index <= step
                            ? coefficient &* acHistory[history + step - index]
                            : residues[base + index - step - 1] &* coefficient
                    }
                    residues[base + index] &+= sum &>> scaling
                }
            }

            for step in stride(from: order - 1, through: 0, by: -1) {
                acHistory[history + step] = count <= step
                    ? acHistory[history + step - count]
                    : channelResidues[base + count - step - 1]
            }
        }
    }

    // MARK: - Helpers

    static func sign(_ value: Int32) -> Int32 { value > 0 ? 1 : value < 0 ? -1 : 0 }

    private static func zero<Element: FixedWidthInteger>(_ values: inout [Element]) {
        for index in values.indices { values[index] = 0 }
    }
}

/// The CDLMS arrays, held apart from the decoder while one channel's cascade runs.
private struct CDLMSState {
    var coefficients: [Int16] = []
    var history: [Int32] = []
    var updates: [Int16] = []
    var residues: [Int32] = []

    /// Runs one filter over the residues in place, and answers the filter's new recent position.
    ///
    /// The dot product reads `width` entries, which reaches past `order`, as FFmpeg's does.
    mutating func run(
        order: Int,
        width: Int,
        scaling: Int,
        coefficients coefficientBase: Int,
        history base: Int,
        recent: Int,
        residues: Range<Int>,
        range: Int32,
        speed: Int32
    ) -> Int {
        Self.run(
            &coefficients, &history, &updates, &self.residues,
            order: order, width: width, scaling: scaling, coefficients: coefficientBase,
            history: base, recent: recent, residues: residues, range: range, speed: speed)
    }

    /// Takes each array as its own argument, so the four spans never overlap an access to `self`.
    private static func run(
        _ coefficientValues: inout [Int16],
        _ historyValues: inout [Int32],
        _ updateValues: inout [Int16],
        _ residueValues: inout [Int32],
        order: Int,
        width: Int,
        scaling: Int,
        coefficients coefficientBase: Int,
        history base: Int,
        recent: Int,
        residues: Range<Int>,
        range: Int32,
        speed: Int32
    ) -> Int {
        var coefficients = coefficientValues.mutableSpan
        var history = historyValues.mutableSpan
        var updates = updateValues.mutableSpan
        var samples = residueValues.mutableSpan
        var position = recent
        let end = base + WMALosslessDecoder.cdlmsHistoryStride

        for sample in residues {
            let residue = samples[sample]
            let multiplier = WMALosslessDecoder.sign(residue)
            var sum: Int32 = 0

            for index in 0..<width {
                let coefficient = Int32(coefficients[coefficientBase + index])
                sum &+= coefficient &* history[base + position + index]
                coefficients[coefficientBase + index] = Int16(
                    truncatingIfNeeded: coefficient
                        &+ multiplier &* Int32(updates[base + position + index]))
            }
            var prediction = UInt32(truncatingIfNeeded: (1 << scaling) >> 1)
            prediction &+= UInt32(bitPattern: sum)
            let input = residue &+ (Int32(bitPattern: prediction) &>> Int32(scaling))

            // the history runs backward, and at the front the first `order` entries copy up behind
            // themselves
            if position != 0 {
                position -= 1
            } else {
                for index in 0..<order {
                    history[base + order + index] = history[base + index]
                    updates[base + order + index] = updates[base + index]
                }
                position = order - 1
            }
            history[base + position] = min(max(input, -range), range - 1)
            updates[base + position] = Int16(
                truncatingIfNeeded: WMALosslessDecoder.sign(input)
                    &* speed)
            updates[base + position + (order >> 4)] >>= 2
            updates[base + position + (order >> 3)] >>= 1

            for index in (base + position + order)..<end { updates[index] = 0 }
            samples[sample] = input
        }
        return position
    }
}

/// The MCLMS arrays, held apart from the decoder while the filter runs over one subframe.
private struct MCLMSState {
    let channels: Int
    let order: Int
    let scaling: Int
    let frameLength: Int
    let range: Int32
    let coded: [Bool]
    var recent: Int
    var coefficients: [Int16] = []
    var current: [Int16] = []
    var history: [Int32] = []
    var updates: [Int32] = []
    var residues: [Int32] = []

    mutating func run(_ count: Int) {
        var prediction = ChannelValues<Int32>(repeating: 0)

        for index in 0..<count {
            predict(index, &prediction)
            update(index, prediction)
        }
    }

    private mutating func predict(_ index: Int, _ prediction: inout ChannelValues<Int32>) {
        let width = order * channels

        for channel in 0..<channels {
            prediction[channel] = 0
            guard coded[channel] else { continue }
            var sum: Int32 = 0

            for step in 0..<width {
                sum &+= history[step + recent]
                    &* Int32(coefficients[step + width * channel])
            }
            for other in 0..<channel {
                sum &+= residues[other * frameLength + index]
                    &* Int32(current[other + channels * channel])
            }
            sum &+= Int32(bitPattern: (UInt32(1) &<< scaling) &>> 1)
            sum &>>= Int32(scaling)
            prediction[channel] = sum
            residues[channel * frameLength + index] &+= sum
        }
    }

    private mutating func update(_ index: Int, _ prediction: ChannelValues<Int32>) {
        let width = order * channels

        for channel in 0..<channels {
            let error = residues[channel * frameLength + index] &- prediction[channel]
            guard error != 0 else { continue }
            let direction: Int32 = error > 0 ? 1 : -1

            for step in 0..<width {
                let target = step + channel * width
                coefficients[target] = Int16(
                    truncatingIfNeeded: Int32(coefficients[target])
                        &+ direction &* updates[recent + step])
            }
            for other in 0..<channel {
                let target = channel * channels + other
                let moved = direction
                    &* WMALosslessDecoder.sign(residues[other * frameLength + index])
                current[target] = Int16(truncatingIfNeeded: Int32(current[target]) &+ moved)
            }
        }

        for channel in stride(from: channels - 1, through: 0, by: -1) {
            let residue = residues[channel * frameLength + index]
            recent -= 1
            history[recent] = min(max(residue, -range), range - 1)
            updates[recent] = WMALosslessDecoder.sign(residue)
        }

        if recent == 0 {
            for step in 0..<width {
                history[width + step] = history[step]
                updates[width + step] = updates[step]
            }
            recent = width
        }
    }
}
