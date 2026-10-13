internal import Foundation

/// One frame, the subframes each channel splits it into, and the transform back to samples.
extension WMAProDecoder {
    // MARK: - The frame

    /// Decodes the frame at the reservoir's cursor, as FFmpeg's `decode_frame` does.
    ///
    /// The first frame after an open decodes but answers no samples, because it only primes the
    /// overlap. A fault sets ``WMAFrameReservoir/packetLoss``.
    ///
    /// - Returns: whether the packet carries another frame behind this one
    func decodeFrame(into produced: inout [Float]?) -> Bool {
        let data = reservoir.bits.bytes
        var reader = BitReader(data.span, cursor: reservoir.cursor)
        let more = decodeFrame(&reader, into: &produced)
        reservoir.cursor = reader.cursor
        return more
    }

    @_lifetime(reader: copy reader)
    private func decodeFrame(_ reader: inout BitReader, into produced: inout [Float]?) -> Bool {
        let frame = configuration.samplesPerFrame
        let channelCount = configuration.channelCount
        var length = 0

        if configuration.hasLengthPrefix { length = Int(reader.read(configuration.log2FrameSize)) }
        guard decodeTileHeader(&reader) else {
            reservoir.packetLoss = true
            return false
        }

        // a post-processing transform the output never applies, so its coefficients are skipped
        if channelCount > 1, reader.readBit(), reader.readBit() {
            reader.skip(4 * channelCount * channelCount)
        }
        if configuration.hasDynamicRangeCompression { reader.skip(8) }

        if reader.readBit() {
            let width = WMAMath.floorLog2(frame * 2)
            if reader.readBit() { trimStart = Int(reader.read(width)) }
            if reader.readBit() { trimEnd = Int(reader.read(width)) }
        } else {
            trimStart = 0
            trimEnd = 0
        }

        parsedAllSubframes = false

        for channel in channels.indices {
            var state = MutableRef(&channels[channel])
            state.value.decodedSamples = 0
            state.value.currentSubframe = 0
            state.value.reusesScaleFactors = false
        }
        while !parsedAllSubframes {
            guard decodeSubframe(&reader) else {
                reservoir.packetLoss = true
                return false
            }
        }

        let samples = interleave(&outputs)

        if skipsFrame {
            skipsFrame = false
            produced = nil
        } else {
            produced = samples
        }

        if configuration.hasLengthPrefix {
            let read = reader.cursor - reservoir.frameOffset
            guard length == read + 2 else {
                reservoir.packetLoss = true
                return false
            }
            reader.skip(length - read - 1)
        } else {
            while reader.cursor < reservoir.savedBits, !reader.readBit() {
                // the frame pads to its end with zeros, and the one bit behind them is the flag
            }
        }
        return reader.readBit()
    }

    /// Answers the frame the output runs hold, and moves each run's overlap to its front.
    private func interleave(_ runs: inout [Float]) -> [Float] {
        let frame = configuration.samplesPerFrame
        let channelCount = configuration.channelCount
        var samples = [Float](repeating: 0, count: frame * channelCount)

        for channel in 0..<channelCount {
            let base = channel * outputStride

            for index in 0..<frame { samples[index * channelCount + channel] = runs[base + index] }
            // the half frame the next frame overlaps moves to the front to meet it
            for index in 0..<(frame / 2) { runs[base + index] = runs[base + frame + index] }
        }
        return samples
    }

    // MARK: - The tiling

    /// Reads how each channel's frame splits into subframes, as FFmpeg's `decode_tilehdr` does.
    ///
    /// The channel with the fewest samples placed so far takes the next subframe. When several tie,
    /// a bit per channel states which of them it covers, unless the layout is fixed.
    @_lifetime(reader: copy reader)
    private func decodeTileHeader(_ reader: inout BitReader) -> Bool {
        let frame = configuration.samplesPerFrame
        let shortest = configuration.minimumSubframeLength
        let channelCount = configuration.channelCount
        var placed = [Int](repeating: 0, count: channelCount)
        var contains = [Bool](repeating: false, count: channelCount)
        var tied = channelCount
        var fewest = 0
        var fixed = configuration.maximumSubframeCount == 1

        for channel in channels.indices { channels[channel].subframeCount = 0 }
        if !fixed { fixed = reader.readBit() }

        repeat {
            for channel in 0..<channelCount {
                if placed[channel] == fewest {
                    if fixed || tied == 1 || fewest == frame - shortest {
                        contains[channel] = true
                    } else {
                        contains[channel] = reader.readBit()
                    }
                } else {
                    contains[channel] = false
                }
            }
            let length = decodeSubframeLength(&reader, offset: fewest)
            guard length > 0 else { return false }
            fewest += length

            for channel in 0..<channelCount {
                if contains[channel] {
                    var state = MutableRef(&channels[channel])
                    let count = state.value.subframeCount
                    guard count < WMAProConfiguration.maximumSubframes else { return false }
                    state.value.subframeLengths[count] = length
                    state.value.subframeCount = count + 1
                    placed[channel] += length
                    guard placed[channel] <= frame else { return false }
                } else if placed[channel] <= fewest {
                    if placed[channel] < fewest {
                        tied = 0
                        fewest = placed[channel]
                    }
                    tied += 1
                }
            }
        } while fewest < frame
        return true
    }

    /// - Returns: the subframe's length, or zero when the bits state none this stream allows
    @_lifetime(reader: copy reader)
    private func decodeSubframeLength(_ reader: inout BitReader, offset: Int) -> Int {
        let frame = configuration.samplesPerFrame
        let shortest = configuration.minimumSubframeLength

        // only one length fits in front of the frame's end
        if offset == frame - shortest { return shortest }
        guard reservoir.savedBits - reader.cursor >= 1 else { return 0 }

        var shift = 0
        let bits = configuration.subframeLengthBits

        if configuration.hasShortSubframeFlag {
            if reader.readBit() { shift = 1 + Int(reader.read(bits - 1)) }
        } else {
            shift = Int(reader.read(bits))
        }
        let length = shift < Int.bitWidth ? frame >> shift : 0
        return length >= shortest && length <= frame ? length : 0
    }

    // MARK: - One subframe

    /// Decodes the subframe of the channels that have placed the fewest samples.
    @_lifetime(reader: copy reader)
    private func decodeSubframe(_ reader: inout BitReader) -> Bool {
        let frame = configuration.samplesPerFrame
        let channelCount = configuration.channelCount
        var offset = frame
        var length = frame

        for channel in 0..<channelCount {
            var state = MutableRef(&channels[channel])
            state.value.grouped = false

            if offset > state.value.decodedSamples {
                offset = state.value.decodedSamples
                length = state.value.subframeLengths[state.value.currentSubframe]
            }
        }

        var total = frame * channelCount
        channelsForSubframe.removeAll(keepingCapacity: true)

        for channel in 0..<channelCount {
            let state = channels[channel]
            total -= state.decodedSamples

            if offset == state.decodedSamples,
               length == state.subframeLengths[state.currentSubframe]
            {
                total -= length
                channels[channel].decodedSamples += length
                channelsForSubframe.append(channel)
            }
        }
        if total == 0 { parsedAllSubframes = true }

        tableIndex = WMAMath.floorLog2(frame / length)
        bandCount = configuration.bandCounts[tableIndex]

        for channel in channelsForSubframe {
            channels[channel].coefficientStart = offset + frame / 2
        }
        subframeLength = length
        escapeLength = WMAMath.floorLog2(length - 1) + 1

        // an extended header carries fill bits the decode never reads
        if reader.readBit() {
            var fill = Int(reader.read(2))

            if fill == 0 {
                let width = Int(reader.read(4))
                fill = Int(reader.read(width)) + 1
            }
            guard reader.cursor + fill <= reservoir.savedBits else { return false }
            reader.skip(fill)
        }
        guard !reader.readBit() else { return false }
        guard decodeChannelTransform(&reader) else { return false }

        var transmits = false

        for channel in channelsForSubframe {
            let sent = reader.readBit()
            channels[channel].transmitsCoefficients = sent
            if sent { transmits = true }
        }
        if transmits { guard decodeQuantization(&reader) else { return false } }

        for channel in channelsForSubframe {
            if channels[channel].transmitsCoefficients, reader.cursor < reservoir.savedBits {
                // FFmpeg keeps whatever a faulty run left, so a fault here drops nothing
                decodeCoefficients(&reader, channel: channel, into: &outputs)
            } else {
                let start = channel * outputStride + channels[channel].coefficientStart
                outputs.replaceSubrange(
                    start..<(start + length), with: repeatElement(0, count: length))
            }
        }

        if transmits {
            inverseChannelTransform(&outputs)
            for channel in channelsForSubframe { reconstruct(channel, into: &outputs) }
        }
        window(&outputs)

        for channel in channelsForSubframe {
            var state = MutableRef(&channels[channel])
            guard state.value.currentSubframe < state.value.subframeCount else { return false }
            state.value.currentSubframe += 1
        }
        return true
    }

    /// Reads the vector coefficient counts, the quantization step and each channel's scale factors.
    @_lifetime(reader: copy reader)
    private func decodeQuantization(_ reader: inout BitReader) -> Bool {
        let length = subframeLength
        var step = (90 * configuration.bitsPerSample) >> 4

        transmitsVectorCount = reader.readBit()

        if transmitsVectorCount {
            let bits = WMAMath.floorLog2((length + 3) / 4) + 1

            for channel in channelsForSubframe {
                let count = Int(reader.read(bits)) << 2
                guard count <= length else { return false }
                channels[channel].vectorCoefficientCount = count
            }
        } else {
            for channel in channelsForSubframe { channels[channel].vectorCoefficientCount = length }
        }

        var change = Int(reader.read(6))
        if change >= 32 { change -= 64 }
        step += change

        // an extreme change continues in five-bit runs, each run of 31 adding 31
        if change == -32 || change == 31 {
            let sign = change == 31 ? 0 : -1
            var extra = 0

            while reader.cursor + 5 < reservoir.savedBits {
                change = Int(reader.read(5))
                guard change == 31 else { break }
                extra += 31
            }
            step += ((extra + change) ^ sign) - sign
        }

        if channelsForSubframe.count == 1 {
            channels[channelsForSubframe[0]].quantizationStep = step
        } else {
            let modifierBits = Int(reader.read(3))

            for channel in channelsForSubframe {
                channels[channel].quantizationStep = step

                if reader.readBit() {
                    channels[channel].quantizationStep += modifierBits > 0
                        ? Int(reader.read(modifierBits)) + 1
                        : 1
                }
            }
        }
        return decodeScaleFactors(&reader)
    }

    // MARK: - The channel transform

    /// Reads which channels this subframe transforms together and how, as FFmpeg's
    /// `decode_channel_transform` does.
    @_lifetime(reader: copy reader)
    private func decodeChannelTransform(_ reader: inout BitReader) -> Bool {
        groupCount = 0
        let streamChannels = configuration.channelCount
        guard streamChannels > 1 else { return true }

        var remaining = channelsForSubframe.count
        guard !reader.readBit() else { return false }

        while remaining > 0, groupCount < channelsForSubframe.count {
            var group = MutableRef(&groups[groupCount])
            group.value.channelCount = 0
            group.value.transforms = false
            group.value.members.removeAll(keepingCapacity: true)

            if remaining > 2 {
                for channel in channelsForSubframe where !channels[channel].grouped {
                    guard reader.readBit() else { continue }
                    group.value.channelCount += 1
                    channels[channel].grouped = true
                    group.value.members.append(channel)
                }
            } else {
                group.value.channelCount = remaining

                for channel in channelsForSubframe {
                    if !channels[channel].grouped { group.value.members.append(channel) }
                    channels[channel].grouped = true
                }
            }

            if group.value.channelCount == 2 {
                if reader.readBit() {
                    guard !reader.readBit() else { return false }
                } else {
                    group.value.transforms = true
                    // mid and side, which a multichannel stream scales by its cos(pi / 4)
                    let unit: Float = streamChannels == 2 ? 1 : 0.70703125
                    group.value.matrix[0] = unit
                    group.value.matrix[1] = -unit
                    group.value.matrix[2] = unit
                    group.value.matrix[3] = unit
                }
            } else if group.value.channelCount > 2, reader.readBit() {
                group.value.transforms = true

                if reader.readBit() {
                    decodeDecorrelationMatrix(&reader, into: &group.value)
                } else if group.value.channelCount <= 6 {
                    // FFmpeg keeps the last matrix for a larger group, which it has no default for
                    let defaults = WMAProTables.defaultDecorrelationMatrices
                    let start = WMAProTables.defaultDecorrelationOffsets[group.value.channelCount]
                        ?? 0

                    for index in 0..<(group.value.channelCount * group.value.channelCount) {
                        group.value.matrix[index] = defaults[start + index]
                    }
                }
            }

            if group.value.transforms {
                if !reader.readBit() {
                    for band in 0..<bandCount {
                        group.value.transformBands[band] = reader.readBit()
                    }
                } else {
                    for band in 0..<bandCount { group.value.transformBands[band] = true }
                }
            }
            remaining -= group.value.channelCount
            groupCount += 1
        }
        return true
    }

    /// Builds a decorrelation matrix from the rotations the bitstream sends.
    @_lifetime(reader: copy reader)
    private func decodeDecorrelationMatrix(
        _ reader: inout BitReader,
        into group: inout WMAProChannelGroup
    ) {
        let count = group.channelCount
        let streamChannels = configuration.channelCount
        let sine = WMAProComputedTables.sine64

        for index in 0..<(streamChannels * streamChannels) { group.matrix[index] = 0 }

        var rotations: [Int] = []
        for _ in 0..<((count * (count - 1)) >> 1) { rotations.append(Int(reader.read(6))) }
        for index in 0..<count { group.matrix[count * index + index] = reader.readBit() ? 1 : -1 }

        var offset = 0

        for row in 1..<count {
            for column in 0..<row {
                for entry in 0...row {
                    let first = group.matrix[column * count + entry]
                    let second = group.matrix[row * count + entry]
                    let rotation = rotations[offset + column]
                    let sin: Float
                    let cos: Float

                    if rotation < 32 {
                        sin = sine[rotation]
                        cos = sine[32 - rotation]
                    } else {
                        sin = sine[64 - rotation]
                        cos = -sine[rotation - 32]
                    }
                    group.matrix[entry + column * count] = first * sin - second * cos
                    group.matrix[entry + row * count] = first * cos + second * sin
                }
            }
            offset += row
        }
    }

    /// Undoes each group's channel transform on the coefficients, band by band.
    private func inverseChannelTransform(_ runs: inout [Float]) {
        let offsets = configuration.bandOffsets[tableIndex]
        let length = subframeLength
        let streamChannels = configuration.channelCount

        for index in 0..<groupCount where groups[index].transforms {
            let group = groups[index]
            let count = group.channelCount
            guard group.members.count == count else { continue }
            let starts = group.members.map { $0 * outputStride + channels[$0].coefficientStart }
            var column = [Float](repeating: 0, count: count)

            for band in 0..<bandCount {
                let lower = offsets[band]
                let upper = min(offsets[band + 1], length)
                guard lower < upper else { continue }

                if group.transformBands[band] {
                    for sample in lower..<upper {
                        for member in 0..<count { column[member] = runs[starts[member] + sample] }

                        for member in 0..<count {
                            var sum: Float = 0

                            for term in 0..<count {
                                sum += column[term] * group.matrix[member * count + term]
                            }
                            runs[starts[member] + sample] = sum
                        }
                    }
                } else if streamChannels == 2 {
                    for sample in lower..<upper {
                        runs[starts[0] + sample] *= 181.0 / 128
                        runs[starts[1] + sample] *= 181.0 / 128
                    }
                }
            }
        }
    }

    // MARK: - The scale factors

    /// Reads each channel's scale factors, as FFmpeg's `decode_scale_factors` does.
    ///
    /// A channel may keep the factors a longer or shorter subframe sent, resampled to this size,
    /// and then either reuse them or add a run level coded difference.
    @_lifetime(reader: copy reader)
    private func decodeScaleFactors(_ reader: inout BitReader) -> Bool {
        for channel in channelsForSubframe {
            var state = MutableRef(&channels[channel])
            let sent = state.value.scaleFactorIndex
            let slot = sent == 0 ? 1 : 0

            if state.value.reusesScaleFactors {
                let map = configuration.scaleFactorBands[tableIndex][state.value.tableIndex]

                for band in 0..<bandCount {
                    state.value.savedScaleFactors[slot][band] = state.value.savedScaleFactors[sent][
                        map[band]]
                }
            }

            var fresh = state.value.currentSubframe == 0
            if !fresh { fresh = reader.readBit() }

            if fresh {
                if !state.value.reusesScaleFactors {
                    state.value.scaleFactorStep = Int(reader.read(2)) + 1
                    var value = 45 / state.value.scaleFactorStep

                    for band in 0..<bandCount {
                        value += codes.scale.symbol(from: &reader)
                        state.value.savedScaleFactors[slot][band] = value
                    }
                } else {
                    guard readScaleFactorDifferences(&reader, into: &state.value, slot: slot) else {
                        return false
                    }
                }
                state.value.scaleFactorIndex = slot
                state.value.tableIndex = tableIndex
                state.value.reusesScaleFactors = true
            }

            let current = state.value.savedScaleFactors[slot]
            state.value.activeScaleFactors = slot
            state.value.maximumScaleFactor = current[0..<bandCount].max() ?? 0
        }
        return true
    }

    /// Adds the run level coded differences to the resampled factors.
    @_lifetime(reader: copy reader)
    private func readScaleFactorDifferences(
        _ reader: inout BitReader,
        into state: inout WMAProChannelState,
        slot: Int
    ) -> Bool {
        var band = 0

        while band < bandCount {
            let index = codes.scaleRunLevel.symbol(from: &reader)
            let skip: Int
            let value: Int
            let sign: Int

            if index == 0 {
                let code = Int(reader.read(14))
                value = code >> 6
                sign = (code & 1) - 1
                skip = (code & 0x3F) >> 1
            } else if index == 1 {
                break
            } else {
                guard index > 1, index < WMAProTables.scaleRuns.count else { return false }
                skip = WMAProTables.scaleRuns[index]
                value = WMAProTables.scaleLevels[index]
                sign = reader.readBit() ? 0 : -1
            }
            band += skip
            guard band < bandCount else { return false }
            state.savedScaleFactors[slot][band] += (value ^ sign) - sign
            band += 1
        }
        return true
    }

    // MARK: - The coefficients

    /// Reads one channel's coefficients, as FFmpeg's `decode_coeffs` does.
    ///
    /// The run opens with values coded four, two or one at a time, and switches to run level coding
    /// once a long enough run of zeros shows the spectrum has thinned out.
    @_lifetime(reader: copy reader)
    private func decodeCoefficients(
        _ reader: inout BitReader,
        channel: Int,
        into runs: inout [Float]
    ) {
        let table = reader.readBit() ? 1 : 0
        let base = channel * outputStride + channels[channel].coefficientStart
        let vectorCount = channels[channel].vectorCoefficientCount
        let zeroLimit = subframeLength >> 8
        var runLevelMode = false
        var current = 0
        var zeros = 0
        var values = InlineArray<4, Float>(repeating: 0)

        while transmitsVectorCount || !runLevelMode, current + 3 < vectorCount {
            let quad = codes.vector4.symbol(from: &reader)

            if quad < 0 {
                for pair in stride(from: 0, to: 4, by: 2) {
                    let both = codes.vector2.symbol(from: &reader)

                    if both < 0 {
                        values[pair] = readSingleValue(&reader)
                        values[pair + 1] = readSingleValue(&reader)
                    } else {
                        values[pair] = Float(both >> 4)
                        values[pair + 1] = Float(both & 0xF)
                    }
                }
            } else {
                values[0] = Float(quad >> 12)
                values[1] = Float((quad >> 8) & 0xF)
                values[2] = Float((quad >> 4) & 0xF)
                values[3] = Float(quad & 0xF)
            }

            for slot in 0..<4 {
                let value = values[slot]

                if value != 0 {
                    runs[base + current] = reader.readBit() ? value : -value
                    zeros = 0
                } else {
                    runs[base + current] = 0
                    zeros += 1
                    if zeros > zeroLimit { runLevelMode = true }
                }
                current += 1
            }
        }

        guard current < subframeLength else { return }
        for index in (base + current)..<(base + subframeLength) { runs[index] = 0 }
        decodeRunLevel(&reader, table: table, base: base, from: current, into: &runs)
    }

    /// Reads one value of the one-value code, which the code's last symbol extends.
    @_lifetime(reader: copy reader)
    private func readSingleValue(_ reader: inout BitReader) -> Float {
        var value = codes.vector1.symbol(from: &reader)
        if value == WMAProTables.vector1Symbols.count - 1 { value += readLargeValue(&reader) }
        return Float(UInt32(truncatingIfNeeded: value))
    }

    /// FFmpeg's `ff_wma_get_large_val`, a value of eight to 31 bits whose width leads it.
    @_lifetime(reader: copy reader)
    private func readLargeValue(_ reader: inout BitReader) -> Int {
        var width = 8

        if reader.readBit() {
            width += 8

            if reader.readBit() {
                width += 8
                if reader.readBit() { width += 7 }
            }
        }
        return Int(reader.read(width))
    }

    /// FFmpeg's `ff_wma_run_level_decode` in its WMA Pro form.
    @_lifetime(reader: copy reader)
    private func decodeRunLevel(
        _ reader: inout BitReader,
        table: Int,
        base: Int,
        from start: Int,
        into coefficients: inout [Float]
    ) {
        let code = codes.coefficients[table]
        let runs = table == 0 ? WMAProTables.coefficient0Runs : WMAProTables.coefficient1Runs
        let levels = table == 0 ? WMAProTables.coefficient0Levels : WMAProTables.coefficient1Levels
        let length = subframeLength
        let mask = length - 1
        var offset = start

        while offset < length {
            let symbol = code.symbol(from: &reader)

            if symbol > 1 {
                offset += runs[symbol]
                let level = levels[symbol]
                coefficients[base + (offset & mask)] = reader.readBit() ? level : -level
            } else if symbol == 1 {
                break
            } else {
                let level = readLargeValue(&reader)

                if reader.readBit() {
                    if reader.readBit() {
                        guard !reader.readBit() else { return }
                        offset += Int(reader.read(escapeLength)) + 4
                    } else {
                        offset += Int(reader.read(2)) + 1
                    }
                }
                coefficients[base + (offset & mask)] = Float(reader.readBit() ? level : -level)
            }
            offset += 1
        }
    }

    // MARK: - Back to samples

    /// Scales one channel's coefficients band by band and transforms them back in place.
    ///
    /// FFmpeg clears the coefficients above the low frequency channel's cutoff and then overwrites
    /// them with every band, so that cutoff changes nothing and is not applied here.
    private func reconstruct(_ channel: Int, into runs: inout [Float]) {
        let state = channels[channel]
        let offsets = configuration.bandOffsets[tableIndex]
        let length = subframeLength
        let base = channel * outputStride + state.coefficientStart
        let factors = state.savedScaleFactors[state.activeScaleFactors]
        let bands = bandCount

        transformInput.withExclusiveAccess { input in
            for band in 0..<bands {
                let lower = offsets[band]
                let upper = min(offsets[band + 1], length)
                let exponent = state.quantizationStep
                    - (state.maximumScaleFactor - factors[band]) * state.scaleFactorStep
                let step = WMAProComputedTables.decibelStep(exponent)
                guard lower < upper else { continue }
                for index in lower..<upper { input[index] = runs[base + index] * step }
            }
        }

        let size = WMAMath.floorLog2(length) - WMAProConfiguration.shortestBlockBits
        guard let transform = transforms[size] else { return }
        transform.transformHalf(transformInput, scale: transformScales[size], into: &runs, at: base)
    }

    /// Windows each channel's new block against the tail of the one before it and adds the two.
    ///
    /// The overlap spans the shorter of the two blocks, which is FFmpeg's `wmapro_window`.
    private func window(_ runs: inout [Float]) {
        let length = subframeLength

        for channel in channelsForSubframe {
            var state = MutableRef(&channels[channel])
            var span = state.value.previousBlockLength
            var start = channel * outputStride + state.value.coefficientStart - span / 2

            if length < span {
                start += (span - length) >> 1
                span = length
            }
            let shape = windows[
                WMAMath.floorLog2(span) - WMAProConfiguration.shortestBlockBits]
            let half = span >> 1

            for step in 0..<half {
                let mirror = span - 1 - step
                let rising = runs[start + step]
                let falling = runs[start + mirror]
                let low = shape[step]
                let high = shape[mirror]
                runs[start + step] = rising * high - falling * low
                runs[start + mirror] = rising * low + falling * high
            }
            state.value.previousBlockLength = length
        }
    }
}
