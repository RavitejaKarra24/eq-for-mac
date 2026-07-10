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

    init(
        name: String,
        path: String? = nil,
        source: String? = nil,
        hasEQ: Bool = false,
        autoeqName: String? = nil,
        file: String? = nil
    ) {
        self.name = name
        self.path = path
        self.source = source
        self.hasEQ = hasEQ
        self.autoeqName = autoeqName
        self.file = file
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

// MARK: - Preset store (fully offline)

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var bundledHeadphones: [EQPreset] = []
    @Published private(set) var imported: [EQPreset] = []
    @Published private(set) var catalog: [HeadphoneCatalogEntry] = []
    @Published private(set) var catalogCount: Int = 0
    @Published private(set) var withEQCount: Int = 0
    @Published private(set) var isLoadingRemote = false
    @Published private(set) var lastLoadError: String?

    private let importedKey = "EQForMac.importedPresets"
    private var presetCache: [String: EQPreset] = [:]

    init() {
        loadCatalog()
        loadBundledHeadphones()
        loadImported()
        for preset in bundledHeadphones {
            presetCache[preset.name.lowercased()] = preset
        }
    }

    var builtIn: [EQPreset] { EQPreset.builtInPresets }
    var headphones: [EQPreset] { bundledHeadphones }

    // MARK: - Search

    func searchCatalog(_ query: String, limit: Int = 800) -> [HeadphoneCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return catalog.count <= limit ? catalog : Array(catalog.prefix(limit))
        }

        let lower = q.lowercased()
        var prefix: [HeadphoneCatalogEntry] = []
        var contains: [HeadphoneCatalogEntry] = []
        for entry in catalog {
            let name = entry.name.lowercased()
            if name.hasPrefix(lower) {
                prefix.append(entry)
            } else if name.contains(lower) {
                contains.append(entry)
            }
            if prefix.count + contains.count >= limit * 2 { break }
        }
        let merged = prefix + contains
        let ranked = merged.sorted { a, b in
            if a.hasEQ != b.hasEQ { return a.hasEQ && !b.hasEQ }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }

    func catalogEntry(named name: String) -> HeadphoneCatalogEntry? {
        let key = name.lowercased()
        return catalog.first { $0.name.lowercased() == key }
    }

    func headphone(named name: String) -> EQPreset? {
        if let cached = presetCache[name.lowercased()] { return cached }
        return bundledHeadphones.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? imported.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Load EQ (offline only)

    func loadPreset(for entry: HeadphoneCatalogEntry) async throws -> EQPreset {
        let cacheKey = entry.name.lowercased()
        if let cached = presetCache[cacheKey] {
            return cached
        }

        // Bundled popular presets by name
        if let bundled = bundledHeadphones.first(where: {
            $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
                || (entry.autoeqName != nil
                    && $0.name.caseInsensitiveCompare(entry.autoeqName!) == .orderedSame)
        }) {
            presetCache[cacheKey] = bundled
            return bundled
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
        imported.removeAll { $0.name == preset.name }
        imported.append(preset)
        imported.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        presetCache[name.lowercased()] = preset
        saveImported()
        return preset
    }

    func removeImported(_ preset: EQPreset) {
        imported.removeAll { $0.id == preset.id }
        saveImported()
    }

    // MARK: - Catalog

    private func loadCatalog() {
        if let data = loadResourceData(name: "headphones_catalog", ext: "json"),
           let file = try? JSONDecoder().decode(HeadphonesCatalogFile.self, from: data) {
            applyCatalogFile(file)
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

    private func resolveAutoEQFile(_ fileName: String) -> URL? {
        // Bundle.module: Resources/autoeq/<file>
        if let url = Bundle.module.url(forResource: fileName.replacingOccurrences(of: ".txt", with: ""),
                                       withExtension: "txt",
                                       subdirectory: "autoeq") {
            return url
        }
        if let root = Bundle.module.resourceURL?
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
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
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

        if let resourceURL = Bundle.module.resourceURL {
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
        guard let data = UserDefaults.standard.data(forKey: importedKey),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data)
        else { return }
        imported = presets
        for p in presets {
            presetCache[p.name.lowercased()] = p
        }
    }

    private func saveImported() {
        if let data = try? JSONEncoder().encode(imported) {
            UserDefaults.standard.set(data, forKey: importedKey)
        }
    }
}
