internal import Foundation

/// The real transforms the WMA Voice postfilter runs, computed the way FFmpeg's `libavutil/tx`
/// does.
///
/// The postfilter's reference output depends on the exact layout and scale of each transform,
/// including where a half-complex result leaves a raw value behind. Each transform here therefore
/// follows FFmpeg's own steps over one shared buffer rather than a textbook formula.
struct WMAVoiceTransform {
    /// How many real samples the transform takes or answers.
    let length: Int

    private let factors: [Float]
    private let cosines: [Float]
    private let sines: [Float]
    private let dft: WMAVoiceDFT

    /// Builds the factor table FFmpeg's `ff_tx_rdft_init` writes.
    ///
    /// - Parameter realOnly: whether a forward half-complex transform answers real parts, which
    ///   takes the one factor that holds the inverse scale
    init(length: Int, inverse: Bool, scale: Float, realOnly: Bool = false) {
        self.length = length
        let m = Double(inverse ? 2 * scale : scale)
        let sign = inverse ? 1.0 : 0.0
        factors = [
            Float((inverse ? 0.5 : 1.0) * m),
            Float(inverse ? 0.5 * m : 1.0 * m),
            Float(m),
            Float(-m),
            Float(0.5 * m),
            realOnly ? 1 / scale : Float(-0.5 * m),
            Float((0.5 - sign) * m),
            Float(-(0.5 - sign) * m),
        ]
        let quarter = (length + 3) / 4
        let step = 2 * Double.pi / Double(length)
        cosines = (0..<quarter).map { Float(cos(Double($0) * step)) }
        sines = (0..<quarter).map { index in
            Float(cos(Double(length - index * 4) / 4 * step)) * (inverse ? 1 : -1)
        }
        dft = WMAVoiceDFT(count: length / 2)
    }

    // MARK: - Real to complex and back

    /// The forward transform of the `length` real samples at `start`, as `length / 2 + 1`
    /// interleaved complex values.
    func forward(_ input: [Float], from start: Int = 0, into data: inout [Float]) {
        let half = length / 2
        if data.count < length + 2 { data = [Float](repeating: 0, count: length + 2) }
        dft.transform(input, from: start, inverse: false, into: &data)
        data[2 * half] = 0
        data[2 * half + 1] = 0
        fold(&data)
        data[2 * half] = data[1]
        data[1] = 0
        data[2 * half + 1] = 0
    }

    /// The inverse transform of `length / 2 + 1` interleaved complex values, as `length` real
    /// samples.
    ///
    /// The transform folds `data` in place, and the imaginary parts of the first and the last value
    /// never reach the answer.
    func inverse(_ data: inout [Float], into output: inout [Float]) {
        data[1] = data[2 * (length / 2)]
        fold(&data)
        dft.transform(data, inverse: true, into: &output)
    }

    /// The split step between the half-length complex transform and the real one.
    private func fold(_ data: inout [Float]) {
        let half = length / 2
        let quarter = length / 4
        let first = data[0]
        data[0] = first + data[1]
        data[1] = first - data[1]
        data[0] = factors[0] * data[0]
        data[1] = factors[1] * data[1]
        data[2 * quarter] = factors[2] * data[2 * quarter]
        data[2 * quarter + 1] = factors[3] * data[2 * quarter + 1]

        for i in 1..<quarter {
            let low = 2 * i
            let high = 2 * (half - i)
            let evenReal = factors[4] * (data[low] + data[high])
            let evenImaginary = factors[5] * (data[low + 1] - data[high + 1])
            let oddReal = factors[6] * (data[low + 1] + data[high + 1])
            let oddImaginary = factors[7] * (data[low] - data[high])
            let twistedReal = oddReal * cosines[i] - oddImaginary * sines[i]
            let twistedImaginary = oddReal * sines[i] + oddImaginary * cosines[i]

            data[low] = evenReal + twistedReal
            data[low + 1] = twistedImaginary - evenImaginary
            data[high] = evenReal - twistedReal
            data[high + 1] = twistedImaginary + evenImaginary
        }
    }

    // MARK: - Half complex

    /// The forward transform that keeps only the real parts, or only the imaginary parts.
    ///
    /// The answer holds `length` values. A caller reads the first `length / 2 + 1`, and the one
    /// slot the layout never fills keeps a raw value of the complex transform under it.
    func half(_ input: [Float], realParts: Bool, into out: inout [Float]) {
        let half = length / 2
        let quarter = length / 4
        let unaligned = length % 4 != 0
        dft.transform(input, inverse: false, into: &out)

        var dc = out[0]
        out[0] = dc + out[1]
        dc -= out[1]
        out[0] = factors[0] * out[0]
        dc = factors[1] * dc
        out[2 * quarter] = factors[2] * out[2 * quarter]
        var middle: Float = 0

        if !unaligned {
            out[2 * quarter + 1] = factors[3] * out[2 * quarter + 1]
        } else {
            middle = self.middle(out, realParts: realParts)
        }

        for i in 1...quarter {
            let low = 2 * i
            let high = 2 * (half - i)
            let even = realParts
                ? factors[4] * (out[low] + out[high])
                : factors[5] * (out[low + 1] - out[high + 1])
            let oddReal = factors[6] * (out[low + 1] + out[high + 1])
            let oddImaginary = factors[7] * (out[low] - out[high])

            if realParts {
                let twisted = oddReal * cosines[i] - oddImaginary * sines[i]
                out[i] = even + twisted
                out[length - i] = even - twisted
            } else {
                let twisted = oddReal * sines[i] + oddImaginary * cosines[i]
                out[i - 1] = twisted - even
                out[length - i - 1] = even + twisted
            }
        }
        for i in 1..<(quarter + (realParts ? 0 : 1)) { out[half - i] = out[length - i] }

        if realParts {
            out[half] = dc
            if unaligned { out[quarter + 1] = middle * factors[5] }
        } else if unaligned { out[quarter] = middle }
    }

    /// The middle value a length that is not a multiple of four computes apart from the loop.
    private func middle(_ data: [Float], realParts: Bool) -> Float {
        let quarter = length / 4
        let (fr, fi) = (data[2 * quarter], data[2 * quarter + 1])
        let (sr, si) = (data[2 * quarter + 2], data[2 * quarter + 3])
        let even = realParts ? factors[4] * (fr + sr) : factors[5] * (fi - si)
        let oddReal = factors[6] * (fi + si)
        let oddImaginary = factors[7] * (fr - sr)

        return realParts
            ? even - (oddReal * cosines[quarter] - oddImaginary * sines[quarter])
            : even + (oddReal * sines[quarter] + oddImaginary * cosines[quarter])
    }
}

// MARK: - The discrete cosine and sine transforms

/// The type I cosine and sine transforms of FFmpeg's `libavutil/tx`, over `count` samples.
struct WMAVoiceDCST {
    let count: Int
    private let cosine: WMAVoiceTransform
    private let sine: WMAVoiceTransform

    init(count: Int, scale: Float) {
        self.count = count
        cosine = WMAVoiceTransform(
            length: (count - 1) * 2, inverse: false, scale: scale,
            realOnly: true)
        sine = WMAVoiceTransform(length: (count + 1) * 2, inverse: false, scale: scale)
    }

    /// The DCT-I of the first `count` values, mirrored around the last one into `mirrored`.
    func cosineTransform(_ input: [Float], into output: inout [Float], mirrored: inout [Float]) {
        let last = count - 1
        if mirrored.count < 2 * last + 1 { mirrored = [Float](repeating: 0, count: 2 * last + 1) }

        for i in 0..<last {
            mirrored[i] = input[i]
            mirrored[2 * last - i] = input[i]
        }
        mirrored[last] = input[last]
        cosine.half(mirrored, realParts: true, into: &output)
    }

    /// The DST-I of the first `count` values, mirrored with the sign turned into `mirrored`.
    func sineTransform(_ input: [Float], into output: inout [Float], mirrored: inout [Float]) {
        let span = count + 1
        if mirrored.count < 2 * span { mirrored = [Float](repeating: 0, count: 2 * span) }
        mirrored[0] = 0
        mirrored[span] = 0

        for i in 1..<span {
            mirrored[i] = -input[i - 1]
            mirrored[2 * span - i] = input[i - 1]
        }
        sine.half(mirrored, realParts: false, into: &output)
    }
}

// MARK: - The complex transform

/// An unnormalized complex DFT over interleaved values, forward with a negative exponent.
///
/// The lengths the postfilter takes are short and odd lengths among them have no Accelerate setup,
/// so this sums directly over a table of `count` roots, in double precision.
struct WMAVoiceDFT {
    let count: Int
    private let cosines: [Double]
    private let sines: [Double]

    init(count: Int) {
        self.count = count
        let step = 2 * Double.pi / Double(count)
        cosines = (0..<count).map { cos(Double($0) * step) }
        sines = (0..<count).map { sin(Double($0) * step) }
    }

    /// Transforms the `count` interleaved complex values at `start` into the front of `output`.
    func transform(
        _ input: [Float],
        from start: Int = 0,
        inverse: Bool,
        into output: inout [Float]
    ) {
        if output.count < 2 * count { output = [Float](repeating: 0, count: 2 * count) }
        let sign: Double = inverse ? 1 : -1

        for k in 0..<count {
            var real = 0.0
            var imaginary = 0.0

            // the root index runs as `(k * n) % count` without a division per term
            var root = 0

            for n in 0..<count {
                let c = cosines[root]
                let s = sign * sines[root]
                let a = Double(input[start + 2 * n])
                let b = Double(input[start + 2 * n + 1])
                real += a * c - b * s
                imaginary += a * s + b * c
                root += k
                if root >= count { root -= count }
            }
            output[2 * k] = Float(real)
            output[2 * k + 1] = Float(imaginary)
        }
    }
}
