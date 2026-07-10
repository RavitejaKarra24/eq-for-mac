import AVFAudio
import Foundation

// MARK: - Filter types

enum EQFilterType: String, Codable, CaseIterable, Sendable {
    case parametric
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch

    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric: return .parametric
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        case .lowPass: return .lowPass
        case .highPass: return .highPass
        case .bandPass: return .bandPass
        case .notch: return .bandStop
        }
    }

    static func fromAPO(_ token: String) -> EQFilterType {
        switch token.uppercased() {
        case "PK", "PEQ", "EQ": return .parametric
        case "LS", "LSC", "LSH": return .lowShelf
        case "HS", "HSC", "HSH": return .highShelf
        case "LP", "LPQ": return .lowPass
        case "HP", "HPQ": return .highPass
        case "BP": return .bandPass
        case "NO", "NOTCH": return .notch
        default: return .parametric
        }
    }
}

// MARK: - Band

struct EQBand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var filterType: EQFilterType
    /// Center / corner frequency in Hz (20…20000)
    var frequency: Float
    /// Gain in dB (−24…+24)
    var gain: Float
    /// Bandwidth in octaves for AVAudioUnitEQ (≈ 1.0 → Q ≈ 1.41)
    var bandwidth: Float
    var enabled: Bool

    init(
        id: UUID = UUID(),
        filterType: EQFilterType = .parametric,
        frequency: Float,
        gain: Float = 0,
        bandwidth: Float = 1.0,
        enabled: Bool = true
    ) {
        self.id = id
        self.filterType = filterType
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.enabled = enabled
    }

    /// Convert Q factor to approximate octave bandwidth used by AVAudioUnitEQ.
    static func bandwidthFromQ(_ q: Float) -> Float {
        // BW (octaves) ≈ 2 / ln(2) * asinh(1/(2Q))  — common practical mapping
        let qClamped = max(0.05, q)
        let value = (2.0 / log(2.0)) * asinh(1.0 / (2.0 * Double(qClamped)))
        return Float(max(0.05, min(5.0, value)))
    }
}

// MARK: - Band modes

enum EQBandMode: String, CaseIterable, Codable, Sendable {
    case ten = "10-band"
    case fifteen = "15-band"
    case parametric = "Parametric"

    var bandCount: Int {
        switch self {
        case .ten: return 10
        case .fifteen: return 15
        case .parametric: return 10
        }
    }

    /// ISO-style center frequencies for graphic EQ modes.
    var frequencies: [Float] {
        switch self {
        case .ten:
            return [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        case .fifteen:
            return [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000]
        case .parametric:
            return [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        }
    }

    /// Default bandwidth for graphic bands (roughly one octave / 2/3 octave).
    var defaultBandwidth: Float {
        switch self {
        case .ten: return 1.0
        case .fifteen: return 0.67
        case .parametric: return 1.0
        }
    }
}

// MARK: - Preset

struct EQPreset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var preampDB: Float
    var bands: [EQBand]
    var bandMode: EQBandMode
    /// Built-in genre / utility presets
    var isBuiltIn: Bool
    /// Headphone correction from AutoEQ / PEQdB export
    var isHeadphone: Bool
    var source: String?

    init(
        id: UUID = UUID(),
        name: String,
        preampDB: Float = 0,
        bands: [EQBand],
        bandMode: EQBandMode = .ten,
        isBuiltIn: Bool = false,
        isHeadphone: Bool = false,
        source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
        self.bandMode = bandMode
        self.isBuiltIn = isBuiltIn
        self.isHeadphone = isHeadphone
        self.source = source
    }

    var isFlat: Bool {
        abs(preampDB) < 0.01 && bands.allSatisfy { abs($0.gain) < 0.01 || !$0.enabled }
    }

    static func flat(mode: EQBandMode = .ten) -> EQPreset {
        let bands = mode.frequencies.map {
            EQBand(frequency: $0, gain: 0, bandwidth: mode.defaultBandwidth)
        }
        return EQPreset(
            name: "Flat",
            preampDB: 0,
            bands: bands,
            bandMode: mode,
            isBuiltIn: true
        )
    }

    static func graphic(name: String, mode: EQBandMode, gains: [Float], preamp: Float = 0) -> EQPreset {
        let freqs = mode.frequencies
        precondition(gains.count == freqs.count)
        let bands = zip(freqs, gains).map { f, g in
            EQBand(frequency: f, gain: g, bandwidth: mode.defaultBandwidth)
        }
        return EQPreset(
            name: name,
            preampDB: preamp,
            bands: bands,
            bandMode: mode,
            isBuiltIn: true
        )
    }

    static let builtInPresets: [EQPreset] = {
        let m10 = EQBandMode.ten
        return [
            .flat(mode: m10),
            .graphic(name: "Bass Boost", mode: m10, gains: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0], preamp: -4),
            .graphic(name: "Treble Boost", mode: m10, gains: [0, 0, 0, 0, 0, 0, 1, 3, 5, 6], preamp: -4),
            .graphic(name: "V-Shape", mode: m10, gains: [5, 3, 1, -1, -2, -2, -1, 1, 3, 5], preamp: -4),
            .graphic(name: "Vocal", mode: m10, gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1], preamp: -3),
            .graphic(name: "Podcast", mode: m10, gains: [-4, -2, 0, 2, 4, 5, 4, 2, 0, -2], preamp: -3),
            .graphic(name: "Loudness", mode: m10, gains: [5, 3, 1, 0, -1, -1, 0, 1, 3, 4], preamp: -4),
            .graphic(name: "Rock", mode: m10, gains: [4, 3, 1, 0, -1, 0, 2, 3, 3, 2], preamp: -3),
            .graphic(name: "Electronic", mode: m10, gains: [5, 4, 2, 0, -1, 0, 1, 2, 4, 5], preamp: -4),
            .graphic(name: "Classical", mode: m10, gains: [0, 0, 0, 0, 0, 0, -1, -1, -1, -1], preamp: 0),
        ]
    }()
}

// MARK: - Persisted app state

struct AppPreferences: Codable {
    var eqEnabled: Bool = false
    var bandMode: EQBandMode = .ten
    var selectedPresetName: String = "Flat"
    var customGains: [Float] = Array(repeating: 0, count: 15)
    var preampDB: Float = 0
    var lastHeadphoneName: String?

    static let defaultsKey = "EQForMac.preferences"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            return AppPreferences()
        }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
