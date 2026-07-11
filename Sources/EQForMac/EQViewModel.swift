import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Shared state driving the menu-bar popover UI and audio engine.
@available(macOS 14.2, *)
@MainActor
final class EQViewModel: ObservableObject {
    @Published var eqEnabled: Bool = false {
        didSet {
            guard !isRestoring else { return }
            audioEngine.setEnabled(eqEnabled)
            if eqEnabled && audioEngine.isRunning {
                permission.markEngineSucceeded()
            } else if eqEnabled {
                // Re-check after start attempt
                permission.refresh()
                if audioEngine.isRunning {
                    permission.markEngineSucceeded()
                }
            }
            persist()
            refreshIcon?()
        }
    }

    @Published var bandMode: EQBandMode = .ten {
        didSet {
            guard !isRestoring else { return }
            rebuildGraphicBandsKeepingGains()
            pushToEngine()
            persist()
        }
    }

    /// Gains for the current graphic mode (length matches bandMode.frequencies).
    @Published var gains: [Float] = Array(repeating: 0, count: 10) {
        didSet {
            guard !isRestoring, !isApplyingPreset else { return }
            // Manual fader move → graphic EQ, leave parametric headphone mode.
            activeParametricBands = nil
            selectedPresetName = "Custom"
            selectedHeadphoneName = nil
            pushToEngine()
            persist()
        }
    }

    @Published var preampDB: Float = 0 {
        didSet {
            guard !isRestoring, !isApplyingPreset else { return }
            // If still in parametric mode, only preamp changes; keep bands.
            // If graphic mode, rebuild from gains + preamp.
            pushToEngine()
            persist()
        }
    }

    @Published var selectedPresetName: String = "Flat"
    @Published var selectedHeadphoneName: String?
    @Published var headphoneSearch: String = ""
    @Published var statusText: String = ""
    @Published var isLoadingHeadphone = false
    @Published var headphoneLoadError: String?
    @Published var catalogNotice: String?

    let audioEngine: AudioEngine
    let presetStore: PresetStore
    let permission = PermissionMonitor.shared

    var refreshIcon: (() -> Void)?

    private var isRestoring = false
    private var isApplyingPreset = false
    /// When a parametric headphone preset is active, keep full bands here.
    private var activeParametricBands: [EQBand]?
    private var activePreampFromPreset: Float = 0

    init(audioEngine: AudioEngine, presetStore: PresetStore) {
        self.audioEngine = audioEngine
        self.presetStore = presetStore
        restore()
        updateStatus()
        permission.refresh()
        audioEngine.onStateChange = { [weak self] in
            Task { @MainActor in
                self?.updateStatus()
                self?.refreshIcon?()
            }
        }
    }

    var frequencies: [Float] { bandMode.frequencies }

    /// Show permission UI only when the monitor says so.
    var permissionHint: Bool { permission.shouldShowBanner }

    /// Full PEQdB graph list search (~4,700 names).
    var catalogResults: [HeadphoneCatalogEntry] {
        presetStore.searchCatalog(headphoneSearch, limit: headphoneSearch.isEmpty ? 400 : 800)
    }

    var frequencyLabels: [String] {
        frequencies.map { f in
            if f >= 1000 {
                let k = f / 1000
                return k == floor(k) ? "\(Int(k))k" : String(format: "%.1fk", k)
            }
            return "\(Int(f))"
        }
    }

    // MARK: - Actions

    func toggleEQ() {
        eqEnabled.toggle()
    }

    func applyBuiltInPreset(_ preset: EQPreset) {
        isApplyingPreset = true
        defer { isApplyingPreset = false }

        selectedPresetName = preset.name
        selectedHeadphoneName = nil
        activeParametricBands = nil

        if preset.bandMode == .parametric || preset.isHeadphone {
            // Map parametric into current graphic mode for slider display (approx)
            // but apply full parametric to engine.
            activeParametricBands = preset.bands
            activePreampFromPreset = preset.preampDB
            preampDB = preset.preampDB
            // Approximate graphic gains for display (nearest band)
            gains = approximateGains(from: preset.bands, mode: bandMode)
        } else {
            bandMode = preset.bandMode == .fifteen ? .fifteen : .ten
            let needed = bandMode.frequencies.count
            var g = preset.bands.map(\.gain)
            if g.count < needed {
                g.append(contentsOf: Array(repeating: Float(0), count: needed - g.count))
            } else if g.count > needed {
                g = Array(g.prefix(needed))
            }
            gains = g
            preampDB = preset.preampDB
            activePreampFromPreset = preset.preampDB
        }

        pushToEngine()
        persist()
        updateStatus()
    }

    func applyHeadphone(_ preset: EQPreset) {
        isApplyingPreset = true
        defer { isApplyingPreset = false }

        selectedHeadphoneName = preset.name
        selectedPresetName = preset.name
        activeParametricBands = preset.bands
        activePreampFromPreset = preset.preampDB
        preampDB = preset.preampDB
        gains = approximateGains(from: preset.bands, mode: bandMode)
        headphoneLoadError = nil

        if !eqEnabled {
            eqEnabled = true
        } else {
            pushToEngine()
        }
        persist()
        updateStatus()
    }

    /// Load EQ from the full AutoEQ catalog (downloads + caches on first use).
    func applyCatalogEntry(_ entry: HeadphoneCatalogEntry) {
        if entry.isTargetCurve {
            headphoneLoadError = nil
            catalogNotice = "\(entry.name) is a reference target, not a standalone EQ. Use it with a compatible headphone measurement in PEQdB Studio."
            statusText = "Reference target · \(entry.name)"
            return
        }

        isLoadingHeadphone = true
        headphoneLoadError = nil
        catalogNotice = nil
        statusText = "Loading \(entry.name)…"

        Task { @MainActor in
            do {
                let preset = try await presetStore.loadPreset(for: entry)
                applyHeadphone(preset)
                isLoadingHeadphone = false
                statusText = "EQ on · \(preset.name) · \(audioEngine.outputDeviceName)"
            } catch {
                isLoadingHeadphone = false
                headphoneLoadError = error.localizedDescription
                statusText = error.localizedDescription
            }
        }
    }

    func resetFlat() {
        applyBuiltInPreset(.flat(mode: bandMode))
    }

    func importEQFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "txt") ?? .plainText,
            .plainText,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import Equalizer APO / AutoEQ / PEQdB filter file"
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preset = try presetStore.importFile(at: url)
            applyHeadphone(preset)
            statusText = "Imported \(preset.name)"
        } catch {
            statusText = error.localizedDescription
            presentAlert(title: "Import failed", message: error.localizedDescription)
        }
    }

    func requestPermissionIfNeeded() {
        permission.refresh()
        if !permission.isGranted {
            permission.requestAccess()
        }
    }

    func openPermissionSettings() {
        permission.openSystemSettings()
    }

    func dismissPermissionBanner() {
        permission.userConfirmedGranted()
    }

    func refreshPermission() {
        permission.refresh()
        updateStatus()
    }

    // MARK: - Engine bridge

    private func currentPresetForEngine() -> EQPreset {
        if let parametric = activeParametricBands {
            return EQPreset(
                name: selectedPresetName,
                preampDB: preampDB,
                bands: parametric,
                bandMode: .parametric,
                isHeadphone: selectedHeadphoneName != nil
            )
        }

        let bands = zip(frequencies, gains).map { f, g in
            EQBand(
                filterType: .parametric,
                frequency: f,
                gain: g,
                bandwidth: bandMode.defaultBandwidth,
                enabled: true
            )
        }
        return EQPreset(
            name: selectedPresetName,
            preampDB: preampDB,
            bands: bands,
            bandMode: bandMode
        )
    }

    private func pushToEngine() {
        audioEngine.apply(preset: currentPresetForEngine())
    }

    private func rebuildGraphicBandsKeepingGains() {
        let count = bandMode.frequencies.count
        if gains.count < count {
            gains.append(contentsOf: Array(repeating: 0, count: count - gains.count))
        } else if gains.count > count {
            gains = Array(gains.prefix(count))
        }
        // Leaving parametric headphone mode when user switches band mode manually
        // keeps approximate gains as graphic EQ.
        if activeParametricBands != nil {
            activeParametricBands = nil
            selectedHeadphoneName = nil
            if selectedPresetName != "Custom" {
                selectedPresetName = "Custom"
            }
        }
    }

    /// Rough mapping of parametric filters → graphic sliders for display only.
    private func approximateGains(from bands: [EQBand], mode: EQBandMode) -> [Float] {
        let centers = mode.frequencies
        var result = Array(repeating: Float(0), count: centers.count)
        for (i, center) in centers.enumerated() {
            var sum: Float = 0
            var weight: Float = 0
            for band in bands where band.enabled {
                let ratio = abs(log2(max(20, band.frequency) / center))
                let w = max(0, 1 - ratio) // influence falls with octave distance
                sum += band.gain * w
                weight += w
            }
            result[i] = weight > 0 ? max(-12, min(12, sum / weight)) : 0
        }
        return result
    }

    // MARK: - Persistence

    private func restore() {
        isRestoring = true
        defer { isRestoring = false }

        let prefs = AppPreferences.load()
        bandMode = prefs.bandMode
        let count = bandMode.frequencies.count
        var g = prefs.customGains
        if g.count < count {
            g.append(contentsOf: Array(repeating: 0, count: count - g.count))
        }
        gains = Array(g.prefix(count))
        preampDB = prefs.preampDB
        selectedPresetName = prefs.selectedPresetName

        if let headphone = prefs.lastHeadphoneName,
           let preset = presetStore.headphone(named: headphone)
            ?? presetStore.imported.first(where: { $0.name == headphone }) {
            selectedHeadphoneName = headphone
            activeParametricBands = preset.bands
            activePreampFromPreset = preset.preampDB
            preampDB = preset.preampDB
            gains = approximateGains(from: preset.bands, mode: bandMode)
        }

        // Don't auto-start EQ on launch — user toggles on/off.
        eqEnabled = false
        if prefs.eqEnabled {
            // Restore previous intent: start after a short delay so permission UI can show.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.eqEnabled = true
            }
        }
    }

    private func persist() {
        var prefs = AppPreferences()
        prefs.eqEnabled = eqEnabled
        prefs.bandMode = bandMode
        var g = gains
        while g.count < 15 { g.append(0) }
        prefs.customGains = Array(g.prefix(15))
        prefs.preampDB = preampDB
        prefs.selectedPresetName = selectedPresetName
        prefs.lastHeadphoneName = selectedHeadphoneName
        prefs.save()
    }

    private func updateStatus() {
        if audioEngine.isRunning {
            permission.markEngineSucceeded()
        }
        if let err = audioEngine.errorMessage {
            statusText = err
            return
        }
        if eqEnabled && audioEngine.isRunning {
            let name = selectedHeadphoneName ?? selectedPresetName
            statusText = "EQ on · \(name) · \(audioEngine.outputDeviceName)"
        } else if eqEnabled && !audioEngine.isRunning {
            statusText = "Starting…"
        } else {
            statusText = "EQ off · \(audioEngine.outputDeviceName)"
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
