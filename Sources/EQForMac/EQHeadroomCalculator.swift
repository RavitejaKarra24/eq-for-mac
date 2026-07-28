import Foundation

/// Estimates the peak positive response of a set of EQ filters.
///
/// AVAudioUnitEQ does not expose its combined response, so this calculator uses
/// the same useful parameters (frequency, octave bandwidth, type and gain) over
/// a dense logarithmic grid. The result is deliberately conservative: it never
/// recommends less attenuation than the largest individual boost.
enum EQHeadroomCalculator {
    private static let halfPowerConstant: Float = 0.693_147_2

    static func recommendedPreamp(
        for bands: [EQBand],
        safetyMarginDB: Float = 0.25
    ) -> Float {
        let boost = maximumBoost(for: bands)
        guard boost > 0.01 else { return 0 }
        // Half-dB steps match the UI and round away from clipping.
        let attenuation = ceil((boost + max(0, safetyMarginDB)) * 2) / 2
        return max(-24, -attenuation)
    }

    static func maximumBoost(for bands: [EQBand]) -> Float {
        let enabled = bands.filter(\.enabled)
        guard !enabled.isEmpty else { return 0 }

        let largestBandBoost = enabled.map(\.gain).max() ?? 0
        var maximum: Float = 0

        // 384 points provide sub-1/40-octave resolution across the audible band.
        for sample in 0..<384 {
            let fraction = Double(sample) / 383
            let frequency = Float(
                exp(log(20.0) + fraction * (log(20_000.0) - log(20.0)))
            )
            let response = enabled.reduce(Float(0)) { partial, band in
                partial + contribution(of: band, at: frequency)
            }
            maximum = max(maximum, response)
        }

        return max(0, max(largestBandBoost, maximum))
    }

    private static func contribution(of band: EQBand, at frequency: Float) -> Float {
        let center = max(20, min(20_000, band.frequency))
        let octaveDistance = log2(max(20, frequency) / center)
        let bandwidth = max(0.05, min(5, band.bandwidth))

        switch band.filterType {
        case .parametric:
            // Treat bandwidth as full width at half maximum.
            let normalized = octaveDistance / (bandwidth * 0.5)
            let weight = exp(-halfPowerConstant * normalized * normalized)
            return band.gain * weight

        case .lowShelf:
            let weight = 1 / (1 + exp(6 * octaveDistance / bandwidth))
            return band.gain * weight

        case .highShelf:
            let weight = 1 / (1 + exp(-6 * octaveDistance / bandwidth))
            return band.gain * weight

        case .bandPass:
            // Band-pass filters normally attenuate outside the pass band. Only
            // model an explicit positive gain, conservatively, around center.
            guard band.gain > 0 else { return 0 }
            let normalized = octaveDistance / (bandwidth * 0.5)
            return band.gain * exp(-halfPowerConstant * normalized * normalized)

        case .lowPass, .highPass, .notch:
            // These filters cannot add headroom pressure without a positive
            // gain parameter. AVAudioUnitEQ treats their gain as non-boosting.
            return max(0, band.gain)
        }
    }
}
