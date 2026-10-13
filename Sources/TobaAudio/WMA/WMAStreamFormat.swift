internal import Foundation

/// The `WAVEFORMATEX` of an ASF audio stream, with the codec's own bytes behind it.
struct WMAStreamFormat: Equatable, Sendable {
    /// Which codec the stream carries, as its format tag. ``makeDecoder()`` reads it.
    var codec: Int

    var channelCount: Int
    var sampleRate: Int

    /// The encoded rate in bits per second, taken from the average byte rate.
    var bitRate: Int

    /// How many bytes one codec packet occupies.
    var blockAlign: Int

    var bitDepth: Int

    /// The codec's own bytes, which carry the encoder options for WMA.
    var extra: Data
}

/// The Windows Media Audio versions this package decodes, by format tag.
enum WMAVersion: Int, Sendable {
    case one = 0x0160
    case two = 0x0161

    /// Where the encoder options sit in the extra bytes.
    var optionsIndex: Int { self == .one ? 2 : 4 }

    /// The first coefficient the bitstream codes.
    var coefficientStart: Int { self == .one ? 3 : 0 }

    /// The highest sample rate that takes the 1024-sample frame.
    var shortFrameLimit: Int { self == .one ? 32_000 : 22_050 }

    /// Whether the high band rule rounds the sample rate down to one its tables are written for.
    var roundsSampleRate: Bool { self == .two }

    /// Whether a block states its first exponent rather than starting from 36.
    var statesFirstExponent: Bool { self == .one }

    /// Whether this decoder follows a frame that splits into shorter blocks.
    ///
    /// FFmpeg fills one band table for a v1 stream that splits, so it gives no reference to port.
    var decodesVariableBlockLength: Bool { self == .two }

    /// What the transform's output scale takes on top of the block length.
    func transformScale(blockLength: Int) -> Float {
        self == .one ? Float(blockLength / 2).squareRoot() : 1
    }
}

/// The encoder options a WMA v1 or v2 stream states in its extra bytes.
///
/// The decode path branches on all three, so a stream that sets none decodes by a different route
/// from one that sets them all.
struct WMAEncodeOptions: Equatable, Sendable {
    /// The whole word, which the block size count reads two more bits out of.
    var raw: UInt16

    /// Whether the exponents are Huffman coded rather than carried as line spectral pairs.
    var usesExponentVLC: Bool { raw & 0x0001 != 0 }

    /// Whether a frame borrows bits from the super frames around it.
    var usesBitReservoir: Bool { raw & 0x0002 != 0 }

    /// Whether a frame splits into blocks shorter than the full frame.
    var usesVariableBlockLength: Bool { raw & 0x0004 != 0 }

    /// How many times a frame may halve its block length, before the bit rate raises it.
    var blockSizeSteps: Int { (Int(raw >> 3) & 0x03) + 1 }

    /// Reads the options a stream states in the extra bytes `cbSize` counts.
    ///
    /// The bytes around the options state a sample count and a super block size that no decode step
    /// reads.
    init(extra: Data, version: WMAVersion) throws(AudioReadError) {
        let index = version.optionsIndex
        guard extra.count >= index + 2 else { throw .malformed("WMA encoder options") }
        let start = extra.startIndex + index
        raw = UInt16(extra[start]) | UInt16(extra[start + 1]) << 8
    }
}
