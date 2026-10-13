internal import Foundation

/// The pitch-adaptive window pulses, the fixed codebook of a low bit rate frame.
///
/// The first set places pulses around each pitch period, and the second places one more pulse at a
/// position the first set left free.
extension WMAVoiceDecoder {
    /// Where the first pulse of a frame starts, by coded index.
    private static let pulseStartOffsets: [Int] = [
        -11, -9, -7, -5, -3, -1, 1, 3, 5, 7, 9, 11,
        13, 15, 18, 17, 19, 20, 21, 22, 23, 24, 25, 26,
        27, 28, 29, 30, 31, 32, 33, 35, 37, 39, 41, 43,
        45, 47, 49, 51, 53, 55, 57, 59, 61, 63, 65, 67,
        69, 71, 73, 75, 77, 79, 81, 83, 85, 87, 89, 91,
        93, 95, 97, 99, 101, 103, 105, 107, 109, 111, 113, 115,
        117, 119, 121, 123, 125, 127, 129, 131, 133, 135, 137, 139,
        141, 143, 145, 147, 149, 151, 153, 155, 157, 159,
    ]

    /// Reads where the first pulses start, and how the two pitch periods split them between the two
    /// blocks, FFmpeg's `aw_parse_coords`.
    @_lifetime(reader: copy reader)
    func readPulseCoordinates(_ reader: inout BitReader, pitch first: Int, _ second: Int) {
        let startOffsets = Self.pulseStartOffsets
        let pitch = (first, second)
        let half = Self.frameSize / 2
        pulseIndexExtended = false
        var bits = Int(reader.read(6))

        if bits >= 54 {
            pulseIndexExtended = true
            bits += (bits - 54) * 3 + Int(reader.read(2))
        }

        pulseRange = min(pitch.0, pitch.1) > 32 ? 24 : 16
        var offset = startOffsets[bits]
        while offset < 0 { offset += pitch.0 }
        pulseCounts[0] = (pitch.0 - 1 + half - offset) / pitch.0
        firstPulseOffsets[0] = offset - pulseRange / 2
        offset += pulseCounts[0] * pitch.0
        pulseCounts[1] = (pitch.1 - 1 + Self.frameSize - offset) / pitch.1
        firstPulseOffsets[1] = offset - (Self.frameSize + pulseRange) / 2

        if startOffsets[bits] < half {
            while firstPulseOffsets[1] - pitch.1 + pulseRange > 0 {
                firstPulseOffsets[1] -= pitch.1
            }

            if startOffsets[bits] < 0 {
                while firstPulseOffsets[0] - pitch.0 + pulseRange > 0 {
                    firstPulseOffsets[0] -= pitch.0
                }
            }
        }
    }

    /// Reads the first set of pulses, FFmpeg's `aw_pulse_set1`.
    @_lifetime(reader: copy reader)
    func readFirstPulses(_ reader: inout BitReader, block: Int, into fixed: inout FixedPulses) {
        var value = Int(reader.read(12 - 2 * (pulseIndexExtended && block == 0 ? 1 : 0)))

        if pulseCounts[block] > 0 {
            let (count, signMask, indexMask, shift) = pulseRange == 24 ? (3, 8, 7, 4) : (4, 4, 3, 3)
            var n = count - 1

            while n >= 0 {
                var position = (value & indexMask) * count + n + firstPulseOffsets[block]
                while position < 0 { position += fixed.pitchLag }

                if position < Self.frameSize / 2 {
                    fixed.add(position, value & signMask != 0 ? -1 : 1)
                }
                n -= 1
                value >>= shift
            }
        } else {
            let pair = (value & 0x1FF) >> 1
            let (delta, index): (Int, Int) =
                switch pair {
                    case ..<79: (1, pair + 1)
                    case ..<156: (3, pair + 1 - 77)
                    case ..<231: (5, pair + 1 - 152)
                    default: (7, pair + 1 - 225)
                }
            let sign: Float = value & 0x200 != 0 ? -1 : 1

            fixed.noRepeatMask |= 3 << fixed.pulseCount
            fixed.add(index - delta, sign)
            fixed.add(index, value & 1 != 0 ? -sign : sign)
        }
    }

    /// Reads the one pulse of the second set, FFmpeg's `aw_pulse_set2`.
    ///
    /// The pulse takes the coded count of free positions, skipping those the first set occupies.
    /// The answer is false when no position is free, which conceals the block.
    @_lifetime(reader: copy reader)
    func readSecondPulse(
        _ reader: inout BitReader,
        block: Int,
        into fixed: inout FixedPulses
    ) -> Bool {
        let half = Self.frameSize / 2
        var pulseOffset = firstPulseOffsets[block]
        var start = 0

        if pulseCounts[block] > 0 {
            while pulseOffset + pulseRange < 1 { pulseOffset += fixed.pitchLag }
        }

        let range: Int

        if pulseCounts[0] > 0 {
            if block == 0 {
                range = 32
            } else {
                range = 8
                if pulseCounts[block] > 0 { pulseOffset = nextPulseOffset }
            }
        } else {
            range = 16
        }
        var pulseStart = pulseCounts[block] > 0 ? pulseOffset - range / 2 : 0

        // one bit per position, most significant first, with two words of padding on each side
        var mask = InlineArray<9, UInt16>(repeating: 0)
        for i in 2..<7 { mask[i] = 0xFFFF }

        if pulseCounts[block] > 0 {
            var index = pulseOffset

            while index < half {
                var word = (index >> 4) + 2
                let firstShift = 16 - (index & 15)
                mask[word] &= UInt16(truncatingIfNeeded: UInt32(0xFFFF) << UInt32(firstShift))
                word += 1
                let excluded = pulseRange - firstShift

                if excluded >= 16 {
                    mask[word] = 0
                    mask[word + 1] &= UInt16(0xFFFF) >> UInt16(excluded - 16)
                } else {
                    mask[word] &= UInt16(0xFFFF) >> UInt16(excluded)
                }
                index += fixed.pitchLag
            }
        }

        let wanted = Int(reader.read(pulseCounts[0] > 0 ? 5 - 2 * block : 4))
        var found = 0

        while found <= wanted {
            var index = pulseStart
            while index < 0 { index += fixed.pitchLag }

            if index >= half {
                var word = 2
                while word < 7, mask[word] == 0 { word += 1 }
                guard word < 7 else { return false }
                let highest = 15 - mask[word].leadingZeroBitCount
                index = (word - 2) * 16 + 15 - highest
            }
            let bit = UInt16(0x8000) >> UInt16(index & 15)

            if mask[(index >> 4) + 2] & bit != 0 {
                mask[(index >> 4) + 2] &= ~bit
                found += 1
                start = index
            }
            pulseStart += 1
        }

        fixed.add(start, reader.readBit() ? -1 : 1)

        let rest = (half - start) % fixed.pitchLag
        nextPulseOffset = rest != 0 ? fixed.pitchLag - rest : 0
        return true
    }
}
