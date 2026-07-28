import Combine
import Foundation

// MARK: - Catalog entry

struct HeadphoneCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    let name: String
    /// Relative AutoEq path (documentation only; offline uses `file`).
    let path: String?
    let source: String?
    let hasEQ: Bool
    let autoeqName: String?
    /// Bundled filename under Resources/autoeq/ (e.g. `a1b2c3d4e5f6.txt`).
    let file: String?
    /// PEQdB Studio grouping for reference targets. Nil for headphone measurements.
    let targetCategory: String?
    /// Alternate public names used by the source (for example a year-qualified name).
    let aliases: [String]?

    var isTargetCurve: Bool { targetCategory != nil }

    init(
        name: String,
        path: String? = nil,
        source: String? = nil,
        hasEQ: Bool = false,
        autoeqName: String? = nil,
        file: String? = nil,
        targetCategory: String? = nil,
        aliases: [String]? = nil
    ) {
        self.name = name
        self.path = path
        self.source = source
        self.hasEQ = hasEQ
        self.autoeqName = autoeqName
        self.file = file
        self.targetCategory = targetCategory
        self.aliases = aliases
    }
}

private struct TargetCurvesFile: Codable {
    let targets: [TargetDTO]

    struct TargetDTO: Codable {
        let name: String
        let category: String
        let aliases: [String]?
    }
}

private struct HeadphonesCatalogFile: Codable {
    let version: Int?
    let mode: String?
    let graphs: [GraphDTO]?
    let extraAutoEQ: [GraphDTO]?
    let headphones: [LegacyDTO]?
    let peqdbNames: [String]?

    struct GraphDTO: Codable {
        let name: String
        let path: String?
        let source: String?
        let hasEQ: Bool?
        let autoeqName: String?
        let file: String?
    }

    struct LegacyDTO: Codable {
        let name: String
        let path: String
        let source: String
    }
}

enum PresetStoreError: LocalizedError, Equatable {
    case emptyPresetName
    case duplicatePresetName(String)
    case userPresetNotFound
    case emptyDeviceUID

    var errorDescription: String? {
        switch self {
        case .emptyPresetName:
            return "Preset name cannot be empty."
        case .duplicatePresetName(let name):
            return "A user preset named “\(name)” already exists."
        case .userPresetNotFound:
            return "The user preset no longer exists."
        case .emptyDeviceUID:
            return "The output device does not have a stable identifier."
        }
    }
}

private struct CatalogSearchDocument {
    let entry: HeadphoneCatalogEntry
    let normalizedName: String
    let normalizedAliases: [String]
    let tokens: [String]
    let compactFields: [String]
}

private struct CatalogSearchMatch {
    let entry: HeadphoneCatalogEntry
    let score: Int
    let isFavorite: Bool
    let recentRank: Int?
}

// MARK: - Preset store (fully offline)

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var bundledHeadphones: [EQPreset] = []
    @Published private(set) var imported: [EQPreset] = []
    @Published private(set) var userPresets: [UserPreset] = []
    @Published private(set) var catalog: [HeadphoneCatalogEntry] = []
    @Published private(set) var catalogCount: Int = 0
    @Published private(set) var withEQCount: Int = 0
    @Published private(set) var favoriteHeadphoneNames: [String] = []
    @Published private(set) var recentHeadphoneNames: [String] = []
    @Published private(set) var deviceProfiles: [DeviceProfile] = []
    @Published private(set) var isLoadingRemote = false
    @Published private(set) var lastLoadError: String?

    private let defaults: UserDefaults
    private let importedKey = "EQForMac.importedPresets"
    private let userPresetsKey = "EQForMac.userPresets"
    private let headphoneLibraryKey = "EQForMac.headphoneLibrary"
    private let deviceProfilesKey = "EQForMac.deviceProfiles"
    private let maximumRecentHeadphones = 12
    private var presetCache: [String: EQPreset] = [:]
    private var catalogSearchDocuments: [CatalogSearchDocument] = []
    private var catalogByNormalizedName: [String: HeadphoneCatalogEntry] = [:]

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        loadCatalog()
        rebuildCatalogSearchIndex()
        loadBundledHeadphones()
        loadImported()
        loadUserPresets()
        loadHeadphoneLibrary()
        loadDeviceProfiles()
        for preset in bundledHeadphones {
            presetCache[preset.name.lowercased()] = preset
        }
    }

    var builtIn: [EQPreset] { EQPreset.builtInPresets }
    var headphones: [EQPreset] { bundledHeadphones }
    var favoriteUserPresets: [UserPreset] { userPresets.filter(\.isFavorite) }

    var favoriteHeadphones: [HeadphoneCatalogEntry] {
        entries(named: favoriteHeadphoneNames)
    }

    /// Recent entries excluding pins, suitable for a separate "Recent" section.
    var recentHeadphones: [HeadphoneCatalogEntry] {
        let favoriteKeys = Set(favoriteHeadphoneNames.map(Self.catalogIdentityKey))
        return entries(named: recentHeadphoneNames).filter {
            !favoriteKeys.contains(Self.catalogIdentityKey($0.name))
        }
    }

    // MARK: - User presets

    func userPreset(id: UUID) -> UserPreset? {
        userPresets.first { $0.id == id }
    }

    func userPreset(named name: String) -> UserPreset? {
        let key = Self.presetNameKey(name)
        return userPresets.first { Self.presetNameKey($0.name) == key }
    }

    /// Save-as always creates a new stable user-preset identity.
    @discardableResult
    func saveUserPreset(_ preset: EQPreset, named requestedName: String? = nil) throws -> UserPreset {
        let name = try validatedPresetName(requestedName ?? preset.name)
        guard userPreset(named: name) == nil else {
            throw PresetStoreError.duplicatePresetName(name)
        }

        var storedPreset = preset
        storedPreset.id = UUID()
        storedPreset.name = name
        storedPreset.isBuiltIn = false
        let now = Date()
        let userPreset = UserPreset(
            preset: storedPreset,
            isFavorite: false,
            createdAt: now,
            modifiedAt: now
        )
        userPresets.append(userPreset)
        saveUserPresets()
        return userPreset
    }

    /// Replace a saved curve while preserving its identity, position, and pin.
    @discardableResult
    func updateUserPreset(id: UUID, with preset: EQPreset) throws -> UserPreset {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else {
            throw PresetStoreError.userPresetNotFound
        }
        let name = try validatedPresetName(preset.name)
        guard !userPresets.contains(where: {
            $0.id != id && Self.presetNameKey($0.name) == Self.presetNameKey(name)
        }) else {
            throw PresetStoreError.duplicatePresetName(name)
        }

        var storedPreset = preset
        storedPreset.id = id
        storedPreset.name = name
        storedPreset.isBuiltIn = false
        userPresets[index].preset = storedPreset
        userPresets[index].modifiedAt = Date()
        let result = userPresets[index]
        saveUserPresets()
        return result
    }

    @discardableResult
    func renameUserPreset(id: UUID, to requestedName: String) throws -> UserPreset {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else {
            throw PresetStoreError.userPresetNotFound
        }
        let name = try validatedPresetName(requestedName)
        guard !userPresets.contains(where: {
            $0.id != id && Self.presetNameKey($0.name) == Self.presetNameKey(name)
        }) else {
            throw PresetStoreError.duplicatePresetName(name)
        }
        userPresets[index].preset.name = name
        userPresets[index].modifiedAt = Date()
        let result = userPresets[index]
        saveUserPresets()
        return result
    }

    @discardableResult
    func deleteUserPreset(id: UUID) -> Bool {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return false }
        userPresets.remove(at: index)
        saveUserPresets()
        return true
    }

    /// Move a single preset to a final zero-based index.
    @discardableResult
    func moveUserPreset(id: UUID, to destinationIndex: Int) -> Bool {
        guard let sourceIndex = userPresets.firstIndex(where: { $0.id == id }),
              userPresets.count > 1
        else { return false }
        let destination = max(0, min(userPresets.count - 1, destinationIndex))
        guard sourceIndex != destination else { return false }
        let preset = userPresets.remove(at: sourceIndex)
        userPresets.insert(preset, at: destination)
        saveUserPresets()
        return true
    }

    /// SwiftUI `onMove`-compatible batch reorder.
    func moveUserPresets(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.sorted().filter { userPresets.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }

        let moving = validOffsets.map { userPresets[$0] }
        let offsetSet = Set(validOffsets)
        var remaining = userPresets.enumerated().compactMap { index, preset in
            offsetSet.contains(index) ? nil : preset
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = max(
            0,
            min(remaining.count, destination - removedBeforeDestination)
        )
        remaining.insert(contentsOf: moving, at: insertionIndex)
        guard remaining != userPresets else { return }
        userPresets = remaining
        saveUserPresets()
    }

    @discardableResult
    func setUserPresetFavorite(id: UUID, isFavorite: Bool) -> UserPreset? {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return nil }
        guard userPresets[index].isFavorite != isFavorite else { return userPresets[index] }
        userPresets[index].isFavorite = isFavorite
        userPresets[index].modifiedAt = Date()
        let result = userPresets[index]
        saveUserPresets()
        return result
    }

    @discardableResult
    func toggleUserPresetFavorite(id: UUID) -> UserPreset? {
        guard let preset = userPreset(id: id) else { return nil }
        return setUserPresetFavorite(id: id, isFavorite: !preset.isFavorite)
    }

    // MARK: - Search

    func searchCatalog(_ query: String, limit: Int = 800) -> [HeadphoneCatalogEntry] {
        guard limit > 0 else { return [] }
        let normalizedQuery = Self.normalizedSearchText(query)
        if normalizedQuery.isEmpty {
            var promoted: [HeadphoneCatalogEntry] = []
            var seen = Set<String>()
            for entry in favoriteHeadphones + entries(named: recentHeadphoneNames) + catalog {
                let key = Self.catalogIdentityKey(entry.name)
                guard seen.insert(key).inserted else { continue }
                promoted.append(entry)
                if promoted.count == limit { break }
            }
            return promoted
        }

        let queryTerms = normalizedQuery.split(separator: " ").map(String.init)
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
        let favoriteKeys = Set(favoriteHeadphoneNames.map(Self.catalogIdentityKey))
        let recentRanks = Dictionary(
            uniqueKeysWithValues: recentHeadphoneNames.enumerated().map {
                (Self.catalogIdentityKey($0.element), $0.offset)
            }
        )

        var matches: [CatalogSearchMatch] = []
        matches.reserveCapacity(min(catalogSearchDocuments.count, limit * 2))
        for document in catalogSearchDocuments {
            guard var score = Self.searchScore(
                document: document,
                normalizedQuery: normalizedQuery,
                compactQuery: compactQuery,
                queryTerms: queryTerms
            ) else { continue }

            let identity = Self.catalogIdentityKey(document.entry.name)
            let favorite = favoriteKeys.contains(identity)
            let recentRank = recentRanks[identity]
            if favorite { score += 180 }
            if let recentRank {
                score += max(15, 70 - recentRank * 5)
            }
            if document.entry.hasEQ { score += 20 }
            matches.append(
                CatalogSearchMatch(
                    entry: document.entry,
                    score: score,
                    isFavorite: favorite,
                    recentRank: recentRank
                )
            )
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
            switch (lhs.recentRank, rhs.recentRank) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            if lhs.entry.hasEQ != rhs.entry.hasEQ {
                return lhs.entry.hasEQ && !rhs.entry.hasEQ
            }
            return lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name)
                == .orderedAscending
        }
        return matches.prefix(limit).map(\.entry)
    }

    func catalogEntry(named name: String) -> HeadphoneCatalogEntry? {
        catalogByNormalizedName[Self.catalogIdentityKey(name)]
    }

    func headphone(named name: String) -> EQPreset? {
        if let cached = presetCache[name.lowercased()] { return cached }
        return bundledHeadphones.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? imported.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? userPresets.lazy.map(\.preset).first {
                $0.isHeadphone && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
    }

    func isHeadphoneFavorite(named name: String) -> Bool {
        let key = Self.catalogIdentityKey(name)
        return favoriteHeadphoneNames.contains { Self.catalogIdentityKey($0) == key }
    }

    func isHeadphoneFavorite(_ entry: HeadphoneCatalogEntry) -> Bool {
        isHeadphoneFavorite(named: entry.name)
    }

    @discardableResult
    func setHeadphoneFavorite(named name: String, isFavorite: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let canonicalName = catalogEntry(named: trimmed)?.name ?? trimmed
        let key = Self.catalogIdentityKey(canonicalName)
        let wasFavorite = favoriteHeadphoneNames.contains {
            Self.catalogIdentityKey($0) == key
        }
        guard wasFavorite != isFavorite else { return isFavorite }

        favoriteHeadphoneNames.removeAll { Self.catalogIdentityKey($0) == key }
        if isFavorite {
            favoriteHeadphoneNames.insert(canonicalName, at: 0)
        }
        saveHeadphoneLibrary()
        return isFavorite
    }

    @discardableResult
    func setHeadphoneFavorite(_ entry: HeadphoneCatalogEntry, isFavorite: Bool) -> Bool {
        setHeadphoneFavorite(named: entry.name, isFavorite: isFavorite)
    }

    @discardableResult
    func toggleHeadphoneFavorite(named name: String) -> Bool {
        setHeadphoneFavorite(named: name, isFavorite: !isHeadphoneFavorite(named: name))
    }

    @discardableResult
    func toggleHeadphoneFavorite(_ entry: HeadphoneCatalogEntry) -> Bool {
        toggleHeadphoneFavorite(named: entry.name)
    }

    func recordRecentHeadphone(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = catalogEntry(named: trimmed)
        guard entry?.isTargetCurve != true else { return }
        let canonicalName = entry?.name ?? trimmed
        let key = Self.catalogIdentityKey(canonicalName)
        if recentHeadphoneNames.first.map(Self.catalogIdentityKey) == key {
            return
        }
        recentHeadphoneNames.removeAll { Self.catalogIdentityKey($0) == key }
        recentHeadphoneNames.insert(canonicalName, at: 0)
        if recentHeadphoneNames.count > maximumRecentHeadphones {
            recentHeadphoneNames.removeLast(
                recentHeadphoneNames.count - maximumRecentHeadphones
            )
        }
        saveHeadphoneLibrary()
    }

    func recordRecentHeadphone(_ entry: HeadphoneCatalogEntry) {
        guard !entry.isTargetCurve else { return }
        recordRecentHeadphone(named: entry.name)
    }

    // MARK: - Load EQ (offline only)

    func loadPreset(for entry: HeadphoneCatalogEntry) async throws -> EQPreset {
        let cacheKey = entry.name.lowercased()
        if let cached = presetCache[cacheKey] {
            var resolved = cached
            resolved.name = entry.name
            presetCache[cacheKey] = resolved
            recordRecentHeadphone(entry)
            return resolved
        }

        // Bundled popular presets by name
        if let bundled = bundledHeadphones.first(where: {
            $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
                || (entry.autoeqName != nil
                    && $0.name.caseInsensitiveCompare(entry.autoeqName!) == .orderedSame)
        }) {
            var resolved = bundled
            resolved.name = entry.name
            presetCache[cacheKey] = resolved
            recordRecentHeadphone(entry)
            return resolved
        }

        guard entry.hasEQ else {
            throw AudioError.message(
                "No published offline EQ for “\(entry.name)”. Export from peqdb.com/studio or autoeq.app and use Import EQ file…"
            )
        }

        // Preferred: local file in autoeq/
        if let file = entry.file, let url = resolveAutoEQFile(file) {
            let parsed = try EqualizerAPOParser.parseFile(at: url)
            let src = entry.source ?? "AutoEQ"
            let preset = EQPreset(
                name: entry.name,
                preampDB: parsed.preampDB,
                bands: parsed.bands,
                bandMode: .parametric,
                isBuiltIn: true,
                isHeadphone: true,
                source: "AutoEQ · \(src) · offline"
            )
            presetCache[cacheKey] = preset
            recordRecentHeadphone(entry)
            return preset
        }

        throw AudioError.message(
            "EQ file missing offline for “\(entry.name)”. Reinstall the app or import a PEQdB/AutoEQ .txt."
        )
    }

    // MARK: - Import

    @discardableResult
    func importFile(at url: URL) throws -> EQPreset {
        let parsed = try EqualizerAPOParser.parseFile(at: url)
        let name = url.deletingPathExtension().lastPathComponent
        let preset = EQPreset(
            name: name,
            preampDB: parsed.preampDB,
            bands: parsed.bands,
            bandMode: .parametric,
            isBuiltIn: false,
            isHeadphone: true,
            source: "Imported · \(url.lastPathComponent)"
        )
        imported.removeAll {
            $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
        }
        imported.append(preset)
        imported.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        presetCache[name.lowercased()] = preset
        saveImported()
        return preset
    }

    func removeImported(_ preset: EQPreset) {
        let removedName = preset.name
        imported.removeAll { $0.id == preset.id }
        let cacheKey = removedName.lowercased()
        if presetCache[cacheKey]?.id == preset.id {
            presetCache.removeValue(forKey: cacheKey)
            if let bundled = bundledHeadphones.first(where: {
                $0.name.caseInsensitiveCompare(removedName) == .orderedSame
            }) {
                presetCache[cacheKey] = bundled
            }
        }
        saveImported()
    }

    // MARK: - Output-device profiles

    func deviceProfile(for deviceUID: String) -> DeviceProfile? {
        deviceProfiles.first { $0.deviceUID == deviceUID }
    }

    @discardableResult
    func saveDeviceProfile(
        deviceUID: String,
        deviceName: String,
        preset: EQPreset,
        eqEnabled: Bool = true
    ) throws -> DeviceProfile {
        let profile = DeviceProfile(
            deviceUID: deviceUID,
            deviceName: deviceName,
            preset: preset,
            eqEnabled: eqEnabled,
            updatedAt: Date()
        )
        return try saveDeviceProfile(profile)
    }

    @discardableResult
    func saveDeviceProfile(_ profile: DeviceProfile) throws -> DeviceProfile {
        let deviceUID = profile.deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceUID.isEmpty else { throw PresetStoreError.emptyDeviceUID }

        var storedProfile = profile
        storedProfile.deviceUID = deviceUID
        storedProfile.deviceName = profile.deviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if storedProfile.deviceName.isEmpty {
            storedProfile.deviceName = deviceUID
        }
        if let index = deviceProfiles.firstIndex(where: { $0.deviceUID == deviceUID }) {
            deviceProfiles[index] = storedProfile
        } else {
            deviceProfiles.append(storedProfile)
        }
        saveDeviceProfiles()
        return storedProfile
    }

    @discardableResult
    func deleteDeviceProfile(for deviceUID: String) -> Bool {
        guard let index = deviceProfiles.firstIndex(where: { $0.deviceUID == deviceUID }) else {
            return false
        }
        deviceProfiles.remove(at: index)
        saveDeviceProfiles()
        return true
    }

    // MARK: - Search internals

    private func rebuildCatalogSearchIndex() {
        var byName: [String: HeadphoneCatalogEntry] = [:]
        catalogSearchDocuments = catalog.map { entry in
            let normalizedName = Self.normalizedSearchText(entry.name)
            let normalizedAliases = (entry.aliases ?? []).map(Self.normalizedSearchText)
                .filter { !$0.isEmpty }
            var rawFields = [entry.name]
            rawFields.append(contentsOf: entry.aliases ?? [])
            for field in [entry.autoeqName, entry.source, entry.targetCategory] {
                if let field, !field.isEmpty { rawFields.append(field) }
            }
            let normalizedFields = rawFields.map(Self.normalizedSearchText)
                .filter { !$0.isEmpty }
            let tokens = Array(Set(normalizedFields.flatMap {
                $0.split(separator: " ").map(String.init)
            }))
            let compactFields = Array(Set(normalizedFields.map {
                $0.replacingOccurrences(of: " ", with: "")
            }))

            let nameKey = Self.catalogIdentityKey(entry.name)
            if byName[nameKey] == nil { byName[nameKey] = entry }
            for alias in entry.aliases ?? [] {
                let aliasKey = Self.catalogIdentityKey(alias)
                if byName[aliasKey] == nil { byName[aliasKey] = entry }
            }

            return CatalogSearchDocument(
                entry: entry,
                normalizedName: normalizedName,
                normalizedAliases: normalizedAliases,
                tokens: tokens,
                compactFields: compactFields
            )
        }
        catalogByNormalizedName = byName
    }

    private static func searchScore(
        document: CatalogSearchDocument,
        normalizedQuery: String,
        compactQuery: String,
        queryTerms: [String]
    ) -> Int? {
        var phraseScore = 0
        let compactName = document.normalizedName.replacingOccurrences(of: " ", with: "")
        if document.normalizedName == normalizedQuery {
            phraseScore = 1_500
        } else if document.normalizedAliases.contains(normalizedQuery) {
            phraseScore = 1_450
        } else if document.normalizedName.hasPrefix(normalizedQuery) {
            phraseScore = 1_300
        } else if document.normalizedAliases.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            phraseScore = 1_250
        } else if compactName == compactQuery {
            phraseScore = 1_400
        } else if compactName.hasPrefix(compactQuery) {
            phraseScore = 1_200
        } else if document.normalizedName.contains(normalizedQuery) {
            phraseScore = 1_100
        } else if document.normalizedAliases.contains(where: { $0.contains(normalizedQuery) }) {
            phraseScore = 1_050
        } else if document.compactFields.contains(where: { $0.contains(compactQuery) }) {
            phraseScore = 950
        }

        var termScore = 0
        for term in queryTerms {
            guard let score = bestTermScore(
                term,
                tokens: document.tokens,
                compactFields: document.compactFields
            ) else {
                return nil
            }
            termScore += score
        }
        return max(phraseScore, 260 + termScore)
    }

    private static func bestTermScore(
        _ term: String,
        tokens: [String],
        compactFields: [String]
    ) -> Int? {
        var best: Int?
        for token in tokens {
            let score: Int?
            if token == term {
                score = 160
            } else if token.hasPrefix(term) {
                score = max(115, 145 - (token.count - term.count))
            } else if token.contains(term) {
                score = 110
            } else {
                score = nil
            }
            if let score { best = max(best ?? score, score) }
        }
        if compactFields.contains(where: { $0.contains(term) }) {
            best = max(best ?? 105, 105)
        }
        if best != nil { return best }

        guard term.count >= 3 else { return nil }
        let maximumDistance = term.count <= 4 ? 1 : 2
        for token in tokens where abs(token.count - term.count) <= maximumDistance {
            guard let distance = boundedEditDistance(
                term,
                token,
                maximumDistance: maximumDistance
            ) else { continue }
            let score = 95 - distance * 18 - abs(token.count - term.count) * 4
            best = max(best ?? score, score)
        }
        return best
    }

    private static func boundedEditDistance(
        _ lhs: String,
        _ rhs: String,
        maximumDistance: Int
    ) -> Int? {
        if lhs == rhs { return 0 }
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= maximumDistance else { return nil }
        if left.isEmpty {
            return right.count <= maximumDistance ? right.count : nil
        }
        if right.isEmpty {
            return left.count <= maximumDistance ? left.count : nil
        }

        var previous = Array(0...right.count)
        for leftIndex in 1...left.count {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            guard rowMinimum <= maximumDistance else { return nil }
            previous = current
        }
        let distance = previous[right.count]
        return distance <= maximumDistance ? distance : nil
    }

    private static func normalizedSearchText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func catalogIdentityKey(_ name: String) -> String {
        normalizedSearchText(name).replacingOccurrences(of: " ", with: "")
    }

    private static func presetNameKey(_ name: String) -> String {
        let normalized = normalizedSearchText(name)
        if !normalized.isEmpty { return normalized }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func entries(named names: [String]) -> [HeadphoneCatalogEntry] {
        var seen = Set<String>()
        return names.compactMap { name in
            guard let entry = catalogEntry(named: name) else { return nil }
            let key = Self.catalogIdentityKey(entry.name)
            guard seen.insert(key).inserted else { return nil }
            return entry
        }
    }

    private func validatedPresetName(_ requestedName: String) throws -> String {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetStoreError.emptyPresetName }
        return name
    }

    // MARK: - Catalog

    private func loadCatalog() {
        if let data = loadResourceData(name: "headphones_catalog", ext: "json"),
           let file = try? JSONDecoder().decode(HeadphonesCatalogFile.self, from: data) {
            applyCatalogFile(file)
            appendTargetCurves()
            return
        }

        if let textData = loadResourceData(name: "graph_names", ext: "txt"),
           let text = String(data: textData, encoding: .utf8) {
            let names = text.split(whereSeparator: \.isNewline).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            catalog = names.map { HeadphoneCatalogEntry(name: $0, hasEQ: false) }
            catalogCount = catalog.count
            withEQCount = 0
            appendTargetCurves()
            return
        }

        lastLoadError = "Headphone catalog missing"
        catalog = []
        catalogCount = 0
    }

    private func applyCatalogFile(_ file: HeadphonesCatalogFile) {
        var entries: [HeadphoneCatalogEntry] = []
        var seen = Set<String>()

        if let graphs = file.graphs {
            for g in graphs {
                let key = g.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                let has = g.hasEQ ?? (g.file != nil || g.path != nil)
                entries.append(
                    HeadphoneCatalogEntry(
                        name: g.name,
                        path: g.path,
                        source: g.source,
                        hasEQ: has && (g.file != nil),
                        autoeqName: g.autoeqName,
                        file: g.file
                    )
                )
            }
        }

        if entries.isEmpty, let headphones = file.headphones {
            for h in headphones {
                let key = h.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                entries.append(
                    HeadphoneCatalogEntry(
                        name: h.name,
                        path: h.path,
                        source: h.source,
                        hasEQ: false,
                        file: nil
                    )
                )
            }
        }

        if let extra = file.extraAutoEQ {
            for g in extra {
                let key = g.name.lowercased()
                guard seen.insert(key).inserted else { continue }
                entries.append(
                    HeadphoneCatalogEntry(
                        name: g.name,
                        path: g.path,
                        source: g.source,
                        hasEQ: (g.hasEQ ?? true) && g.file != nil,
                        autoeqName: g.autoeqName,
                        file: g.file
                    )
                )
            }
        }

        catalog = entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        catalogCount = catalog.count
        withEQCount = catalog.filter(\.hasEQ).count
    }

    private func appendTargetCurves() {
        guard let data = loadResourceData(name: "target_curves", ext: "json"),
              let file = try? JSONDecoder().decode(TargetCurvesFile.self, from: data)
        else { return }

        for target in file.targets {
            let entry = HeadphoneCatalogEntry(
                name: target.name,
                source: "PEQdB Studio",
                hasEQ: false,
                targetCategory: target.category,
                aliases: target.aliases
            )
            if let index = catalog.firstIndex(where: {
                $0.name.caseInsensitiveCompare(target.name) == .orderedSame
            }) {
                catalog[index] = entry
            } else {
                catalog.append(entry)
            }
        }
        catalog.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        catalogCount = catalog.count
        withEQCount = catalog.filter(\.hasEQ).count
    }

    private var resourceBundle: Bundle {
        guard let resourceURL = Bundle.main.resourceURL,
              let bundle = Bundle(
                  url: resourceURL.appendingPathComponent("EQForMac_EQForMac.bundle", isDirectory: true)
              )
        else {
            return .module
        }
        return bundle
    }

    private func resolveAutoEQFile(_ fileName: String) -> URL? {
        if let url = resourceBundle.url(forResource: fileName.replacingOccurrences(of: ".txt", with: ""),
                                        withExtension: "txt",
                                        subdirectory: "autoeq") {
            return url
        }
        if let root = resourceBundle.resourceURL?
            .appendingPathComponent("autoeq", isDirectory: true)
            .appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: root.path) {
            return root
        }
        // Dev fallbacks
        let candidates = [
            URL(fileURLWithPath: "Sources/EQForMac/Resources/autoeq").appendingPathComponent(fileName),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/EQForMac/Resources/autoeq")
                .appendingPathComponent(fileName),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func loadResourceData(name: String, ext: String) -> Data? {
        if let url = resourceBundle.url(forResource: name, withExtension: ext) {
            return try? Data(contentsOf: url)
        }
        let candidates = [
            URL(fileURLWithPath: "Sources/EQForMac/Resources/\(name).\(ext)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/EQForMac/Resources/\(name).\(ext)"),
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    // MARK: - Popular offline subset (named .txt for quick access)

    private func loadBundledHeadphones() {
        var urls: [URL] = []

        if let resourceURL = resourceBundle.resourceURL {
            let dir = resourceURL.appendingPathComponent("headphones", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) {
                urls.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "txt" })
            }
        }

        if urls.isEmpty {
            let candidates = [
                URL(fileURLWithPath: "Sources/EQForMac/Resources/headphones"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Sources/EQForMac/Resources/headphones"),
            ]
            for dir in candidates {
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                ) {
                    urls = files.filter { $0.pathExtension.lowercased() == "txt" }
                    if !urls.isEmpty { break }
                }
            }
        }

        var loaded: [EQPreset] = []
        for url in urls {
            guard let parsed = try? EqualizerAPOParser.parseFile(at: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            loaded.append(
                EQPreset(
                    name: name,
                    preampDB: parsed.preampDB,
                    bands: parsed.bands,
                    bandMode: .parametric,
                    isBuiltIn: true,
                    isHeadphone: true,
                    source: "AutoEQ · offline"
                )
            )
        }
        bundledHeadphones = loaded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func loadImported() {
        guard let data = defaults.data(forKey: importedKey),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data)
        else { return }
        imported = presets
        for p in presets {
            presetCache[p.name.lowercased()] = p
        }
    }

    private func saveImported() {
        if let data = try? JSONEncoder().encode(imported) {
            defaults.set(data, forKey: importedKey)
        }
    }

    private func loadUserPresets() {
        let preferences = AppPreferences.load(from: defaults)
        guard let data = defaults.data(forKey: userPresetsKey),
              let stored = try? JSONDecoder().decode([UserPreset].self, from: data)
        else {
            userPresets = []
            return
        }

        let mirroredFavorites = Set(preferences.favoritePresetIDs)
        var seenIDs = Set<UUID>()
        userPresets = stored.compactMap { record in
            guard seenIDs.insert(record.id).inserted else { return nil }
            var migrated = record
            migrated.preset.isBuiltIn = false
            if mirroredFavorites.contains(migrated.id) {
                migrated.isFavorite = true
            }
            return migrated
        }
    }

    private func saveUserPresets() {
        if let data = try? JSONEncoder().encode(userPresets) {
            defaults.set(data, forKey: userPresetsKey)
        }
        syncStoreStateToPreferences()
    }

    private func loadHeadphoneLibrary() {
        let preferences = AppPreferences.load(from: defaults)
        let state: HeadphoneLibraryState
        if let data = defaults.data(forKey: headphoneLibraryKey),
           let decoded = try? JSONDecoder().decode(HeadphoneLibraryState.self, from: data) {
            state = decoded
        } else {
            var recents = preferences.recentHeadphoneNames
            if recents.isEmpty, let lastHeadphoneName = preferences.lastHeadphoneName {
                recents = [lastHeadphoneName]
            }
            state = HeadphoneLibraryState(
                favoriteNames: preferences.favoriteHeadphoneNames,
                recentNames: recents
            )
        }
        favoriteHeadphoneNames = canonicalizedCatalogNames(state.favoriteNames)
        recentHeadphoneNames = Array(
            canonicalizedCatalogNames(state.recentNames).prefix(maximumRecentHeadphones)
        )
    }

    private func saveHeadphoneLibrary() {
        let state = HeadphoneLibraryState(
            favoriteNames: favoriteHeadphoneNames,
            recentNames: recentHeadphoneNames
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: headphoneLibraryKey)
        }
        syncStoreStateToPreferences()
    }

    private func canonicalizedCatalogNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { rawName in
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = catalogEntry(named: trimmed)?.name ?? trimmed
            let key = Self.catalogIdentityKey(name)
            guard seen.insert(key).inserted else { return nil }
            return name
        }
    }

    private func loadDeviceProfiles() {
        let preferences = AppPreferences.load(from: defaults)
        var loaded: [DeviceProfile] = []
        if let data = defaults.data(forKey: deviceProfilesKey) {
            if let profiles = try? JSONDecoder().decode([DeviceProfile].self, from: data) {
                loaded = profiles
            } else if let legacyMap = try? JSONDecoder().decode([String: EQPreset].self, from: data) {
                loaded = legacyMap.map { deviceUID, preset in
                    DeviceProfile(
                        deviceUID: deviceUID,
                        deviceName: deviceUID,
                        preset: preset,
                        eqEnabled: true,
                        updatedAt: Date(timeIntervalSince1970: 0)
                    )
                }
            }
        } else {
            loaded = preferences.deviceProfiles
        }

        var seen = Set<String>()
        deviceProfiles = loaded.compactMap { profile in
            let uid = profile.deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { return nil }
            var migrated = profile
            migrated.deviceUID = uid
            if migrated.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                migrated.deviceName = uid
            }
            return migrated
        }
    }

    private func saveDeviceProfiles() {
        if let data = try? JSONEncoder().encode(deviceProfiles) {
            defaults.set(data, forKey: deviceProfilesKey)
        }
        syncStoreStateToPreferences()
    }

    /// Keep expanded AppPreferences useful to callers while the dedicated keys
    /// remain authoritative and immune to older EQViewModel save code.
    private func syncStoreStateToPreferences() {
        var preferences = AppPreferences.load(from: defaults)
        preferences.favoritePresetIDs = userPresets.filter(\.isFavorite).map(\.id)
        preferences.favoriteHeadphoneNames = favoriteHeadphoneNames
        preferences.recentHeadphoneNames = recentHeadphoneNames
        preferences.deviceProfiles = deviceProfiles
        preferences.save(to: defaults)
    }
}
