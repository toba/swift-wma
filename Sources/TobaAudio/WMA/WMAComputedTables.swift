internal import Foundation

/// The tables a decode derives rather than transcribes.
///
/// Each one follows a rule the format states, so writing the rule is both shorter and safer than
/// copying the values it produces.
extension WMATables {
    /// How many entries the exponent scale table holds.
    static let powerCount = 156

    /// Where the scale table's own zero exponent sits.
    static let powerBias = 60

    /// The scale an exponent stands for, which steps by a sixteenth of a decade.
    ///
    /// An exponent reaches this at `exponent + powerBias`, so the stored exponent runs from minus
    /// sixty upward.
    static let powers: [Float] = (0..<powerCount).map {
        Float(pow(10, Double($0 - powerBias) / 16))
    }

    /// How many values the noise table holds. It wraps, so a decode never runs out.
    static let noiseCount = 8192

    /// The noise a stream substitutes for a high band it did not code.
    ///
    /// The values come from a fixed generator rather than a random one, so two devices decoding the
    /// same file substitute the same noise.
    ///
    /// - Parameter multiplier: the amplitude the stream's own options set
    static func noise(multiplier: Float) -> [Float] {
        let norm = Float(1.0 / Double(1 << 31) * 3.0.squareRoot()) * multiplier
        var seed: UInt32 = 1

        return (0..<noiseCount).map { _ in
            seed = seed &* 314_159 &+ 1
            return Float(Int32(bitPattern: seed)) * norm
        }
    }

    /// The run each coefficient code names, and the level beside it.
    ///
    /// A table walks its levels in turn. Level one covers the first run of codes, level two the
    /// next, and so on, with the level table naming how many codes each level takes. Codes zero and
    /// one are the escape and the end of block, so the walk starts behind them.
    ///
    /// - Parameters:
    ///   - levels: how many codes each level carries
    ///   - count: how many codes the table holds
    static func runsAndLevels(levels: [UInt16], count: Int) -> (runs: [Int], levels: [Int]) {
        var runs = [Int](repeating: 0, count: count)
        var values = [Int](repeating: 0, count: count)
        var index = 2
        var level = 1
        var step = 0

        while index < count, step < levels.count {
            let span = Int(levels[step])
            step += 1

            for run in 0..<span where index < count {
                runs[index] = run
                values[index] = level
                index += 1
            }
            level += 1
        }
        return (runs, values)
    }
}
