import Foundation

/// Calculates clip headroom from the exact coefficients used by the renderer.
enum EQHeadroomCalculator {
    static func recommendedPreamp(
        for bands: [EQBand],
        safetyMarginDB: Float = 0.25,
        sampleRate: Double = 48_000
    ) -> Float {
        let boost = maximumBoost(for: bands, sampleRate: sampleRate)
        guard boost > 0.01 else { return 0 }
        // Half-dB steps match the UI and round away from clipping.
        let attenuation = ceil((boost + max(0, safetyMarginDB)) * 2) / 2
        return max(-24, -attenuation)
    }

    static func maximumBoost(
        for bands: [EQBand],
        sampleRate: Double = 48_000
    ) -> Float {
        let enabled = bands.filter(\.enabled)
        guard !enabled.isEmpty else { return 0 }

        var maximum: Float = 0
        let upperBound = min(20_000, sampleRate * 0.499)
        for frequency in EQResponse.logarithmicFrequencies(
            count: 4_096,
            upperBound: upperBound
        ) {
            maximum = max(
                maximum,
                EQResponse.magnitudeDB(
                    bands: enabled,
                    at: Double(frequency),
                    sampleRate: sampleRate
                )
            )
        }
        return max(0, maximum)
    }
}
