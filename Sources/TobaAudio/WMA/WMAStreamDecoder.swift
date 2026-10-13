internal import Foundation

/// Decodes the media objects of one WMA stream into interleaved samples between minus one and one.
///
/// Each codec of the family conforms, and ``WMAAudioFile`` picks one off the stream's format tag.
protocol WMAStreamDecoder: AnyObject {
    /// Decodes one ASF media object. An object that only fills a reservoir answers no samples.
    func decode(_ packet: Data) throws(AudioReadError) -> [Float]

    /// Drops every frame the decoder holds, which a seek needs before it decodes elsewhere.
    func reset()

    /// Decodes the frames still held once the last media object has passed.
    func drain() -> [Float]
}

extension WMAStreamDecoder {
    func drain() -> [Float] { [] }
}

extension WMADecoder: WMAStreamDecoder {}

extension WMAStreamFormat {
    /// The decoder the format tag names.
    func makeDecoder() throws(AudioReadError) -> any WMAStreamDecoder {
        switch codec {
            case WMAVersion.one.rawValue, WMAVersion.two.rawValue: try WMADecoder(format: self)
            case WMAProDecoder.formatTag: try WMAProDecoder(format: self)
            case WMALosslessDecoder.formatTag: try WMALosslessDecoder(format: self)
            case WMAVoiceDecoder.formatTag: try WMAVoiceDecoder(format: self)
            default: throw .malformed("WMA codec \(codec)")
        }
    }
}
