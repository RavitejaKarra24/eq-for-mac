import Foundation

/// Parses Equalizer APO / AutoEQ / PEQdB-export style filter text.
///
/// Example:
/// ```
/// Preamp: -6.3 dB
/// Filter 1: ON LSC Fc 105 Hz Gain 6.3 dB Q 0.70
/// Filter 2: ON PK Fc 169 Hz Gain -2.1 dB Q 0.77
/// ```
enum EqualizerAPOParser {
    struct Parsed {
        var preampDB: Float
        var bands: [EQBand]
    }

    static func parse(text: String) -> Parsed? {
        var preamp: Float = 0
        var bands: [EQBand] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.lowercased().hasPrefix("preamp") {
                if let value = firstNumber(in: line) {
                    preamp = value
                }
                continue
            }

            // Filter N: ON TYPE Fc F Hz Gain G dB Q Q
            guard line.lowercased().hasPrefix("filter") else { continue }

            let tokens = tokenize(line)
            guard tokens.count >= 3 else { continue }

            // Find ON/OFF
            var enabled = true
            var typeToken: String?
            var frequency: Float?
            var gain: Float = 0
            var q: Float = 1.0

            var i = 0
            while i < tokens.count {
                let t = tokens[i]
                let upper = t.uppercased()

                if upper == "ON" {
                    enabled = true
                } else if upper == "OFF" {
                    enabled = false
                } else if ["PK", "PEQ", "EQ", "LS", "LSC", "LSH", "HS", "HSC", "HSH",
                           "LP", "LPQ", "HP", "HPQ", "BP", "NO", "NOTCH", "IIR"].contains(upper) {
                    typeToken = upper
                } else if upper == "FC" || upper == "F" {
                    if i + 1 < tokens.count, let v = Float(tokens[i + 1]) {
                        frequency = v
                        i += 1
                    }
                } else if upper == "GAIN" || upper == "G" {
                    if i + 1 < tokens.count, let v = Float(tokens[i + 1]) {
                        gain = v
                        i += 1
                    }
                } else if upper == "Q" || upper == "BW" {
                    if i + 1 < tokens.count, let v = Float(tokens[i + 1]) {
                        q = v
                        i += 1
                    }
                }
                i += 1
            }

            guard let freq = frequency, let typeTok = typeToken else { continue }

            let filterType = EQFilterType.fromAPO(typeTok)
            let bandwidth: Float
            if typeTok == "BW" {
                bandwidth = max(0.05, min(5, q))
            } else {
                bandwidth = EQBand.bandwidthFromQ(q)
            }

            bands.append(
                EQBand(
                    filterType: filterType,
                    frequency: max(20, min(20000, freq)),
                    gain: max(-24, min(24, gain)),
                    bandwidth: bandwidth,
                    enabled: enabled
                )
            )
        }

        guard !bands.isEmpty || abs(preamp) > 0.001 else { return nil }
        return Parsed(preampDB: preamp, bands: bands)
    }

    static func parseFile(at url: URL) throws -> Parsed {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let parsed = parse(text: text) else {
            throw AudioError.message("Could not parse EQ filters from \(url.lastPathComponent)")
        }
        return parsed
    }

    private static func tokenize(_ line: String) -> [String] {
        // Split on whitespace and strip trailing punctuation like "Hz," "dB,"
        line
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespaces)
            .map { token in
                var t = token
                for suffix in ["Hz", "dB", "db", "hz"] where t.hasSuffix(suffix) && t.count > suffix.count {
                    t = String(t.dropLast(suffix.count))
                }
                return t
            }
            .filter { !$0.isEmpty && $0 != ":" }
    }

    private static func firstNumber(in line: String) -> Float? {
        let pattern = #"-?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range, in: line)
        else { return nil }
        return Float(line[swiftRange])
    }
}
