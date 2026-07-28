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
    /// True for a non-destructive graphic/curve edit layered over an imported
    /// parametric preset. Persisting this marker prevents later edits from
    /// repurposing one of the source preset's filters.
    var isUserOverlay: Bool

    init(
        id: UUID = UUID(),
        filterType: EQFilterType = .parametric,
        frequency: Float,
        gain: Float = 0,
        bandwidth: Float = 1.0,
        enabled: Bool = true,
        isUserOverlay: Bool = false
    ) {
        self.id = id
        self.filterType = filterType
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.enabled = enabled
        self.isUserOverlay = isUserOverlay
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case filterType
        case frequency
        case gain
        case bandwidth
        case enabled
        case isUserOverlay
        // Compatibility with early exports that stored Q instead of bandwidth.
        case q
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filterType = try container.decodeIfPresent(EQFilterType.self, forKey: .filterType)
            ?? .parametric
        frequency = try container.decodeIfPresent(Float.self, forKey: .frequency) ?? 1_000
        gain = try container.decodeIfPresent(Float.self, forKey: .gain) ?? 0
        if let decodedBandwidth = try container.decodeIfPresent(Float.self, forKey: .bandwidth) {
            bandwidth = decodedBandwidth
        } else if let legacyQ = try container.decodeIfPresent(Float.self, forKey: .q) {
            bandwidth = Self.bandwidthFromQ(legacyQ)
        } else {
            bandwidth = 1
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isUserOverlay = try container.decodeIfPresent(Bool.self, forKey: .isUserOverlay)
            ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filterType, forKey: .filterType)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(gain, forKey: .gain)
        try container.encode(bandwidth, forKey: .bandwidth)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(isUserOverlay, forKey: .isUserOverlay)
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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case preampDB
        case bands
        case bandMode
        case isBuiltIn
        case isHeadphone
        case source
        // Compatibility with early hand-authored preset JSON.
        case preamp
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Preset"
        preampDB = try container.decodeIfPresent(Float.self, forKey: .preampDB)
            ?? container.decodeIfPresent(Float.self, forKey: .preamp)
            ?? 0
        bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        isHeadphone = try container.decodeIfPresent(Bool.self, forKey: .isHeadphone) ?? false
        bandMode = try container.decodeIfPresent(EQBandMode.self, forKey: .bandMode)
            ?? container.decodeIfPresent(EQBandMode.self, forKey: .mode)
            ?? (isHeadphone ? .parametric : (bands.count == 15 ? .fifteen : .ten))
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(preampDB, forKey: .preampDB)
        try container.encode(bands, forKey: .bands)
        try container.encode(bandMode, forKey: .bandMode)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(isHeadphone, forKey: .isHeadphone)
        try container.encodeIfPresent(source, forKey: .source)
    }

    var isFlat: Bool {
        abs(preampDB) < 0.01 && bands.allSatisfy { band in
            guard band.enabled else { return true }
            switch band.filterType {
            case .parametric, .lowShelf, .highShelf:
                return abs(band.gain) < 0.01
            case .lowPass, .highPass, .bandPass, .notch:
                return false
            }
        }
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

// MARK: - Personal presets and output-device profiles

/// A user-owned preset plus library metadata.
///
/// The preset's UUID is the stable identity. `init(from:)` also accepts a bare
/// `EQPreset`, which lets older arrays migrate without a one-off data rewrite.
struct UserPreset: Codable, Identifiable, Equatable, Sendable {
    var preset: EQPreset
    var isFavorite: Bool
    var createdAt: Date
    var modifiedAt: Date

    var id: UUID { preset.id }
    var name: String { preset.name }

    init(
        preset: EQPreset,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.preset = preset
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case preset
        case isFavorite
        case createdAt
        case modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.preset) {
            preset = try container.decode(EQPreset.self, forKey: .preset)
            isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
                ?? Date(timeIntervalSince1970: 0)
            modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
                ?? createdAt
        } else {
            // Legacy user-preset payloads were stored directly as EQPreset.
            preset = try EQPreset(from: decoder)
            isFavorite = false
            createdAt = Date(timeIntervalSince1970: 0)
            modifiedAt = createdAt
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

/// Snapshot of the EQ state to restore when an output device becomes active.
///
/// A full preset is stored rather than only a preset name so renaming or
/// deleting a user preset cannot silently break an existing device profile.
struct DeviceProfile: Codable, Identifiable, Equatable, Sendable {
    var deviceUID: String
    var deviceName: String
    var preset: EQPreset
    var eqEnabled: Bool
    var updatedAt: Date

    var id: String { deviceUID }

    init(
        deviceUID: String,
        deviceName: String,
        preset: EQPreset,
        eqEnabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.preset = preset
        self.eqEnabled = eqEnabled
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceUID
        case deviceName
        case preset
        case eqEnabled
        case updatedAt
        // Compatibility aliases for early development builds.
        case uid
        case name
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceUID = try container.decodeIfPresent(String.self, forKey: .deviceUID)
            ?? container.decodeIfPresent(String.self, forKey: .uid)
            ?? ""
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? deviceUID
        preset = try container.decode(EQPreset.self, forKey: .preset)
        eqEnabled = try container.decodeIfPresent(Bool.self, forKey: .eqEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceUID, forKey: .deviceUID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(preset, forKey: .preset)
        try container.encode(eqEnabled, forKey: .eqEnabled)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Persisted headphone pins/history. Names are used because catalog entries
/// deliberately have stable, human-readable identifiers across catalog builds.
struct HeadphoneLibraryState: Codable, Equatable, Sendable {
    var favoriteNames: [String] = []
    var recentNames: [String] = []

    private enum CodingKeys: String, CodingKey {
        case favoriteNames
        case recentNames
        case favoriteHeadphoneNames
        case recentHeadphoneNames
        case favorites
        case recents
    }

    init(favoriteNames: [String] = [], recentNames: [String] = []) {
        self.favoriteNames = favoriteNames
        self.recentNames = recentNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favoriteNames = try container.decodeIfPresent([String].self, forKey: .favoriteNames)
            ?? container.decodeIfPresent([String].self, forKey: .favoriteHeadphoneNames)
            ?? container.decodeIfPresent([String].self, forKey: .favorites)
            ?? []
        recentNames = try container.decodeIfPresent([String].self, forKey: .recentNames)
            ?? container.decodeIfPresent([String].self, forKey: .recentHeadphoneNames)
            ?? container.decodeIfPresent([String].self, forKey: .recents)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(favoriteNames, forKey: .favoriteNames)
        try container.encode(recentNames, forKey: .recentNames)
    }
}

// MARK: - Persisted app state

struct AppPreferences: Codable, Equatable, Sendable {
    var eqEnabled: Bool
    var bandMode: EQBandMode
    var selectedPresetName: String
    var selectedUserPresetID: UUID?
    var customGains: [Float]
    var tenBandGains: [Float]?
    var fifteenBandGains: [Float]?
    var preampDB: Float
    var lastHeadphoneName: String?

    var autoPreampEnabled: Bool
    var autoPreampDefaultEnabled: Bool
    var launchAtLogin: Bool
    var hotKeyEnabled: Bool
    var hotKeyKeyCode: UInt32?
    var hotKeyModifiers: UInt32
    var crossfeedEnabled: Bool
    var crossfeedAmount: Float
    var stereoWidth: Float
    var balance: Float
    var monoEnabled: Bool

    var favoritePresetIDs: [UUID]
    var favoriteHeadphoneNames: [String]
    var recentHeadphoneNames: [String]
    var deviceProfiles: [DeviceProfile]
    var activeParametricBands: [EQBand]?

    static let defaultsKey = "EQForMac.preferences"

    init(
        eqEnabled: Bool = false,
        bandMode: EQBandMode = .ten,
        selectedPresetName: String = "Flat",
        selectedUserPresetID: UUID? = nil,
        customGains: [Float] = Array(repeating: 0, count: 15),
        tenBandGains: [Float]? = nil,
        fifteenBandGains: [Float]? = nil,
        preampDB: Float = 0,
        lastHeadphoneName: String? = nil,
        autoPreampEnabled: Bool = false,
        autoPreampDefaultEnabled: Bool = false,
        launchAtLogin: Bool = false,
        hotKeyEnabled: Bool = false,
        hotKeyKeyCode: UInt32? = nil,
        hotKeyModifiers: UInt32 = 0,
        crossfeedEnabled: Bool = false,
        crossfeedAmount: Float = 0.25,
        stereoWidth: Float = 1,
        balance: Float = 0,
        monoEnabled: Bool = false,
        favoritePresetIDs: [UUID] = [],
        favoriteHeadphoneNames: [String] = [],
        recentHeadphoneNames: [String] = [],
        deviceProfiles: [DeviceProfile] = [],
        activeParametricBands: [EQBand]? = nil
    ) {
        self.eqEnabled = eqEnabled
        self.bandMode = bandMode
        self.selectedPresetName = selectedPresetName
        self.selectedUserPresetID = selectedUserPresetID
        self.customGains = customGains
        self.tenBandGains = tenBandGains
        self.fifteenBandGains = fifteenBandGains
        self.preampDB = preampDB
        self.lastHeadphoneName = lastHeadphoneName
        self.autoPreampEnabled = autoPreampEnabled
        self.autoPreampDefaultEnabled = autoPreampDefaultEnabled
        self.launchAtLogin = launchAtLogin
        self.hotKeyEnabled = hotKeyEnabled
        self.hotKeyKeyCode = hotKeyKeyCode
        self.hotKeyModifiers = hotKeyModifiers
        self.crossfeedEnabled = crossfeedEnabled
        self.crossfeedAmount = crossfeedAmount
        self.stereoWidth = stereoWidth
        self.balance = balance
        self.monoEnabled = monoEnabled
        self.favoritePresetIDs = favoritePresetIDs
        self.favoriteHeadphoneNames = favoriteHeadphoneNames
        self.recentHeadphoneNames = recentHeadphoneNames
        self.deviceProfiles = deviceProfiles
        self.activeParametricBands = activeParametricBands
    }

    private enum CodingKeys: String, CodingKey {
        case eqEnabled
        case bandMode
        case selectedPresetName
        case selectedUserPresetID
        case customGains
        case tenBandGains
        case fifteenBandGains
        case preampDB
        case lastHeadphoneName
        case autoPreampEnabled
        case autoPreampDefaultEnabled
        case launchAtLogin
        case hotKeyEnabled
        case hotKeyKeyCode
        case hotKeyModifiers
        case crossfeedEnabled
        case crossfeedAmount
        case stereoWidth
        case balance
        case monoEnabled
        case favoritePresetIDs
        case favoriteHeadphoneNames
        case recentHeadphoneNames
        case deviceProfiles
        case activeParametricBands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eqEnabled = try container.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        bandMode = try container.decodeIfPresent(EQBandMode.self, forKey: .bandMode) ?? .ten
        selectedPresetName = try container.decodeIfPresent(String.self, forKey: .selectedPresetName)
            ?? "Flat"
        selectedUserPresetID = try container.decodeIfPresent(
            UUID.self,
            forKey: .selectedUserPresetID
        )
        customGains = try container.decodeIfPresent([Float].self, forKey: .customGains)
            ?? Array(repeating: 0, count: 15)
        tenBandGains = try container.decodeIfPresent([Float].self, forKey: .tenBandGains)
        fifteenBandGains = try container.decodeIfPresent([Float].self, forKey: .fifteenBandGains)
        preampDB = try container.decodeIfPresent(Float.self, forKey: .preampDB) ?? 0
        lastHeadphoneName = try container.decodeIfPresent(String.self, forKey: .lastHeadphoneName)
        autoPreampEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoPreampEnabled)
            ?? false
        autoPreampDefaultEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoPreampDefaultEnabled
        ) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hotKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? false
        hotKeyKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .hotKeyKeyCode)
        hotKeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? 0
        crossfeedEnabled = try container.decodeIfPresent(Bool.self, forKey: .crossfeedEnabled)
            ?? false
        crossfeedAmount = try container.decodeIfPresent(Float.self, forKey: .crossfeedAmount)
            ?? 0.25
        stereoWidth = try container.decodeIfPresent(Float.self, forKey: .stereoWidth) ?? 1
        balance = try container.decodeIfPresent(Float.self, forKey: .balance) ?? 0
        monoEnabled = try container.decodeIfPresent(Bool.self, forKey: .monoEnabled) ?? false
        favoritePresetIDs = try container.decodeIfPresent([UUID].self, forKey: .favoritePresetIDs)
            ?? []
        favoriteHeadphoneNames = try container.decodeIfPresent(
            [String].self,
            forKey: .favoriteHeadphoneNames
        ) ?? []
        recentHeadphoneNames = try container.decodeIfPresent(
            [String].self,
            forKey: .recentHeadphoneNames
        ) ?? []
        deviceProfiles = try container.decodeIfPresent(
            [DeviceProfile].self,
            forKey: .deviceProfiles
        ) ?? []
        activeParametricBands = try container.decodeIfPresent(
            [EQBand].self,
            forKey: .activeParametricBands
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eqEnabled, forKey: .eqEnabled)
        try container.encode(bandMode, forKey: .bandMode)
        try container.encode(selectedPresetName, forKey: .selectedPresetName)
        try container.encodeIfPresent(selectedUserPresetID, forKey: .selectedUserPresetID)
        try container.encode(customGains, forKey: .customGains)
        try container.encodeIfPresent(tenBandGains, forKey: .tenBandGains)
        try container.encodeIfPresent(fifteenBandGains, forKey: .fifteenBandGains)
        try container.encode(preampDB, forKey: .preampDB)
        try container.encodeIfPresent(lastHeadphoneName, forKey: .lastHeadphoneName)
        try container.encode(autoPreampEnabled, forKey: .autoPreampEnabled)
        try container.encode(autoPreampDefaultEnabled, forKey: .autoPreampDefaultEnabled)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(hotKeyEnabled, forKey: .hotKeyEnabled)
        try container.encodeIfPresent(hotKeyKeyCode, forKey: .hotKeyKeyCode)
        try container.encode(hotKeyModifiers, forKey: .hotKeyModifiers)
        try container.encode(crossfeedEnabled, forKey: .crossfeedEnabled)
        try container.encode(crossfeedAmount, forKey: .crossfeedAmount)
        try container.encode(stereoWidth, forKey: .stereoWidth)
        try container.encode(balance, forKey: .balance)
        try container.encode(monoEnabled, forKey: .monoEnabled)
        try container.encode(favoritePresetIDs, forKey: .favoritePresetIDs)
        try container.encode(favoriteHeadphoneNames, forKey: .favoriteHeadphoneNames)
        try container.encode(recentHeadphoneNames, forKey: .recentHeadphoneNames)
        try container.encode(deviceProfiles, forKey: .deviceProfiles)
        try container.encodeIfPresent(activeParametricBands, forKey: .activeParametricBands)
    }

    static func load(from defaults: UserDefaults = .standard) -> AppPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            return AppPreferences()
        }
        return prefs
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
