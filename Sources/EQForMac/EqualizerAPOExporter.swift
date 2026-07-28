import Foundation

enum EqualizerAPOExporter {
    static func export(_ preset: EQPreset) -> String {
        var lines = [String(format: "Preamp: %.2f dB", preset.preampDB)]
        var filterNumber = 1
        for band in preset.bands where band.enabled {
            let type = token(for: band.filterType)
            let q = qFactor(forBandwidth: band.bandwidth)
            switch band.filterType {
            case .parametric, .lowShelf, .highShelf:
                lines.append(
                    String(
                        format: "Filter %d: ON %@ Fc %.2f Hz Gain %.2f dB Q %.4f",
                        filterNumber,
                        type,
                        band.frequency,
                        band.gain,
                        q
                    )
                )
            case .lowPass, .highPass, .bandPass, .notch:
                lines.append(
                    String(
                        format: "Filter %d: ON %@ Fc %.2f Hz Q %.4f",
                        filterNumber,
                        type,
                        band.frequency,
                        q
                    )
                )
            }
            filterNumber += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func token(for type: EQFilterType) -> String {
        switch type {
        case .parametric: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LPQ"
        case .highPass: return "HPQ"
        case .bandPass: return "BP"
        case .notch: return "NO"
        }
    }

    private static func qFactor(forBandwidth bandwidth: Float) -> Float {
        let positiveBandwidth = max(0.000_001, abs(bandwidth))
        return 1 / (2 * sinh(log(2) * positiveBandwidth * 0.5))
    }
}
