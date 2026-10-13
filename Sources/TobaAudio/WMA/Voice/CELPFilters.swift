internal import Foundation

/// The CELP and ACELP routines WMA Voice synthesizes through, ported from FFmpeg.
///
/// A filter reads the samples in front of its first output, so each routine takes a flat array and
/// the index its run starts at rather than a slice.
enum CELPFilters {
    /// The sum of the products of `count` pairs, accumulated in single precision.
    static func dot(
        _ a: [Float],
        _ aStart: Int,
        _ b: [Float],
        _ bStart: Int,
        _ count: Int
    ) -> Float {
        var sum: Float = 0
        for i in 0..<count { sum += a[aStart + i] * b[bStart + i] }
        return sum
    }

    /// Runs the all-pole LPC synthesis filter, which reads `order` outputs in front of `start`.
    ///
    /// This follows FFmpeg's unrolled `ff_celp_lp_synthesis_filterf` four samples at a time, so the
    /// float sums run in the order FFmpeg's own output does. `order` is even and at least four.
    static func synthesize(
        _ output: inout [Float],
        at start: Int,
        coefficients: [Float],
        input: [Float],
        from inputStart: Int,
        count: Int,
        order: Int
    ) {
        let a = coefficients[0]
        var b = coefficients[1]
        var c = coefficients[2]
        b -= coefficients[0] * coefficients[0]
        c -= coefficients[1] * coefficients[0]
        c -= coefficients[0] * b

        var old0 = output[start - 4]
        var old1 = output[start - 3]
        var old2 = output[start - 2]
        var old3 = output[start - 1]
        var n = 0

        while n <= count - 4 {
            let at = start + n
            let from = inputStart + n
            var out0 = input[from]
            var out1 = input[from + 1]
            var out2 = input[from + 2]
            var out3 = input[from + 3]

            out0 -= coefficients[2] * old1
            out1 -= coefficients[2] * old2
            out2 -= coefficients[2] * old3

            out0 -= coefficients[1] * old2
            out1 -= coefficients[1] * old3

            out0 -= coefficients[0] * old3

            var value = coefficients[3]
            out0 -= value * old0
            out1 -= value * old1
            out2 -= value * old2
            out3 -= value * old3

            var i = 5

            while i < order {
                old3 = output[at - i]
                value = coefficients[i - 1]
                out0 -= value * old3
                out1 -= value * old0
                out2 -= value * old1
                out3 -= value * old2

                old2 = output[at - i - 1]
                value = coefficients[i]
                out0 -= value * old2
                out1 -= value * old3
                out2 -= value * old0
                out3 -= value * old1

                swap(&old0, &old2)
                old1 = old3
                i += 2
            }

            let (held0, held1, held2) = (out0, out1, out2)
            out3 -= a * held2
            out2 -= a * held1
            out1 -= a * held0

            out3 -= b * held1
            out2 -= b * held0

            out3 -= c * held0

            output[at] = out0
            output[at + 1] = out1
            output[at + 2] = out2
            output[at + 3] = out3
            (old0, old1, old2, old3) = (out0, out1, out2, out3)
            n += 4
        }

        while n < count {
            var value = input[inputStart + n]
            for i in 1...order { value -= coefficients[i - 1] * output[start + n - i] }
            output[start + n] = value
            n += 1
        }
    }

    /// Runs the all-zero filter that turns speech back into its excitation.
    static func excite(
        _ output: inout [Float],
        at start: Int,
        coefficients: [Float],
        input: [Float],
        from inputStart: Int,
        count: Int,
        order: Int
    ) {
        for n in 0..<count {
            var value = input[inputStart + n]
            for i in 1...order { value += coefficients[i - 1] * input[inputStart + n - i] }
            output[start + n] = value
        }
    }

    /// Interpolates a signal at a fractional delay, writing into the same array it reads.
    ///
    /// - Parameters:
    ///   - phase: the fractional position, between one and `precision - 1`
    ///   - taps: half the filter's length
    static func interpolate(
        _ signal: inout [Float],
        into start: Int,
        from source: Int,
        filter: [Float],
        precision: Int,
        phase: Int,
        taps: Int,
        count: Int
    ) {
        for n in 0..<count {
            var index = 0
            var value: Float = 0
            var i = 0

            while i < taps {
                value += signal[source + n + i] * filter[index + phase]
                index += precision
                i += 1
                value += signal[source + n - i] * filter[index - phase]
            }
            signal[start + n] = value
        }
    }

    /// Runs a second order pole-zero filter over `count` samples in place.
    static func secondOrder(
        _ samples: inout [Float],
        at start: Int,
        zeros: (Float, Float),
        poles: (Float, Float),
        gain: Float,
        memory: inout (Float, Float),
        count: Int
    ) {
        for i in 0..<count {
            let value = gain * samples[start + i] - poles.0 * memory.0 - poles.1 * memory.1
            samples[start + i] = value + zeros.0 * memory.0 + zeros.1 * memory.1
            memory.1 = memory.0
            memory.0 = value
        }
    }

    /// Subtracts `tilt` times each sample's predecessor, the first reading `memory`.
    static func compensateTilt(
        _ samples: inout [Float],
        at start: Int,
        tilt: Float,
        memory: inout Float,
        count: Int
    ) {
        let last = samples[start + count - 1]
        var i = count - 1

        while i > 0 {
            samples[start + i] -= tilt * samples[start + i - 1]
            i -= 1
        }
        samples[start] -= tilt * memory
        memory = last
    }

    // MARK: - Line spectral pairs

    /// Converts `2 * halfOrder` line spectral pairs in the cosine domain to LPC coefficients.
    static func lpc(fromLSP lsp: [Double], halfOrder: Int, into lpc: inout [Float]) {
        let even = polynomial(lsp, from: 0, halfOrder: halfOrder)
        let odd = polynomial(lsp, from: 1, halfOrder: halfOrder)
        var index = halfOrder

        while index > 0 {
            index -= 1
            let sum = even[index + 1] + even[index]
            let difference = odd[index + 1] - odd[index]
            lpc[index] = Float(0.5 * (sum + difference))
            lpc[2 * halfOrder - 1 - index] = Float(0.5 * (sum - difference))
        }
    }

    /// The polynomial every second pair from `first` spans, FFmpeg's `lsp2polyf`.
    ///
    /// - Parameter halfOrder: eight at the most
    private static func polynomial(
        _ lsp: [Double],
        from first: Int,
        halfOrder: Int
    ) -> InlineArray<9, Double> {
        var f = InlineArray<9, Double>(repeating: 0)
        f[0] = 1
        f[1] = -2 * lsp[first]

        if halfOrder >= 2 {
            for i in 2...halfOrder {
                let value = -2 * lsp[first + 2 * i - 2]
                f[i] = value * f[i - 1] + 2 * f[i - 2]
                var j = i - 1

                while j > 1 {
                    f[j] += f[j - 1] * value + f[j - 2]
                    j -= 1
                }
                f[1] += value
            }
        }
        return f
    }
}

/// The fixed codebook pulses of one block, FFmpeg's `AMRFixed`, which holds ten at the most.
struct FixedPulses {
    private(set) var positions = InlineArray<10, Int>(repeating: 0)
    private(set) var signs = InlineArray<10, Float>(repeating: 0)
    private(set) var pulseCount = 0

    /// One bit per pulse that is placed once rather than repeated at every pitch lag.
    var noRepeatMask = 0

    var pitchLag = 0

    mutating func add(_ position: Int, _ sign: Float) {
        positions[pulseCount] = position
        signs[pulseCount] = sign
        pulseCount += 1
    }

    /// Adds each pulse to `output`, repeating it every pitch lag unless its mask bit is set.
    func place(into output: inout [Float], count: Int) {
        guard pitchLag > 0 else { return }

        for i in 0..<pulseCount {
            let repeats = (noRepeatMask >> i) & 1 == 0
            var x = positions[i]

            repeat {
                guard x >= 0, x < count else { break }
                output[x] += signs[i]
                x += pitchLag
            } while x < count && repeats
        }
    }
}
