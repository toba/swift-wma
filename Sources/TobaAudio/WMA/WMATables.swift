internal import Foundation

/// The constant tables a WMA v1 or v2 frame decodes through.
///
/// Every Huffman table here is the bitstream's own, so the values are transcribed rather than
/// derived. There is no rule that produces them, and one wrong entry decodes to noise rather than
/// to an error. They come from FFmpeg's `libavcodec`, which is the only published set: `wmadata.h`
/// holds the coefficient and gain tables, `wma_freqs.c` the band edges, and `aactab.c` the exponent
/// table WMA shares with AAC.
enum WMATables {
    /// The Bark scale critical band edges, in hertz.
    static let criticalFrequencies: [UInt16] = [
        100, 200, 300, 400, 510, 630, 770, 920,
        1080, 1270, 1480, 1720, 2000, 2320, 2700, 3150,
        3700, 4400, 5300, 6400, 7700, 9500, 12000, 15500,
        24500,
    ]

    /// The exponent band widths at 22050 hertz, the leading value naming how many widths follow it.
    static let exponentBands22050: [[UInt8]] = [
        [10, 4, 8, 4, 8, 8, 12, 20, 24, 24, 16],
        [14, 4, 8, 8, 4, 12, 12, 16, 24, 16, 20, 24, 32, 40, 36],
        [23, 4, 4, 4, 8, 4, 4, 8, 8, 8, 8, 8, 12, 12, 16, 16, 24, 24, 32, 44, 48, 60, 84, 72],
    ]

    /// The exponent band widths at 32000 hertz, the leading value naming how many widths follow it.
    static let exponentBands32000: [[UInt8]] = [
        [11, 4, 4, 8, 4, 4, 12, 16, 24, 20, 28, 4],
        [15, 4, 8, 4, 4, 8, 8, 16, 20, 12, 20, 20, 28, 40, 56, 8],
        [16, 8, 4, 8, 8, 12, 16, 20, 24, 40, 32, 32, 44, 56, 80, 112, 16],
    ]

    /// The exponent band widths at 44100 hertz, the leading value naming how many widths follow it.
    static let exponentBands44100: [[UInt8]] = [
        [12, 4, 4, 4, 4, 4, 8, 8, 8, 12, 16, 20, 36],
        [15, 4, 8, 4, 8, 8, 4, 8, 8, 12, 12, 12, 24, 28, 40, 76],
        [17, 4, 8, 8, 4, 12, 12, 8, 8, 24, 16, 20, 24, 32, 40, 60, 80, 152],
    ]

    /// The high band gain each code stands for.
    static let highGainSymbols: [UInt8] = [
        25, 2, 27, 0, 31, 30, 23, 7, 29, 26, 24, 10, 12, 20, 22, 8,
        33, 32, 5, 34, 35, 36, 3, 1, 4, 6, 28, 18, 16, 21, 9, 11,
        19, 14, 15, 13, 17,
    ]

    /// How many bits each high band gain code occupies.
    static let highGainLengths: [UInt8] = [
        10, 10, 10, 10, 9, 9, 8, 8, 8, 8, 7, 5, 4, 5, 6, 7,
        10, 13, 13, 13, 13, 13, 13, 12, 9, 9, 9, 4, 4, 5, 5, 4,
        4, 3, 3, 3, 3,
    ]

    /// The exponent delta codes, which WMA takes from AAC's scale factors.
    static let exponentCodes: [UInt32] = [
        0x3FFE8, 0x3FFE6, 0x3FFE7, 0x3FFE5, 0x7FFF5, 0x7FFF1, 0x7FFED, 0x7FFF6,
        0x7FFEE, 0x7FFEF, 0x7FFF0, 0x7FFFC, 0x7FFFD, 0x7FFFF, 0x7FFFE, 0x7FFF7,
        0x7FFF8, 0x7FFFB, 0x7FFF9, 0x3FFE4, 0x7FFFA, 0x3FFE3, 0x1FFEF, 0x1FFF0,
        0xFFF5, 0x1FFEE, 0xFFF2, 0xFFF3, 0xFFF4, 0xFFF1, 0x7FF6, 0x7FF7,
        0x3FF9, 0x3FF5, 0x3FF7, 0x3FF3, 0x3FF6, 0x3FF2, 0x1FF7, 0x1FF5,
        0x0FF9, 0x0FF7, 0x0FF6, 0x07F9, 0x0FF4, 0x07F8, 0x03F9, 0x03F7,
        0x03F5, 0x01F8, 0x01F7, 0x00FA, 0x00F8, 0x00F6, 0x0079, 0x003A,
        0x0038, 0x001A, 0x000B, 0x0004, 0x0000, 0x000A, 0x000C, 0x001B,
        0x0039, 0x003B, 0x0078, 0x007A, 0x00F7, 0x00F9, 0x01F6, 0x01F9,
        0x03F4, 0x03F6, 0x03F8, 0x07F5, 0x07F4, 0x07F6, 0x07F7, 0x0FF5,
        0x0FF8, 0x1FF4, 0x1FF6, 0x1FF8, 0x3FF8, 0x3FF4, 0xFFF0, 0x7FF4,
        0xFFF6, 0x7FF5, 0x3FFE2, 0x7FFD9, 0x7FFDA, 0x7FFDB, 0x7FFDC, 0x7FFDD,
        0x7FFDE, 0x7FFD8, 0x7FFD2, 0x7FFD3, 0x7FFD4, 0x7FFD5, 0x7FFD6, 0x7FFF2,
        0x7FFDF, 0x7FFE7, 0x7FFE8, 0x7FFE9, 0x7FFEA, 0x7FFEB, 0x7FFE6, 0x7FFE0,
        0x7FFE1, 0x7FFE2, 0x7FFE3, 0x7FFE4, 0x7FFE5, 0x7FFD7, 0x7FFEC, 0x7FFF4,
        0x7FFF3,
    ]

    /// How many bits each exponent delta code occupies.
    static let exponentLengths: [UInt8] = [
        18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
        19, 19, 19, 18, 19, 18, 17, 17, 16, 17, 16, 16, 16, 16, 15, 15,
        14, 14, 14, 14, 14, 14, 13, 13, 12, 12, 12, 11, 12, 11, 10, 10,
        10, 9, 9, 8, 8, 8, 7, 6, 6, 5, 4, 3, 1, 4, 4, 5,
        6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 11, 11, 11, 11, 12,
        12, 13, 13, 13, 14, 14, 16, 15, 16, 15, 18, 19, 19, 19, 19, 19,
        19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
        19, 19, 19, 19, 19, 19, 19, 19, 19,
    ]
}
