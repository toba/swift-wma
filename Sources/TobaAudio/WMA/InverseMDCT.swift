internal import Accelerate
internal import Foundation

/// The inverse modified discrete cosine transform a WMA block reconstructs through.
///
/// A transform of `count` coefficients answers `2 * count` samples. Consecutive blocks overlap by
/// half, so a caller windows the answer and adds it to the tail the block before it left.
///
/// The transform runs as a DCT-IV of the same length, which the two transforms' shared symmetry
/// extends over the full window.
///
/// A stream builds one of these per block size and keeps it for its whole life, which is why this
/// is a reference rather than a value.
@safe
final class InverseMDCT {
    /// How many coefficients one block carries.
    let count: Int

    private let setup: vDSP_DFT_Setup

    /// The half transform, which the fold below extends to the full window.
    private var folded: [Float]

    /// - Parameter count: a power of two, sixteen or larger, which is what the DCT setup accepts
    init?(count: Int) {
        guard count >= 16, count.nonzeroBitCount == 1 else { return nil }
        guard let built = unsafe vDSP_DCT_CreateSetup(nil, vDSP_Length(count), .IV) else {
            return nil
        }
        self.count = count
        unsafe setup = built
        folded = [Float](repeating: 0, count: count)
    }

    deinit { unsafe vDSP_DFT_DestroySetup(setup) }

    /// Transforms `coefficients` into `samples`.
    ///
    /// - Parameters:
    ///   - coefficients: at least ``count`` values past `offset`
    ///   - offset: where the run to transform starts, which lets one array hold every channel
    ///   - samples: at least `2 * count` values, of which it overwrites the first
    func transform(_ coefficients: [Float], from offset: Int = 0, into samples: inout [Float]) {
        guard offset >= 0, coefficients.count >= offset + count, samples.count >= count * 2
        else { return }
        coefficients.withUnsafeBufferPointer { source in
            unsafe vDSP_DCT_Execute(setup, source.baseAddress! + offset, &folded)
        }
        fold(into: &samples)
    }

    /// Transforms `coefficients` into the `count` samples of FFmpeg's half inverse MDCT, scaled by
    /// `scale`, writing them into `samples` from `start` on.
    ///
    /// That half is the DCT-IV read backward, with no negation, which is what WMA Pro windows.
    func transformHalf(
        _ coefficients: [Float],
        scale: Float,
        into samples: inout [Float],
        at start: Int
    ) {
        let length = count
        guard coefficients.count >= length, start >= 0, samples.count >= start + length
        else { return }
        coefficients.withUnsafeBufferPointer { source in
            unsafe vDSP_DCT_Execute(setup, source.baseAddress!, &folded)
        }
        folded.withUnsafeBufferPointer { source in
            samples.withUnsafeMutableBufferPointer { target in
                for step in 0..<length {
                    unsafe target[start &+ step] = source[length &- 1 &- step] * scale
                }
            }
        }
    }

    /// Extends the half transform over the full window.
    ///
    /// A DCT-IV is even about the sample in front of its first and odd about the one behind its
    /// last. Reading it over those reflections is the whole transform, so the three runs below are
    /// one copy, one reversed negation and one negation.
    ///
    /// Accelerate's DCT-IV matches the definition term for term, so nothing here rescales it.
    private func fold(into samples: inout [Float]) {
        let half = count / 2

        folded.withUnsafeBufferPointer { source in
            samples.withUnsafeMutableBufferPointer { target in
                for step in 0..<half { unsafe target[step] = source[half &+ step] }
                for step in 0..<count { unsafe target[half &+ step] = -source[count &- 1 &- step] }
                for step in 0..<half { unsafe target[count &+ half &+ step] = -source[step] }
            }
        }
    }
}

/// The rising half of the sine window a WMA block folds with.
///
/// The window over `count` samples is `sin(pi * (n + 0.5) / (2 * count))`, which climbs from near
/// zero to near one. The falling half is the same values read backward, so only the rise is stored.
///
/// A block whose neighbour uses a different size folds that edge with the neighbour's window, which
/// is what keeps two overlapping blocks summing back to one.
enum SineWindow {
    static func make(count: Int) -> [Float] {
        let step = Double.pi / Double(count * 2)
        return (0..<count).map { Float(sin(step * (Double($0) + 0.5))) }
    }
}
