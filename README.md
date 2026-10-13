# swift-wma

A Swift port of the Windows Media Audio decoders of [FFmpeg][]. It decodes WMA v1, WMA v2,
WMA Pro, WMA Lossless and WMA Voice from an ASF file to interleaved float samples.

## Purpose

This repository publishes source. It exists so that any person who has Musup, a music
player for macOS and iOS, can read, change and use the WMA decoder that Musup contains. Toba makes Musup, and the Musup
repository is private.

Apple platforms decode no `.wma` file, so Musup carries a decoder of its own. That decoder is a
port of FFmpeg code, and FFmpeg is under the GNU Lesser General Public License. The license
keeps the port open, and this repository is where the port is open.

## Provenance

- **Upstream.** Each decoder is a port of the C source of FFmpeg, in `libavcodec`, `libavutil`
  and `libavformat`. The port follows FFmpeg at commit
  [`c766e0d`](https://github.com/FFmpeg/FFmpeg/commit/c766e0de78b0239a36e49e50573e2297a7b500b4).
- **Change.** The port changes the language from C to Swift. It keeps the arithmetic of the
  upstream code, because the tests of the Pro, Lossless and Voice decoders compare each decode
  with the reference output of FFmpeg. The work
  started in 2026.
- **Constant tables.** No published specification of WMA exists. The Huffman tables, the
  codebooks and the band tables are transcribed from the FFmpeg headers, value for value.
- **Origin of the files.** The files are a copy of `Sources/TobaAudio/` in the Musup repository,
  which is private. The copy is from Musup commit `7676ff9dfcbe3c63645fb130d9e9bf84ea47b886`.
  The paths here are the paths there.
- **Upstream holders.** `NOTICE` holds the copyright line of each upstream file, as the header of
  that file states it.

## What Musup links

Musup does not link this repository. Musup compiles the same files as part of its `TobaAudio`
module, and the files here are a copy of those files. A change to the decoder in Musup comes
here as a new copy, and the provenance section then names the new Musup commit.

## What the repository holds

| Path | Content |
|---|---|
| `Sources/TobaAudio/WMA/` | The 38 files of the port |
| `Sources/TobaAudio/BitReader.swift` | The bit reader that each decoder reads through |
| `Sources/TobaAudio/ByteReader.swift` | The byte reader that the ASF walk reads through |
| `LICENSE` | The full text of the LGPL, version 2.1 |
| `NOTICE` | The provenance and the upstream copyright lines |

**The repository is not a Swift package, and the files do not compile alone.** Two symbols they
call stay in Musup:

- `AudioReadError`, the error type that each decoder throws. It is an enum with three cases:
  `unsupportedFormat(String)`, `unreadable(String)` and `malformed(String)`.
- `ASFReader.layout(of:)`, the walk over the header objects of an ASF file that
  `ASFHeaderInfo.swift` reads. It is part of the tag reader of Musup and is not a port of FFmpeg.

The repository holds no test and no audio fixture. The tests stay in Musup.

## The files and their FFmpeg sources

A row names each FFmpeg file that the Swift file ports or follows. A row with "none" holds no
FFmpeg code. The ASF rows name the FFmpeg demuxer as a precaution, because the ASF container
also has a published specification.

### `Sources/TobaAudio/WMA/`

| Swift file | FFmpeg file |
|---|---|
| `Array+ExclusiveAccess.swift` | none |
| `ASFGUID.swift` | `libavformat/asf.c` |
| `ASFHeaderInfo.swift` | `libavformat/asfdec_f.c` |
| `ASFPacketReader.swift` | `libavformat/asfdec_f.c` |
| `InverseMDCT.swift` | `libavutil/tx_template.c`, `libavcodec/sinewin_tablegen.h` |
| `WMAAudioFile.swift` | none |
| `WMABitWriter.swift` | `libavcodec/put_bits.h` |
| `WMACodeTable.swift` | `libavcodec/vlc.c`, `libavcodec/get_bits.h` |
| `WMACoefficientTables.swift` | `libavcodec/wmadata.h` |
| `WMAComputedTables.swift` | `libavcodec/wma.c`, `libavcodec/wmadec.c` |
| `WMAConfiguration.swift` | `libavcodec/wma.c`, `libavcodec/wmadec.c` |
| `WMADecoder.swift` | `libavcodec/wmadec.c` |
| `WMADecoder+Frame.swift` | `libavcodec/wmadec.c`, `libavcodec/wma.c` |
| `WMAFrameReservoir.swift` | `libavcodec/wmaprodec.c`, `libavcodec/wmalosslessdec.c` |
| `WMAMath.swift` | `libavutil/intmath.h`, `libavutil/common.h`, `libavcodec/wma_common.c` |
| `WMASeekTable.swift` | `libavcodec/wmadec.c` |
| `WMAStreamDecoder.swift` | none |
| `WMAStreamFormat.swift` | `libavcodec/wmadec.c`, `libavcodec/wma.c` |
| `WMATables.swift` | `libavcodec/wmadata.h`, `libavcodec/wma_freqs.c`, `libavcodec/aactab.c` |

### `Sources/TobaAudio/WMA/Pro/`

| Swift file | FFmpeg file |
|---|---|
| `WMAProCodeSet.swift` | `libavcodec/wmaprodec.c`, `libavcodec/wmaprodata.h` |
| `WMAProComputedTables.swift` | `libavcodec/wmaprodec.c`, `libavutil/ffmath.h` |
| `WMAProConfiguration.swift` | `libavcodec/wmaprodec.c` |
| `WMAProDecoder.swift` | `libavcodec/wmaprodec.c` |
| `WMAProDecoder+Frame.swift` | `libavcodec/wmaprodec.c`, `libavcodec/wma.c`, `libavcodec/wma_common.c` |
| `WMAProTables.swift` | `libavcodec/wmaprodata.h` |

### `Sources/TobaAudio/WMA/Lossless/`

| Swift file | FFmpeg file |
|---|---|
| `WMALosslessConfiguration.swift` | `libavcodec/wmalosslessdec.c` |
| `WMALosslessDecoder.swift` | `libavcodec/wmalosslessdec.c` |
| `WMALosslessDecoder+Filters.swift` | `libavcodec/wmalosslessdec.c`, `libavcodec/lossless_audiodsp.c` |
| `WMALosslessDecoder+Frame.swift` | `libavcodec/wmalosslessdec.c` |

### `Sources/TobaAudio/WMA/Voice/`

| Swift file | FFmpeg file |
|---|---|
| `CELPFilters.swift` | `libavcodec/celp_filters.c`, `libavcodec/acelp_filters.c`, `libavcodec/acelp_vectors.c`, `libavcodec/lsp.c` |
| `WMAVoiceDecoder.swift` | `libavcodec/wmavoice.c` |
| `WMAVoiceDecoder+Frame.swift` | `libavcodec/wmavoice.c` |
| `WMAVoiceDecoder+Postfilter.swift` | `libavcodec/wmavoice.c` |
| `WMAVoiceDecoder+Pulses.swift` | `libavcodec/wmavoice.c` |
| `WMAVoiceFrameType.swift` | `libavcodec/wmavoice.c` |
| `WMAVoiceScratch.swift` | `libavcodec/wmavoice.c` |
| `WMAVoiceTables.swift` | `libavcodec/wmavoice_data.h` |
| `WMAVoiceTransform.swift` | `libavutil/tx.c`, `libavutil/tx_template.c` |

### `Sources/TobaAudio/`

| Swift file | FFmpeg file |
|---|---|
| `BitReader.swift` | `libavcodec/get_bits.h` |
| `ByteReader.swift` | none |

## What the port refuses

- A WMA v1 stream with variable block length, because FFmpeg fills one band table for it and so
  gives no reference output.
- A WMA v1 or v2 stream that codes its exponents as line spectral pairs.
- A WMA Lossless stream with arithmetic coding, as FFmpeg refuses it.

## License

The port is under the GNU Lesser General Public License, version 2.1 or (at your option) any
later version. `LICENSE` holds the full text. `NOTICE` holds the upstream copyright lines.

The files with "none" in the tables above are in the same module as the port, and this
repository gives them under the same license.

This software comes with no warranty. The license text gives the details.

[FFmpeg]: https://github.com/FFmpeg/FFmpeg
