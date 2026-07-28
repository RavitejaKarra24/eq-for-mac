import Foundation

/// Normalized, direct-form-I coefficients for one RBJ biquad.
struct BiquadCoefficients: Equatable, Sendable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

/// The single source of truth for both rendered filters and displayed response.
///
/// Coefficients follow Robert Bristow-Johnson's Audio EQ Cookbook. Bandwidth is
/// expressed in octaves throughout the app and is intentionally not clamped, so
/// high-Q imported filters retain their authored shape.
enum EQResponse {
    static let minimumFrequency: Double = 10

    static func coefficients(
        for band: EQBand,
        sampleRate: Double
    ) -> BiquadCoefficients {
        guard band.enabled, sampleRate > 0 else { return .identity }

        let nyquist = sampleRate * 0.5
        let frequency = min(max(minimumFrequency, Double(band.frequency)), nyquist * 0.999)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let amplitude = pow(10, Double(band.gain) / 40)
        let q = qFactor(forBandwidth: Double(band.bandwidth))
        let alpha = sine / (2 * q)

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
        switch band.filterType {
        case .parametric:
            raw = (
                1 + alpha * amplitude,
                -2 * cosine,
                1 - alpha * amplitude,
                1 + alpha / amplitude,
                -2 * cosine,
                1 - alpha / amplitude
            )

        case .lowShelf:
            let shelfAlpha = sine / (2 * q)
            let rootA = sqrt(amplitude)
            let twoRootAAlpha = 2 * rootA * shelfAlpha
            raw = (
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + twoRootAAlpha),
                2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - twoRootAAlpha),
                (amplitude + 1) + (amplitude - 1) * cosine + twoRootAAlpha,
                -2 * ((amplitude - 1) + (amplitude + 1) * cosine),
                (amplitude + 1) + (amplitude - 1) * cosine - twoRootAAlpha
            )

        case .highShelf:
            let shelfAlpha = sine / (2 * q)
            let rootA = sqrt(amplitude)
            let twoRootAAlpha = 2 * rootA * shelfAlpha
            raw = (
                amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + twoRootAAlpha),
                -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - twoRootAAlpha),
                (amplitude + 1) - (amplitude - 1) * cosine + twoRootAAlpha,
                2 * ((amplitude - 1) - (amplitude + 1) * cosine),
                (amplitude + 1) - (amplitude - 1) * cosine - twoRootAAlpha
            )

        case .lowPass:
            raw = (
                (1 - cosine) * 0.5,
                1 - cosine,
                (1 - cosine) * 0.5,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )

        case .highPass:
            raw = (
                (1 + cosine) * 0.5,
                -(1 + cosine),
                (1 + cosine) * 0.5,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )

        case .bandPass:
            raw = (
                alpha,
                0,
                -alpha,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )

        case .notch:
            raw = (
                1,
                -2 * cosine,
                1,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )
        }

        guard raw.a0.isFinite, abs(raw.a0) > .ulpOfOne else { return .identity }
        return BiquadCoefficients(
            b0: raw.b0 / raw.a0,
            b1: raw.b1 / raw.a0,
            b2: raw.b2 / raw.a0,
            a1: raw.a1 / raw.a0,
            a2: raw.a2 / raw.a0
        )
    }

    static func magnitudeDB(
        bands: [EQBand],
        at frequency: Double,
        sampleRate: Double = 48_000
    ) -> Float {
        guard sampleRate > 0 else { return 0 }
        let clampedFrequency = min(max(minimumFrequency, frequency), sampleRate * 0.499)
        let omega = 2 * Double.pi * clampedFrequency / sampleRate
        var logMagnitude = 0.0

        for band in bands where band.enabled {
            let coefficient = coefficients(for: band, sampleRate: sampleRate)
            let numerator = complexMagnitude(
                c0: coefficient.b0,
                c1: coefficient.b1,
                c2: coefficient.b2,
                omega: omega
            )
            let denominator = complexMagnitude(
                c0: 1,
                c1: coefficient.a1,
                c2: coefficient.a2,
                omega: omega
            )
            guard numerator > 0, denominator > 0 else { continue }
            logMagnitude += log(numerator / denominator)
        }

        let decibels = 20 * logMagnitude / log(10)
        return Float(decibels.isFinite ? decibels : 0)
    }

    static func logarithmicFrequencies(
        count: Int,
        lowerBound: Double = 20,
        upperBound: Double = 20_000
    ) -> [Float] {
        guard count > 1 else { return [Float(lowerBound)] }
        let lower = log(max(minimumFrequency, lowerBound))
        let upper = log(max(lowerBound, upperBound))
        return (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            return Float(exp(lower + fraction * (upper - lower)))
        }
    }

    private static func qFactor(forBandwidth bandwidth: Double) -> Double {
        let positiveBandwidth = max(0.000_001, abs(bandwidth))
        let denominator = 2 * sinh(log(2) * positiveBandwidth * 0.5)
        return max(0.000_001, 1 / denominator)
    }

    private static func complexMagnitude(
        c0: Double,
        c1: Double,
        c2: Double,
        omega: Double
    ) -> Double {
        let real = c0 + c1 * cos(omega) + c2 * cos(2 * omega)
        let imaginary = -c1 * sin(omega) - c2 * sin(2 * omega)
        return hypot(real, imaginary)
    }
}
