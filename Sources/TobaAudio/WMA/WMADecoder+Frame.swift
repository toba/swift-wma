internal import Accelerate
internal import Foundation

/// One frame, and the blocks it splits into.
///
/// A frame holds `frameLength` samples. It splits into one block of that length, or into several
/// shorter ones that together cover it. Each block transforms to twice its own length and overlaps
/// its neighbours by half, so a sample leaves the decoder only once the block behind it has added
/// its own half.
///
/// Every run over a channel's samples binds the flat storage to a buffer once and walks a pointer
/// through it. Subscripting the array per element would run a uniqueness check on each write, which
/// is the whole cost of a loop this shape.
extension WMADecoder {
    // MARK: - The frame

    @_lifetime(reader: copy reader)
    func decodeFrame(
        _ reader: inout BitReader,
        into samples: inout [Float],
        at offset: Int
    ) throws(AudioReadError) {
        blockPosition = 0

        while true {
            if try decodeBlock(&reader) { break }
            guard !reader.isOverrun else { throw .malformed("WMA frame ran short") }
        }
        emit(into: &samples, at: offset)
    }

    /// Interleaves the finished frame into `samples`, then moves each channel's overlap to the
    /// front to meet the frame to come.
    ///
    /// A stereo pair is the two parts of a complex number, so the split to interleaved conversion
    /// is the interleave. That reaches the processor's own interleaving store, which a loop writing
    /// one sample per channel stride never does.
    private func emit(into samples: inout [Float], at offset: Int) {
        let channels = configuration.channelCount
        let frameLength = configuration.frameLength
        let span = frameLength * 2

        frameOut.withUnsafeMutableBufferPointer { out in
            samples.withUnsafeMutableBufferPointer { target in
                let source = out.baseAddress!
                let write = unsafe target.baseAddress! + offset

                if channels == 2 {
                    var split = unsafe DSPSplitComplex(realp: source, imagp: source + span)

                    unsafe write.withMemoryRebound(to: DSPComplex.self, capacity: frameLength) {
                        pairs in
                        unsafe vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(frameLength))
                    }
                } else {
                    unsafe write.update(from: source, count: frameLength)
                }

                // the half that overlaps the frame to come moves to the front to meet it
                for channel in 0..<channels {
                    let base = unsafe source + channel * span

                    unsafe base.update(from: base + frameLength, count: frameLength)
                }
            }
        }
    }

    // MARK: - One block

    /// - Returns: whether this block completes the frame
    @_lifetime(reader: copy reader)
    private func decodeBlock(_ reader: inout BitReader) throws(AudioReadError) -> Bool {
        let frameLengthBits = configuration.frameLengthBits
        let sizes = configuration.blockSizeCount

        if configuration.options.usesVariableBlockLength {
            let width = WMAMath.floorLog2(sizes - 1) + 1

            if resetBlockLengths {
                // the first block of a run states both of the lengths behind it
                resetBlockLengths = false
                previousBlockLengthBits = try blockBits(reader.read(width), sizes)
                blockLengthBits = try blockBits(reader.read(width), sizes)
            } else {
                previousBlockLengthBits = blockLengthBits
                blockLengthBits = nextBlockLengthBits
            }
            nextBlockLengthBits = try blockBits(reader.read(width), sizes)
        } else {
            previousBlockLengthBits = frameLengthBits
            blockLengthBits = frameLengthBits
            nextBlockLengthBits = frameLengthBits
        }
        let size = frameLengthBits - blockLengthBits
        guard size >= 0, size < sizes else { throw .malformed("WMA block length") }

        let blockLength = 1 << blockLengthBits
        guard blockPosition + blockLength <= configuration.frameLength else {
            throw .malformed("WMA frame overflow")
        }
        let channels = configuration.channelCount
        isMidSide = false
        if channels == 2 { isMidSide = reader.readBit() }
        var anyCoded = false

        for channel in 0..<channels {
            let coded = reader.readBit()
            channelCoded[channel] = coded
            anyCoded = anyCoded || coded
        }

        if anyCoded { try decodeCoded(&reader, size: size, blockLength: blockLength) }
        transform(size: size, blockLength: blockLength)

        blockPosition += blockLength
        return blockPosition >= configuration.frameLength
    }

    /// The block length a field names, as a power of two.
    @inline(__always)
    private func blockBits(_ value: UInt32, _ sizes: Int) throws(AudioReadError) -> Int {
        let step = Int(value)
        guard step < sizes else { throw .malformed("WMA block length") }
        return configuration.frameLengthBits - step
    }

    // MARK: - The coded channels

    @_lifetime(reader: copy reader)
    private func decodeCoded(
        _ reader: inout BitReader,
        size: Int,
        blockLength: Int
    ) throws(AudioReadError) {
        let channels = configuration.channelCount
        let stride = configuration.frameLength
        var totalGain = 1

        // the gain is a run of seven-bit steps, and a step short of its own maximum ends the run
        while true {
            guard reader.remaining >= 7 else { throw .malformed("WMA total gain") }
            let step = Int(reader.read(7))
            totalGain += step
            if step != 127 { break }
        }
        let escapeBits = WMAConfiguration.escapeBits(totalGain: totalGain)
        let count = min(configuration.coefficientEnds[size], blockLength)
            - configuration.version.coefficientStart

        for channel in 0..<channels { coefficientCounts[channel] = count }
        if configuration.usesNoiseCoding { decodeHighBands(&reader, size: size) }

        // a short block reuses the exponents of the block in front of it unless it says otherwise
        if blockLengthBits == configuration.frameLengthBits || reader.readBit() {
            for channel in 0..<channels where channelCoded[channel] {
                try decodeExponents(&reader, channel: channel, size: size, blockLength: blockLength)
                exponentBlockSize[channel] = size
                exponentsReady[channel] = true
            }
        }

        for channel in 0..<channels where channelCoded[channel] {
            guard exponentsReady[channel] else { throw .malformed("WMA exponents") }
        }

        coded.withUnsafeMutableBufferPointer { slot in
            for channel in 0..<channels where channelCoded[channel] {
                unsafe vDSP_vclr(slot.baseAddress! + channel * stride, 1, vDSP_Length(blockLength))
            }
        }

        for channel in 0..<channels where channelCoded[channel] {
            try decodeRunLevel(
                &reader,
                channel: channel,
                // a mid-side channel carries less energy, so it reads a table of its own
                table: channel == 1 && isMidSide ? 1 : 0,
                count: coefficientCounts[channel],
                blockLength: blockLength,
                escapeBits: escapeBits
            )
        }
        applyExponents(totalGain: totalGain, size: size, blockLength: blockLength, count: count)

        if isMidSide, channelCoded[1] { resolveMidSide(blockLength: blockLength) }
    }

    // MARK: - The high bands

    /// Reads which high bands each coded channel fills with noise, then the gain of each.
    ///
    /// A channel's first noise band states its gain in seven bits, and each one behind it codes the
    /// step from the band before.
    @_lifetime(reader: copy reader)
    private func decodeHighBands(_ reader: inout BitReader, size: Int) {
        let widths = configuration.highBands[size]
        let channels = configuration.channelCount

        for channel in 0..<channels where channelCoded[channel] {
            let base = channel * highBandLimit

            for (band, width) in widths.enumerated() {
                let isNoise = reader.readBit()
                highBandNoise[base + band] = isNoise
                if isNoise { coefficientCounts[channel] -= width }
            }
        }

        for channel in 0..<channels where channelCoded[channel] {
            let base = channel * highBandLimit
            var gain: Int?

            for band in widths.indices where highBandNoise[base + band] {
                let next =
                    if let gain {
                        gain + highGainTable.symbol(from: &reader)
                    } else {
                        Int(reader.read(7)) - 19
                    }
                highBandGains[base + band] = next
                gain = next
            }
        }
    }

    // MARK: - The exponents

    @_lifetime(reader: copy reader)
    private func decodeExponents(
        _ reader: inout BitReader,
        channel: Int,
        size: Int,
        blockLength: Int
    ) throws(AudioReadError) {
        let bands = configuration.exponentBands[size]
        let base = channel * configuration.frameLength
        let stated = configuration.version.statesFirstExponent
        var exponent = stated ? Int(reader.read(5)) + 10 : 36
        var position = 0
        var maximum: Float = 0
        var value: Float = 0
        var failure: AudioReadError?

        exponents.withUnsafeMutableBufferPointer { slot in
            for (band, width) in bands.enumerated() {
                guard position < blockLength else { break }

                if !stated || band > 0 {
                    let symbol = exponentTable.symbol(from: &reader)
                    guard symbol >= 0 else {
                        failure = .malformed("WMA exponent code")
                        return
                    }
                    exponent += symbol - WMATables.powerBias
                }
                let index = exponent + WMATables.powerBias
                guard index >= 0, index < WMATables.powerCount else {
                    failure = .malformed("WMA exponent range")
                    return
                }
                value = powers[index]
                if value > maximum { maximum = value }

                // one band is one run of the same exponent
                let span = min(width, blockLength - position)
                for step in 0..<span { unsafe slot[base + position + step] = value }
                position += span
            }
            // a band list that stops short leaves the rest of the block at the last exponent
            while position < blockLength {
                unsafe slot[base + position] = value
                position += 1
            }
        }
        if let failure { throw failure }
        guard maximum > 0 else { throw .malformed("WMA exponents") }
        maximumExponent[channel] = maximum
    }

    // MARK: - The coefficients

    /// Reads one channel's coefficients, which are a run of zeros and a level at a time.
    @_lifetime(reader: copy reader)
    private func decodeRunLevel(
        _ reader: inout BitReader,
        channel: Int,
        table: Int,
        count: Int,
        blockLength: Int,
        escapeBits: Int
    ) throws(AudioReadError) {
        let codes = coefficientTables[table]
        let runs = coefficientRuns[table]
        let levels = coefficientLevels[table]
        let base = channel * configuration.frameLength
        let mask = blockLength - 1
        let width = configuration.frameLengthBits
        var offset = 0
        var failure: AudioReadError?

        coded.withUnsafeMutableBufferPointer { slot in
            while offset < count {
                let code = codes.symbol(from: &reader)
                guard code >= 0 else {
                    failure = .malformed("WMA coefficient code")
                    return
                }
                var level: Float

                if code > 1 {
                    guard code < runs.count else {
                        failure = .malformed("WMA coefficient code")
                        return
                    }
                    offset += runs[code]
                    level = Float(levels[code])
                } else if code == 1 {
                    break
                } else {
                    level = Float(reader.read(escapeBits))
                    offset += Int(reader.read(width))
                }
                // the sign bit sits behind the level, and a set bit means positive
                if !reader.readBit() { level = -level }
                unsafe slot[base + (offset & mask)] = level
                offset += 1
            }
        }
        if let failure { throw failure }
        guard offset <= count else { throw .malformed("WMA coefficient overflow") }
    }

    /// Scales each coded coefficient by the exponent of the band it sits in.
    ///
    /// A block whose exponents were read at its own size maps one coefficient to one exponent, so
    /// that case runs as two vector passes. Any other size has to rescale the index per
    /// coefficient.
    ///
    /// A coefficient lands `WMAVersion.coefficientStart` places up but takes the exponent at its
    /// coded index, which is what FFmpeg does for version 1.
    private func applyExponents(totalGain: Int, size: Int, blockLength: Int, count: Int) {
        let gain = Float(pow(10, Double(totalGain) * 0.05))
        // the transform sums over a quarter of the window, so the scale takes that length back out
        let normalize = 2 / Float(blockLength) * WMADecoder.outputScale
            * configuration.version.transformScale(blockLength: blockLength)
        let start = configuration.version.coefficientStart
        let stride = configuration.frameLength
        let channels = configuration.channelCount

        if configuration.usesNoiseCoding {
            for channel in 0..<channels where channelCoded[channel] {
                applyNoise(
                    channel: channel,
                    multiplier: gain / maximumExponent[channel] * normalize,
                    normalize: normalize,
                    size: size,
                    blockLength: blockLength
                )
            }
            return
        }

        scaled.withUnsafeMutableBufferPointer { out in
            coded.withUnsafeBufferPointer { source in
                exponents.withUnsafeBufferPointer { scale in
                    guard let output = out.baseAddress,
                          let input = source.baseAddress,
                          let weights = scale.baseAddress else { return }

                    for channel in 0..<channels where channelCoded[channel] {
                        let base = channel * stride
                        // the exponents may have been read at a different block size
                        let shift = exponentBlockSize[channel]
                        var multiplier = gain / maximumExponent[channel] * normalize
                        let floor = unsafe output + base
                        let target = unsafe floor + start

                        if start > 0 { unsafe vDSP_vclr(floor, 1, vDSP_Length(start)) }

                        if shift == size {
                            unsafe vDSP_vmul(
                                input + base, 1, weights + base, 1, target, 1,
                                vDSP_Length(count))
                            unsafe vDSP_vsmul(target, 1, &multiplier, target, 1, vDSP_Length(count))
                        } else {
                            for index in 0..<count {
                                let band = (index << size) >> shift
                                unsafe target[index] = source[base + index]
                                    * scale[base + band] * multiplier
                            }
                        }
                        // the top of the spectrum is never coded
                        let end = start + count

                        if end < blockLength {
                            unsafe vDSP_vclr(floor + end, 1, vDSP_Length(blockLength - end))
                        }
                    }
                }
            }
        }
    }

    /// Scales one channel of a sparse block, where every coefficient takes the next noise value.
    ///
    /// Below the first coded coefficient and above the last, the block is noise alone. A coded band
    /// adds the noise to its coefficients. A noise band scales the noise by its exponent power
    /// against the last noise band's, times its own gain.
    ///
    /// - Parameters:
    ///   - multiplier: the coded coefficient scale, which the total gain sets
    ///   - normalize: the transform's own scale, which a noise band takes without the total gain
    private func applyNoise(
        channel: Int,
        multiplier: Float,
        normalize: Float,
        size: Int,
        blockLength: Int
    ) {
        let start = configuration.version.coefficientStart
        let highStart = configuration.highBandStarts[size]
        let widths = configuration.highBands[size]
        let base = channel * configuration.frameLength
        let bands = channel * highBandLimit
        let shift = exponentBlockSize[channel]
        let noiseScale = maximumExponent[channel] * configuration.noiseMultiplier
        let mask = WMATables.noiseCount - 1
        var next = noiseIndex
        var last = 0

        scaled.withUnsafeMutableBufferPointer { out in
            coded.withUnsafeBufferPointer { source in
                exponents.withUnsafeBufferPointer { scale in
                    noise.withUnsafeBufferPointer { table in
                        highBandPower.withUnsafeMutableBufferPointer { power in
                            let target = unsafe out.baseAddress! + base
                            let weights = unsafe scale.baseAddress! + base
                            var packed = unsafe source.baseAddress! + base

                            for index in 0..<start {
                                unsafe target[index] = table[next]
                                    * weights[(index << size) >> shift] * multiplier
                                next = (next + 1) & mask
                            }

                            // a noise band's power is the mean square of its exponents
                            var exponent = (highStart << size) >> shift

                            for (band, width) in widths.enumerated() {
                                if highBandNoise[bands + band] {
                                    var sum: Float = 0

                                    for index in 0..<width {
                                        let value = unsafe weights[
                                            exponent + ((index << size) >> shift)]
                                        sum += value * value
                                    }
                                    unsafe power[band] = sum / Float(width)
                                    last = band
                                }
                                exponent += (width << size) >> shift
                            }
                            exponent = (start << size) >> shift
                            var position = start

                            for band in -1..<widths.count {
                                let width = band < 0 ? highStart - start : widths[band]
                                let run = unsafe weights + exponent

                                if band >= 0, highBandNoise[bands + band] {
                                    let ratio = unsafe (power[band] / power[last]).squareRoot()
                                    let gain = Float(pow(
                                        10, Double(highBandGains[bands + band]) * 0.05))
                                    let scaleBy = ratio * gain / noiseScale * normalize

                                    for index in 0..<width {
                                        let value = unsafe table[next]
                                            * run[(index << size) >> shift]
                                        unsafe target[position + index] = value * scaleBy
                                        next = (next + 1) & mask
                                    }
                                } else {
                                    for index in 0..<width {
                                        unsafe target[position + index] =
                                            (packed[index] + table[next])
                                            * run[(index << size) >> shift] * multiplier
                                        next = (next + 1) & mask
                                    }
                                    unsafe packed += width
                                }
                                position += width
                                exponent += (width << size) >> shift
                            }

                            // the very high band takes the exponent of the last coded place
                            let tail = unsafe weights[exponent + ((-(1 << size)) >> shift)]
                                * multiplier

                            for index in position..<blockLength {
                                unsafe target[index] = table[next] * tail
                                next = (next + 1) & mask
                            }
                        }
                    }
                }
            }
        }
        noiseIndex = next
    }

    /// Turns the mid and the side channel back into the left and the right.
    private func resolveMidSide(blockLength: Int) {
        let stride = configuration.frameLength
        let rebuildLeft = !channelCoded[0]

        scaled.withUnsafeMutableBufferPointer { out in
            if rebuildLeft { unsafe vDSP_vclr(out.baseAddress!, 1, vDSP_Length(blockLength)) }

            for index in 0..<blockLength {
                let mid = unsafe out[index]
                let side = unsafe out[stride + index]
                unsafe out[index] = mid + side
                unsafe out[stride + index] = mid - side
            }
        }
        if rebuildLeft { channelCoded[0] = true }
    }

    // MARK: - The transform

    private func transform(size: Int, blockLength: Int) {
        let index = configuration.frameLength / 2 + blockPosition - blockLength / 2
        let stride = configuration.frameLength

        for channel in 0..<configuration.channelCount {
            if channelCoded[channel] {
                transforms[size].transform(scaled, from: channel * stride, into: &output)
            } else if !(isMidSide && channel == 1) {
                output.withUnsafeMutableBufferPointer { block in
                    unsafe vDSP_vclr(block.baseAddress!, 1, vDSP_Length(blockLength * 2))
                }
            }
            applyWindow(channel: channel, at: index, blockLength: blockLength)
        }
    }

    /// Folds one block into the frame, rising edge onto what came before and falling edge over what
    /// has not arrived.
    ///
    /// Each edge takes the window of the shorter of the two blocks meeting there, centred in the
    /// longer one. That is what makes two blocks of different lengths still sum back to one.
    private func applyWindow(channel: Int, at index: Int, blockLength: Int) {
        let frameLengthBits = configuration.frameLengthBits
        let base = channel * configuration.frameLength * 2 + index

        frameOut.withUnsafeMutableBufferPointer { out in
            output.withUnsafeBufferPointer { block in
                let target = unsafe out.baseAddress! + base
                let source = block.baseAddress!

                if blockLengthBits <= previousBlockLengthBits {
                    let window = windows[frameLengthBits - blockLengthBits]

                    unsafe vDSP_vma(
                        source, 1, window, 1, target, 1, target, 1, vDSP_Length(blockLength))
                } else {
                    let shorter = 1 << previousBlockLengthBits
                    let edge = (blockLength - shorter) / 2
                    let window = windows[frameLengthBits - previousBlockLengthBits]

                    unsafe vDSP_vma(
                        source + edge, 1, window, 1, target + edge, 1, target + edge, 1,
                        vDSP_Length(shorter))
                    unsafe (target + edge + shorter).update(
                        from: source + edge + shorter, count: edge)
                }
                let tail = unsafe target + blockLength
                let half = unsafe source + blockLength

                if blockLengthBits <= nextBlockLengthBits {
                    let window = fallingWindows[frameLengthBits - blockLengthBits]

                    unsafe vDSP_vmul(half, 1, window, 1, tail, 1, vDSP_Length(blockLength))
                } else {
                    let shorter = 1 << nextBlockLengthBits
                    let edge = (blockLength - shorter) / 2
                    let window = fallingWindows[frameLengthBits - nextBlockLengthBits]

                    unsafe tail.update(from: half, count: edge)
                    unsafe vDSP_vmul(
                        half + edge, 1, window, 1, tail + edge, 1, vDSP_Length(shorter))
                    unsafe vDSP_vclr(tail + edge + shorter, 1, vDSP_Length(edge))
                }
            }
        }
    }
}
