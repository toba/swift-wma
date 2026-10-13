/// One frame, its tile header, and the subframes it splits into.
///
/// Every read here runs over the reservoir. FFmpeg keeps that reader across packets, so the cursor
/// lives on the decoder and a frame decode rebuilds the reader over the reservoir bytes.
extension WMALosslessDecoder {
    // MARK: - The frame

    /// Decodes one frame, answering 1 when the trailer bit states more frames, 0 when it does not,
    /// and -1 on a fault.
    func decodeFrame() -> Int {
        // the reader runs into the bytes an earlier save left and stops 8 bits past this one, as
        // FFmpeg's does
        let data = reservoir.bits.bytes
        var reader = BitReader(data.span, cursor: reservoir.cursor, limit: reservoir.readerSize + 8)
        let result = decodeFrame(&reader)
        reservoir.cursor = reader.cursor
        return result
    }

    @_lifetime(reader: copy reader)
    private func decodeFrame(_ reader: inout BitReader) -> Int {
        let frameLength = configuration.samplesPerFrame
        frameSampleCount = frameLength
        frameSamples.withExclusiveAccess { samples in
            for index in samples.indices { samples[index] = 0 }
        }
        for channel in writePositions.indices { writePositions[channel] = 0 }

        var length = 0
        if configuration.hasLengthPrefix { length = Int(reader.read(configuration.log2FrameSize)) }

        guard decodeTileHeader(&reader) else {
            reservoir.packetLoss = true
            frameSampleCount = 0
            return -1
        }
        if configuration.hasDynamicRangeGain { reader.skip(8) }

        if reader.readBit() {
            let width = WMAMath.floorLog2(frameLength * 2)
            // the start skip, which FFmpeg reads and ignores
            if reader.readBit() { reader.skip(width) }

            if reader.readBit() {
                frameSampleCount -= Int(reader.read(width))
                if frameSampleCount <= 0 { return -1 }
            }
        }

        parsedAllSubframes = false

        for channel in subframes.indices {
            subframes[channel].decodedSamples = 0
            subframes[channel].current = 0
        }

        while !parsedAllSubframes {
            let decoded = subframes[0].decodedSamples

            if decodeSubframe(&reader) < 0 {
                reservoir.packetLoss = true
                if frameSampleCount != 0 { frameSampleCount = decoded }
                return 0
            }
        }

        if configuration.hasLengthPrefix {
            let used = reader.cursor - reservoir.frameOffset
            guard length == used + 2 else {
                reservoir.packetLoss = true
                return 0
            }
            reader.skip(length - used - 1)
        }
        return reader.readBit() ? 1 : 0
    }

    // MARK: - The tile header

    /// Reads how each channel's share of the frame splits into subframes.
    ///
    /// When the split differs per channel, the channels with the fewest samples so far each read a
    /// bit that states whether the next subframe length applies to them.
    @_lifetime(reader: copy reader)
    private func decodeTileHeader(_ reader: inout BitReader) -> Bool {
        let channels = configuration.channelCount
        let frameLength = configuration.samplesPerFrame
        let shortest = configuration.minimumSubframeLength
        var counted = ChannelValues<Int>(repeating: 0)
        var contains = ChannelValues<Bool>(repeating: false)
        var channelsForSubframe = channels
        var minimumLength = 0

        for channel in 0..<channels { subframes[channel].count = 0 }
        let aligned = reader.readBit()
        let fixedLayout = configuration.maximumSubframes == 1 || aligned

        repeat {
            var inUse = false

            for channel in 0..<channels {
                if counted[channel] == minimumLength {
                    let implied = fixedLayout || channelsForSubframe == 1
                        || minimumLength == frameLength - shortest
                    contains[channel] = implied ? true : reader.readBit()
                    inUse = inUse || contains[channel]
                } else {
                    contains[channel] = false
                }
            }
            guard inUse else { return false }
            guard let length = decodeSubframeLength(&reader, offset: minimumLength), length > 0
            else { return false }
            minimumLength += length

            for channel in 0..<channels {
                if contains[channel] {
                    var tiling = MutableRef(&subframes[channel])
                    let index = tiling.value.count
                    guard index < WMALosslessConfiguration.maximumSubframeCount else {
                        return false
                    }
                    tiling.value.lengths[index] = length
                    tiling.value.count += 1
                    counted[channel] += length
                    guard counted[channel] <= frameLength else { return false }
                } else if counted[channel] <= minimumLength {
                    if counted[channel] < minimumLength {
                        channelsForSubframe = 0
                        minimumLength = counted[channel]
                    }
                    channelsForSubframe += 1
                }
            }
        } while minimumLength < frameLength
        return true
    }

    @_lifetime(reader: copy reader)
    private func decodeSubframeLength(_ reader: inout BitReader, offset: Int) -> Int? {
        let shortest = configuration.minimumSubframeLength
        let frameLength = configuration.samplesPerFrame
        // only one length fits in front of the frame end
        if offset == frameLength - shortest { return shortest }

        let width = WMAMath.floorLog2(configuration.maximumSubframes - 1) + 1
        let length = shortest * (Int(reader.read(width)) + 1)
        guard length >= shortest, length <= frameLength else { return nil }
        return length
    }

    // MARK: - The subframe

    /// Decodes the next subframe of the channels with the fewest samples so far.
    ///
    /// - Returns: zero, or a negative value on a fault or while no seekable tile has set the
    ///   filters
    @_lifetime(reader: copy reader)
    private func decodeSubframe(_ reader: inout BitReader) -> Int {
        let channels = configuration.channelCount
        let frameLength = configuration.samplesPerFrame
        let depth = configuration.bitsPerSample
        var offset = frameLength
        var subframeLength = frameLength
        var total = frameLength * channels

        for channel in 0..<channels where offset > subframes[channel].decodedSamples {
            offset = subframes[channel].decodedSamples
            subframeLength = subframes[channel].lengths[subframes[channel].current]
        }

        channelsForSubframe.removeAll(keepingCapacity: true)

        for channel in 0..<channels {
            let tiling = subframes[channel]
            total -= tiling.decodedSamples

            if offset == tiling.decodedSamples, subframeLength == tiling.lengths[tiling.current] {
                total -= tiling.lengths[tiling.current]
                subframes[channel].decodedSamples += tiling.lengths[tiling.current]
                channelsForSubframe.append(channel)
            }
        }
        if total == 0 { parsedAllSubframes = true }

        seekableTile = reader.readBit()

        if seekableTile {
            clearCodecBuffers()
            // arithmetic coding has no reference decoder to port
            if reader.readBit() { return -1 }
            usesACFilter = reader.readBit()
            usesInterChannel = reader.readBit()
            usesMCLMS = reader.readBit()

            if usesACFilter { decodeACFilter(&reader) }
            if usesMCLMS { decodeMCLMS(&reader) }
            guard decodeCDLMS(&reader) else { return -1 }
            movingAverageScaling = Int(reader.read(3))
            quantStep = Int(reader.read(8)) + 1
            resetCodec()
        }

        let isRawPCM = reader.readBit()
        guard isRawPCM || cdlmsOrder[0] != 0 else {
            // the stream opened partway, and nothing decodes before a seekable tile
            frameSampleCount = 0
            return -1
        }
        for channel in 0..<channels { isChannelCoded[channel] = true }

        if !isRawPCM {
            for channel in 0..<channels { isChannelCoded[channel] = reader.readBit() }

            if configuration.isVersion3RTM {
                usesLPC = reader.readBit()
                if usesLPC { decodeLPC(&reader) }
            } else {
                usesLPC = false
            }
        }
        guard reservoir.readerSize - reader.cursor >= 1 else { return -1 }
        let padding = reader.readBit() ? Int(reader.read(5)) : 0

        if isRawPCM {
            let width = depth - padding
            guard width > 0 else { return -1 }

            channelResidues.withExclusiveAccess { residues in
                for channel in 0..<channels {
                    let base = channel * frameLength

                    for index in 0..<subframeLength {
                        residues[base + index] = reader.readSignedLossless(width)
                    }
                }
            }
        } else {
            guard depth >= padding else { return -1 }

            for channel in 0..<channels {
                if isChannelCoded[channel] {
                    decodeChannelResidues(&reader, channel: channel, tileSize: subframeLength)

                    if seekableTile {
                        useHighUpdateSpeed(channel)
                    } else {
                        useNormalUpdateSpeed(channel)
                    }
                    revertCDLMS(channel, count: subframeLength)
                } else {
                    let base = channel * frameLength
                    channelResidues.withExclusiveAccess { residues in
                        for index in base..<(base + subframeLength) { residues[index] = 0 }
                    }
                }
            }
            if usesMCLMS { revertMCLMS(subframeLength) }
            if usesInterChannel { revertInterChannel(subframeLength) }
            if usesACFilter { revertACFilter(subframeLength) }

            if quantStep != 1 {
                let step = Int32(truncatingIfNeeded: quantStep)

                channelResidues.withExclusiveAccess { residues in
                    for channel in 0..<channels {
                        let base = channel * frameLength
                        for index in base..<(base + subframeLength) { residues[index] &*= step }
                    }
                }
            }
        }

        writeSubframe(padding: padding)

        for channel in channelsForSubframe {
            var tiling = MutableRef(&subframes[channel])
            guard tiling.value.current < tiling.value.count else { return -1 }
            tiling.value.current += 1
        }
        return 0
    }

    /// Writes each subframe channel's residues into the frame, shifted up past the padding bits.
    private func writeSubframe(padding: Int) {
        let frameLength = configuration.samplesPerFrame
        let isShort = configuration.bitsPerSample == 16
        let wide = UInt32(256) &<< padding

        for channel in channelsForSubframe {
            let tiling = subframes[channel]
            let length = tiling.lengths[tiling.current]
            let residues = channel * frameLength
            let source = channelResidues
            var position = writePositions[channel]

            frameSamples.withExclusiveAccess { samples in
                for index in 0..<length where position < frameLength {
                    let residue = source[residues + index]
                    samples[channel * frameLength + position] =
                        if isShort {
                            Int32(Int16(
                                truncatingIfNeeded: Int32(Int16(truncatingIfNeeded: residue))
                                    &<< padding))
                        } else {
                            Int32(bitPattern: UInt32(bitPattern: residue) &* wide)
                        }
                    position += 1
                }
            }
            writePositions[channel] = position
        }
    }

    // MARK: - The filter headers

    @_lifetime(reader: copy reader)
    private func decodeACFilter(_ reader: inout BitReader) {
        acOrder = Int(reader.read(4)) + 1
        acScaling = Int(reader.read(4))

        for index in 0..<acOrder {
            acCoefficients[index] = Int16(truncatingIfNeeded: reader.read(acScaling) + 1)
        }
    }

    @_lifetime(reader: copy reader)
    private func decodeMCLMS(_ reader: inout BitReader) {
        let channels = configuration.channelCount
        mclmsOrder = (Int(reader.read(4)) + 1) * 2
        mclmsScaling = Int(reader.read(4))
        guard reader.readBit() else { return }

        let width = Int(reader.read(Self.bitsToHold(mclmsScaling + 1))) + 2

        for index in 0..<(mclmsOrder * channels * channels) {
            mclmsCoefficients[index] = Int16(truncatingIfNeeded: reader.read(width))
        }
        for channel in 0..<channels {
            for other in 0..<channel {
                mclmsCurrent[channel * channels + other] = Int16(truncatingIfNeeded: reader.read(
                    width))
            }
        }
    }

    /// Reads the cascade of CDLMS filters each channel runs, answering false for an order past 256.
    @_lifetime(reader: copy reader)
    private func decodeCDLMS(_ reader: inout BitReader) -> Bool {
        let sendsCoefficients = reader.readBit()

        for channel in 0..<configuration.channelCount {
            let first = channel * Self.filtersPerChannel
            let count = Int(reader.read(3)) + 1
            let filters = first..<(first + count)
            cdlmsCount[channel] = count

            for filter in filters {
                let order = (Int(reader.read(7)) + 1) * 8
                guard order <= 256 else {
                    cdlmsOrder[0] = 0
                    return false
                }
                cdlmsOrder[filter] = order
            }
            for filter in filters { cdlmsScaling[filter] = Int(reader.read(4)) }

            if sendsCoefficients {
                for filter in filters {
                    let sent = Int(reader.read(Self.bitsToHold(cdlmsOrder[filter]))) + 1
                    let width = Int(reader.read(Self.bitsToHold(cdlmsScaling[filter] + 1))) + 2
                    let left = 32 - width
                    let right = 32 - cdlmsScaling[filter] - 2
                    let base = filter * Self.cdlmsCoefficientStride

                    // the shifts run on an unsigned value, as FFmpeg's do, so no sign extends
                    for index in 0..<sent {
                        let value = (reader.read(width) &<< left) &>> right
                        cdlmsCoefficients[base + index] = Int16(truncatingIfNeeded: value)
                    }
                }
            }
            for filter in filters {
                let base = filter * Self.cdlmsCoefficientStride + cdlmsOrder[filter]
                for index in base..<(base + 8) { cdlmsCoefficients[index] = 0 }
            }
        }
        return true
    }

    @_lifetime(reader: copy reader)
    private func decodeLPC(_ reader: inout BitReader) {
        lpcOrder = Int(reader.read(5)) + 1
        lpcScaling = Int(reader.read(4))
        lpcIntegerBits = Int(reader.read(3)) + 1
        let width = lpcScaling + lpcIntegerBits

        for channel in 0..<configuration.channelCount {
            for index in 0..<lpcOrder {
                lpcCoefficients[channel * 40 + index] = reader.readSignedLossless(width)
            }
        }
    }

    // MARK: - The residues

    /// Reads one channel's residues, each an adaptive Golomb code whose remainder width follows a
    /// moving average of the values before it.
    @_lifetime(reader: copy reader)
    func decodeChannelResidues(_ reader: inout BitReader, channel: Int, tileSize: Int) {
        let depth = configuration.bitsPerSample
        let scaling = movingAverageScaling
        let base = channel * configuration.samplesPerFrame

        transient[channel] = reader.readBit()

        if transient[channel] {
            transientPosition[channel] = Int(reader.read(WMAMath.floorLog2(tileSize)))
            if transientPosition[channel] != 0 { transient[channel] = false }
            transientCounter[channel] = max(
                transientCounter[channel], configuration.samplesPerFrame / 2)
        } else if transientCounter[channel] != 0 { transient[channel] = true }

        var index = 0

        if seekableTile {
            averageSum[channel] = reader.read(depth) &<< (scaling + 1)
            channelResidues[base] = reader.readSignedLossless(depth + (usesInterChannel ? 1 : 0))
            index = 1
        }

        while index < tileSize {
            var quotient: UInt32 = 0

            while reader.readBit() {
                quotient &+= 1
                if reservoir.readerSize - reader.cursor <= 0 { return }
            }
            if quotient >= 32 { quotient &+= reader.read(Int(reader.read(5)) + 1) }

            let mean = (averageSum[channel] &+ (1 << scaling)) &>> (scaling + 1)
            var residue = quotient

            if mean > 1 {
                let width = WMAMath.ceilLog2(Int(mean))
                residue = (quotient &<< width) &+ reader.read(width)
            }
            averageSum[channel] = residue &+ averageSum[channel]
                &- (averageSum[channel] &>> scaling)

            residue = (residue &>> 1) ^ (0 &- (residue & 1))
            channelResidues[base + index] = Int32(bitPattern: residue)
            index += 1
        }
    }

    /// The width that holds every value below `count`, which FFmpeg writes as a log and a round up.
    private static func bitsToHold(_ count: Int) -> Int {
        let bits = WMAMath.floorLog2(count)
        return 1 << bits < count ? bits + 1 : bits
    }
}

fileprivate extension BitReader {
    /// Reads `width` bits as a two's complement value, one to 32.
    @_lifetime(self: copy self)
    mutating func readSignedLossless(_ width: Int) -> Int32 {
        guard width > 0 else { return 0 }
        let shift = 32 - width
        return Int32(bitPattern: read(width) &<< shift) &>> shift
    }
}
