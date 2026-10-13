public import Foundation

/// Reads a WMA file as PCM, a packet at a time.
///
/// This is the decode surface outside this package. Core Audio opens no WMA file, so a player that
/// wants one reaches it here rather than through `ExtAudioFile`.
///
/// ```swift
/// let file = try WMAAudioFile(contentsOf: url)
/// while let block = try file.readNext() {
///     render(block, channels: file.channelCount)
/// }
/// ```
///
/// A block holds interleaved samples between minus one and one, and its length varies. A packet
/// carries one to fifteen frames, and the first packets of a file carry none at all while the bit
/// reservoir fills.
public final class WMAAudioFile {
    public let sampleRate: Int
    public let channelCount: Int

    /// How long the file plays, in seconds.
    public let duration: Double

    /// How many frames the file holds, taken from its stated duration.
    public let totalFrames: Int64

    private let bytes: Data
    private let header: ASFHeaderInfo
    private let decoder: any WMAStreamDecoder
    private var packets: ASFPacketReader

    /// How many frames still to drop, which a seek sets.
    ///
    /// The file's preroll never lands here. It states how long a client buffers before it plays,
    /// not a run of samples to discard, and dropping it takes the first seconds of the track.
    private var skipping: Int

    /// Whether the decoder has answered the frames it held past the last packet.
    private var drained = false

    /// How many objects the walk answers that the decode drops unread, which a seek sets.
    private var objectsToDrop = 0

    /// Whether the decode opened midway, so a failure there retries from the first packet.
    private var resumed = false

    /// The restart points of a v1 or v2 stream, read on the first seek that wants one.
    private lazy var seekTable: WMASeekTable? = (decoder as? WMADecoder).flatMap {
        WMASeekTable(bytes: bytes, header: header, decoder: $0)
    }

    /// How many media objects the decoder has taken since the open or the last seek.
    private(set) var objectsDecoded = 0

    /// Where the next block the reader answers starts.
    private(set) public var frameOffset: Int64 = 0

    /// Opens the file at `url`.
    ///
    /// The file is mapped rather than copied, so the reader touches only the packets it decodes.
    ///
    /// - Throws: ``AudioReadError/unreadable(_:)`` when the file will not map, and
    ///   ``AudioReadError/malformed(_:)`` when it carries no WMA stream this decodes
    public init(contentsOf url: URL) throws(AudioReadError) {
        do {
            bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        header = try ASFHeaderInfo.read(bytes)
        decoder = try header.format.makeDecoder()
        packets = ASFPacketReader(bytes: bytes, header: header)

        sampleRate = header.format.sampleRate
        channelCount = header.format.channelCount
        duration = header.duration
        totalFrames = Int64(duration * Double(header.format.sampleRate))
        skipping = 0
    }

    /// The next block of interleaved samples, or `nil` at the end of the file.
    ///
    /// A packet that only fills the bit reservoir answers nothing, so this decodes packets until
    /// one yields samples rather than answering an empty block.
    public func readNext() throws(AudioReadError) -> [Float]? {
        while true {
            var block: [Float]

            if let object = try packets.next() {
                if objectsToDrop > 0 {
                    objectsToDrop -= 1
                    continue
                }
                objectsDecoded += 1

                do {
                    block = try decoder.decode(object.bytes)
                } catch {
                    // a fresh decoder can miss state the straight read carries, so that read wins
                    guard resumed else { throw error }
                    seekFromStart(to: frameOffset)
                    continue
                }
            } else if !drained {
                drained = true
                block = decoder.drain()
            } else {
                return nil
            }
            guard !block.isEmpty else { continue }

            if skipping > 0 {
                let dropped = min(skipping, block.count / channelCount)
                skipping -= dropped
                block.removeFirst(dropped * channelCount)
                if block.isEmpty { continue }
            }
            frameOffset += Int64(block.count / channelCount)
            return block
        }
    }

    /// Moves the read position to `frame`, and the next block starts exactly there.
    ///
    /// A v1 or v2 stream resumes at a packet before the target and drops the frames in front of it.
    /// Any other stream carries state no header states, so its walk restarts at the first packet.
    ///
    /// - Parameter frame: counted from the first sample the file plays
    public func seek(toFrame frame: Int64) {
        let target = max(0, min(frame, totalFrames))

        guard target > 0, let table = seekTable, let entry = table.entry(reaching: target) else {
            seekFromStart(to: target)
            return
        }
        decoder.reset()
        packets = ASFPacketReader(bytes: bytes, header: header, resumingAt: entry.start)
        objectsToDrop = entry.skip
        // the fresh decode answers its first frame one frame past the entry
        skipping = Int(target - entry.position) - table.frameLength
        resumed = true
        drained = false
        objectsDecoded = 0
        frameOffset = target
    }

    private func seekFromStart(to target: Int64) {
        decoder.reset()
        packets = ASFPacketReader(bytes: bytes, header: header)
        objectsToDrop = 0
        skipping = Int(target)
        resumed = false
        drained = false
        objectsDecoded = 0
        frameOffset = target
    }
}
