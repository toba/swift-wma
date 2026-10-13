/// The integer rules every WMA codec reads, named as FFmpeg names them.
enum WMAMath {
    /// FFmpeg's `av_log2`, the position of the highest set bit, which answers zero for zero.
    static func floorLog2(_ value: Int) -> Int {
        value > 0 ? Int.bitWidth - 1 - value.leadingZeroBitCount : 0
    }

    /// FFmpeg's `av_ceil_log2`, which works in 32 unsigned bits and answers zero for one.
    static func ceilLog2(_ value: Int) -> Int {
        let doubled = (UInt32(truncatingIfNeeded: value) &- 1) &<< 1
        return doubled == 0 ? 0 : 31 - doubled.leadingZeroBitCount
    }

    /// The frame length rule FFmpeg's `ff_wma_get_frame_len_bits` states for version 3, which WMA
    /// Pro and WMA Lossless share.
    static func version3FrameLengthBits(sampleRate: Int, decodeFlags: Int) -> Int {
        var bits =
            switch sampleRate {
                case ...16_000: 9
                case ...22_050: 10
                case ...48_000: 11
                case ...96_000: 12
                default: 13
            }
        switch decodeFlags & 0x6 {
            case 0x2: bits += 1
            case 0x4: bits -= 1
            case 0x6: bits -= 2
            default: break
        }
        return bits
    }
}
