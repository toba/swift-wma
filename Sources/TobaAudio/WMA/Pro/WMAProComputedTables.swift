internal import Foundation

/// The WMA Pro tables a rule produces, so none is transcribed.
enum WMAProComputedTables {
    /// `sin(i * pi / 64)` for `i` from 0 to 32, which a sent decorrelation matrix rotates by.
    static let sine64: [Float] = (0...32).map { Float(sin(Double($0) * Double.pi / 64)) }

    /// `10 ** (exponent / 20)`, the step a quantizer exponent in decibels stands for.
    ///
    /// FFmpeg's `ff_exp10` runs through `exp2`, so this does too, which keeps the last bit equal.
    static func decibelStep(_ exponent: Int) -> Float {
        Float(exp2(3.32192809488736234787 * (Double(exponent) / 20.0)))
    }
}
