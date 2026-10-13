internal import Foundation

/// One of the 17 frame shapes a WMA Voice frame header names.
struct WMAVoiceFrameType {
    /// How the adaptive codebook, the pitch-predicted part of the excitation, is coded.
    enum Adaptive: Equatable {
        /// No adaptive part, only the fixed codebook.
        case none
        /// One pitch per frame, interpolated per sample through an asymmetric sinc window.
        case asymmetric
        /// One pitch per block, interpolated through a Hamming sinc window.
        case hamming
    }

    /// How the fixed codebook, the innovation part of the excitation, is coded.
    enum Fixed: Int, Comparable {
        case silence
        case hardcoded
        case adaptiveWindowPulses
        case excitationPulses

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How many blocks split the frame's 160 samples.
    let blocks: Int
    let logBlocks: Int
    let adaptive: Adaptive
    let fixed: Fixed

    /// How many of the five pulse tracks carry a pair rather than a single pulse.
    let doublePulses: Int

    static let all: [Self] = [
        .init(blocks: 1, logBlocks: 0, adaptive: .none, fixed: .silence, doublePulses: 0),
        .init(blocks: 2, logBlocks: 1, adaptive: .none, fixed: .hardcoded, doublePulses: 0),
        .init(
            blocks: 2, logBlocks: 1, adaptive: .asymmetric, fixed: .adaptiveWindowPulses,
            doublePulses: 0),
        .init(
            blocks: 2, logBlocks: 1, adaptive: .asymmetric, fixed: .excitationPulses,
            doublePulses: 2),
        .init(
            blocks: 2, logBlocks: 1, adaptive: .asymmetric, fixed: .excitationPulses,
            doublePulses: 5),
        .init(
            blocks: 4, logBlocks: 2, adaptive: .asymmetric, fixed: .excitationPulses,
            doublePulses: 0),
        .init(
            blocks: 4, logBlocks: 2, adaptive: .asymmetric, fixed: .excitationPulses,
            doublePulses: 2),
        .init(
            blocks: 4, logBlocks: 2, adaptive: .asymmetric, fixed: .excitationPulses,
            doublePulses: 5),
        .init(
            blocks: 2, logBlocks: 1, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 0),
        .init(
            blocks: 2, logBlocks: 1, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 2),
        .init(
            blocks: 2, logBlocks: 1, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 5),
        .init(
            blocks: 4, logBlocks: 2, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 0),
        .init(
            blocks: 4, logBlocks: 2, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 2),
        .init(
            blocks: 4, logBlocks: 2, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 5),
        .init(
            blocks: 8, logBlocks: 3, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 0),
        .init(
            blocks: 8, logBlocks: 3, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 2),
        .init(
            blocks: 8, logBlocks: 3, adaptive: .hamming, fixed: .excitationPulses,
            doublePulses: 5),
    ]

    /// Reads a frame type code, which is up to six pairs of set bits and then two more bits.
    ///
    /// Each pair of set bits moves the code three symbols on, and the last level takes all four.
    /// That is the canonical code FFmpeg builds from the lengths 2, 4, 6, 8, 10, 12 and 14.
    @_lifetime(reader: copy reader)
    static func readCode(_ reader: inout BitReader) -> Int {
        for level in 0..<6 {
            let value = Int(reader.read(2))
            if value < 3 { return 3 * level + value }
        }
        return 18 + Int(reader.read(2))
    }

    /// The index into the 1000-entry codebook a silent block starts reading at.
    ///
    /// This is FFmpeg's `pRNG`, which computes `x * 49995 / ((x % 9) * 5 + 6)` in 16 bits through a
    /// table of reciprocals.
    static func codebookStart(frame: Int, block: Int, size: Int) -> Int {
        let reciprocals: [(UInt32, UInt32)] = [
            (8332, 3 * 715_827_883), (4545, 0), (3124, 11 * 268_435_456),
            (2380, 15 * 204_522_253), (1922, 23 * 165_191_050), (1612, 23 * 138_547_333),
            (1388, 27 * 119_304_648), (1219, 16 * 104_755_300), (1086, 39 * 93_368_855),
        ]
        var x = UInt32(truncatingIfNeeded: block * 1877 + frame)
        if x >= 0xFFFF { x -= 0xFFFF }
        let ninth = UInt32(truncatingIfNeeded: (Int64(477_218_589) * Int64(x)) >> 32)
        let y = Int(x &- 9 &* ninth)
        let high = UInt32(truncatingIfNeeded: (UInt64(x) * UInt64(reciprocals[y].1)) >> 32)
        let z = UInt16(truncatingIfNeeded: x &* reciprocals[y].0 &+ high)
        return Int(z) % (1000 - size)
    }
}
