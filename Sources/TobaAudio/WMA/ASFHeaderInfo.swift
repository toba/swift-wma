internal import Foundation

/// What the decode path needs out of an ASF file's header objects.
///
/// The tag path reads the same objects through ``ASFReader`` and keeps different fields, so the two
/// walks stay apart.
struct ASFHeaderInfo: Equatable, Sendable {
    /// The audio stream's number, which every payload of that stream carries.
    var streamNumber: Int

    var format: WMAStreamFormat

    /// Where the first data packet starts.
    var firstPacketOffset: Int

    /// How many data packets follow, already held down to what the file's bytes carry.
    var packetCount: Int

    /// The size a packet that states none of its own takes.
    var packetSize: Int

    /// The lead-in the encoder wrote, in milliseconds. It is buffering rather than audio, so the
    /// decode drops that much from the front.
    var preroll: Int

    /// How long the file plays, in seconds, with the preroll already taken off.
    var duration: Double
}

extension ASFHeaderInfo {
    /// Reads the header objects of an ASF file.
    ///
    /// - Throws: ``AudioReadError/malformed(_:)`` when the file states no audio stream, no file
    ///   properties or no data object
    static func read(_ data: Data) throws(AudioReadError) -> Self {
        let layout = try ASFReader.layout(of: data)
        var file: FileFacts?
        var audio: StreamFacts?

        for child in layout.children {
            switch child.identifier {
                case ASFGUID.fileProperties: file = try readFileFacts(child.body)
                case ASFGUID.streamProperties: audio = try readStreamFacts(child.body) ?? audio
                default: break
            }
        }

        guard let file else { throw .malformed("ASF file properties object") }
        guard let audio else { throw .malformed("ASF audio stream properties object") }

        let stated = try readDataObject(data, at: layout.headerSize)
        let packetSize = file.minimumPacketSize
        guard packetSize > 0 else { throw .malformed("ASF minimum packet size") }

        // a truncated file states more packets than it carries, and the walk stops at the bytes
        let carried = (data.count - stated.firstPacketOffset) / packetSize
        let counted = stated.packetCount > 0 ? stated.packetCount : file.packetCount

        return .init(
            streamNumber: audio.streamNumber,
            format: audio.format,
            firstPacketOffset: stated.firstPacketOffset,
            packetCount: min(max(0, counted), max(0, carried)),
            packetSize: packetSize,
            preroll: file.preroll,
            duration: file.duration
        )
    }

    // MARK: - The objects

    /// Reads the File Properties Object, which states the packet sizes and the play duration.
    ///
    /// The duration is in units of 100 nanoseconds and it counts the preroll, so subtracting the
    /// preroll gives the length a person hears.
    private static func readFileFacts(_ body: Data) throws(AudioReadError) -> FileFacts {
        var reader = ByteReader(body)
        // the file identifier, the file size and the creation date
        try reader.skip(32, "ASF file properties preamble")
        let packetCount = try Int(clamping: reader.readUInt64(.little, "ASF data packet count"))
        let playDuration = try reader.readUInt64(.little, "ASF play duration")
        try reader.skip(8, "ASF send duration")
        let preroll = try Int(clamping: reader.readUInt64(.little, "ASF preroll"))
        try reader.skip(4, "ASF file flags")
        let minimum = try Int(reader.readUInt32(.little, "ASF minimum packet size"))
        let maximum = try Int(reader.readUInt32(.little, "ASF maximum packet size"))

        return .init(
            packetCount: packetCount,
            minimumPacketSize: minimum,
            maximumPacketSize: maximum,
            preroll: preroll,
            duration: max(0, Double(playDuration) / 10_000_000 - Double(preroll) / 1000)
        )
    }

    /// Reads the Stream Properties Object of the audio stream, whose type-specific data is a
    /// `WAVEFORMATEX`.
    ///
    /// A file carries one such object per stream, so a video stream's object reads as `nil` and the
    /// walk keeps looking.
    private static func readStreamFacts(_ body: Data) throws(AudioReadError) -> StreamFacts? {
        var reader = ByteReader(body)
        guard try reader.read(16, "ASF stream type") == ASFGUID.audioMedia else { return nil }
        // the error correction type and the time offset
        try reader.skip(24, "ASF stream preamble")
        let specificLength = try Int(reader.readUInt32(.little, "ASF stream data length"))
        try reader.skip(4, "ASF error correction data length")
        let flags = try reader.readUInt16(.little, "ASF stream flags")
        try reader.skip(4, "ASF stream reserved word")
        guard specificLength >= 18 else { throw .malformed("WAVEFORMATEX") }

        let codec = try Int(reader.readUInt16(.little, "WAVEFORMATEX format tag"))
        let channels = try Int(reader.readUInt16(.little, "WAVEFORMATEX channels"))
        let rate = try Int(reader.readUInt32(.little, "WAVEFORMATEX sample rate"))
        let byteRate = try Int(reader.readUInt32(.little, "WAVEFORMATEX byte rate"))
        let blockAlign = try Int(reader.readUInt16(.little, "WAVEFORMATEX block align"))
        let depth = try Int(reader.readUInt16(.little, "WAVEFORMATEX bit depth"))
        let stated = try Int(reader.readUInt16(.little, "WAVEFORMATEX extra length"))
        let extra = try reader.read(min(stated, specificLength - 18), "WAVEFORMATEX extra bytes")

        return .init(
            streamNumber: Int(flags & 0x7F),
            format: .init(
                codec: codec,
                channelCount: channels,
                sampleRate: rate,
                bitRate: byteRate * 8,
                blockAlign: blockAlign,
                bitDepth: depth,
                extra: extra
            )
        )
    }

    /// Reads the Data Object's own header, which sits directly behind the Header Object.
    private static func readDataObject(
        _ data: Data,
        at offset: Int
    ) throws(AudioReadError) -> (packetCount: Int, firstPacketOffset: Int) {
        var reader = ByteReader(data)
        try reader.seek(to: offset, "ASF data object")
        guard try reader.read(16, "ASF data object identifier") == ASFGUID.data else {
            throw .malformed("ASF data object identifier")
        }
        // the object's own size and the file identifier it repeats
        try reader.skip(24, "ASF data object preamble")
        let count = try Int(clamping: reader.readUInt64(.little, "ASF total data packets"))
        try reader.skip(2, "ASF data object reserved bytes")
        return (count, reader.offset)
    }

    // MARK: - What each object contributes

    private struct FileFacts {
        let packetCount: Int
        let minimumPacketSize: Int
        let maximumPacketSize: Int
        let preroll: Int
        let duration: Double
    }

    private struct StreamFacts {
        let streamNumber: Int
        let format: WMAStreamFormat
    }
}
