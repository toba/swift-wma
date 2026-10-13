internal import Foundation

/// The buffers one WMA Voice superframe decodes through, built once so a superframe allocates
/// nothing.
///
/// No value here outlives the superframe that writes it. The decoder's lasting state stays on the
/// decoder itself.
struct WMAVoiceScratch {
    var synthesis = [Float](
        repeating: 0, count: WMAVoiceDecoder.maximumLSPs + WMAVoiceDecoder.superframeSize)
    var excitation = [Float](
        repeating: 0,
        count: WMAVoiceDecoder.maximumHistory + WMAVoiceDecoder.superframeSize + 12)
    var samples = [Float](repeating: 0, count: WMAVoiceDecoder.superframeSize)

    /// The three frames' LSFs, `WMAVoiceDecoder.maximumLSPs` apart.
    var frameLSPs = [Double](repeating: 0, count: 3 * WMAVoiceDecoder.maximumLSPs)

    /// The current frame's LSFs and the ones in front of them.
    var lsps = [Double](repeating: 0, count: WMAVoiceDecoder.maximumLSPs)
    var previous = [Double](repeating: 0, count: WMAVoiceDecoder.maximumLSPs)

    var residualPrevious = [Double](repeating: 0, count: WMAVoiceDecoder.maximumLSPs)
    var residualFirst = [Double](repeating: 0, count: 32)
    var residualSecond = [Double](repeating: 0, count: 32)

    /// The cosines one LPC set is built from, and that set.
    var lspCosines = [Double](repeating: 0, count: WMAVoiceDecoder.maximumLSPs)
    var lpcs = [Float](repeating: 0, count: WMAVoiceDecoder.maximumLSPs)

    var pulses = [Float](repeating: 0, count: WMAVoiceDecoder.frameSize)
    var smoothed = [Float](repeating: 0, count: 80)

    // MARK: - The Wiener filter's spectra

    var speech = [Float](repeating: 0, count: 0x82)
    var filter = [Float](repeating: 0, count: 0x82)
    var spectrum = [Float](repeating: 0, count: 0x82)

    /// The response coefficients the inverse transform reads. The two values past 128 stay zero.
    var response = [Float](repeating: 0, count: 0x82)
    var filtered = [Float](repeating: 0, count: 0x82)
    var mirrored = [Float](repeating: 0, count: 0x82)
    var cosine = [Float](repeating: 0, count: 0x82)
    var phases = [Float](repeating: 0, count: 0x82)
}
