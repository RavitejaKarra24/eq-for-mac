import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Shared state driving the menu-bar UI, persistence, and audio engine.
@available(macOS 14.2, *)
@MainActor
final class EQViewModel: ObservableObject {
    @Published var eqEnabled = false {
        didSet {
            guard !isRestoring else { return }
            if !eqEnabled {
                endDryComparison()
            }
            audioEngine.setEnabled(eqEnabled)
            if eqEnabled, audioEngine.isRunning {
                permission.markEngineSucceeded()
            } else if eqEnabled {
                lastHandledEngineError = audioEngine.errorMessage
                permission.invalidateEngineProof()
            }
            persist()
            updateStatus()
            refreshIcon?()
        }
    }

    /// One stable 10-band overview; imported presets remain fully parametric.
    let bandMode: EQBandMode = .ten

    /// Graphic-band display values. A parametric preset remains stored in full;
    /// these values are only its projection onto the selected ISO centers.
    @Published private(set) var gains: [Float] = Array(repeating: 0, count: 10)
    @Published private(set) var preampDB: Float = 0
    @Published private(set) var recommendedPreampDB: Float = 0
    @Published private(set) var isBypassed = false
    @Published private(set) var isComparing = false
    @Published private(set) var autoPreampEnabled = false

    @Published private(set) var launchAtLogin = false
    @Published private(set) var hotKeyEnabled = false
    @Published private(set) var crossfeedEnabled = false
    @Published private(set) var crossfeedAmount: Float = 0.25
    @Published private(set) var loginItemNotice: String?
    @Published var systemFeatureError: String?

    @Published private(set) var selectedPresetName = "Flat"
    @Published private(set) var selectedUserPresetID: UUID?
    @Published private(set) var selectedHeadphoneName: String?
    @Published var headphoneSearch = "" {
        didSet { refreshCatalogResults() }
    }
    @Published private(set) var catalogResults: [HeadphoneCatalogEntry] = []
    @Published var statusText = ""
    @Published var isLoadingHeadphone = false
    @Published var headphoneLoadError: String?
    @Published var catalogNotice: String?
    @Published var showPermissionOnboarding = false

    let audioEngine: AudioEngine
    let presetStore: PresetStore
    let permission = PermissionMonitor.shared

    var refreshIcon: (() -> Void)?

    private let hotKeyManager = HotKeyManager()
    private let onboardingKey = "EQForMac.permissionOnboardingCompleted"
    private var isRestoring = false
    private var isApplyingPreset = false
    private var isApplyingDeviceProfile = false
    private var activeParametricBands: [EQBand]?
    private var graphicGainsByMode: [EQBandMode: [Float]] = [:]
    private var bypassBeforeComparison = false
    private var lastOutputDeviceUID: String?
    private var lastHandledEngineError: String?
    private var preferences = AppPreferences()
    private var persistWorkItem: DispatchWorkItem?

    init(audioEngine: AudioEngine, presetStore: PresetStore) {
        self.audioEngine = audioEngine
        self.presetStore = presetStore

        restore()
        configureSystemFeatures()
        audioEngine.setCrossfeedIntensity(crossfeedEnabled ? crossfeedAmount : 0)
        pushToEngine()
        refreshCatalogResults()
        updateStatus()
        permission.refresh()

        audioEngine.onStateChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.audioEngine.isRunning {
                    self.lastHandledEngineError = nil
                } else if let error = self.audioEngine.errorMessage,
                          error != self.lastHandledEngineError {
                    self.lastHandledEngineError = error
                    self.permission.invalidateEngineProof()
                }
                self.updateStatus()
                self.refreshIcon?()
            }
        }
        audioEngine.onOutputDeviceChange = { [weak self] uid, name in
            Task { @MainActor in
                self?.handleOutputDeviceChange(uid: uid, name: name)
            }
        }
        if let uid = audioEngine.outputDeviceUID,
           let profile = presetStore.deviceProfile(for: uid) {
            applyPreset(
                profile.preset,
                headphoneName: profile.preset.isHeadphone ? profile.preset.name : nil
            )
            eqEnabled = profile.eqEnabled
        }
        lastOutputDeviceUID = audioEngine.outputDeviceUID

        if eqEnabled {
            audioEngine.setEnabled(true)
        }

        if permission.shouldShowBanner,
           !UserDefaults.standard.bool(forKey: onboardingKey) {
            showPermissionOnboarding = true
        }
    }

    var frequencies: [Float] { bandMode.frequencies }
    var permissionHint: Bool { permission.shouldShowBanner }
    var hasParametricFilters: Bool { activeParametricBands != nil }
    /// A level-matched dry comparison intentionally keeps the preamp, so only
    /// filters and crossfeed can create an audible A/B difference.
    var hasDryComparisonDifference: Bool {
        currentPresetSnapshot().changesFrequencyResponse
            || (crossfeedEnabled && crossfeedAmount >= 0.000_01)
    }
    var hasUserOverlays: Bool {
        activeParametricBands?.contains(where: \.isUserOverlay) == true
    }
    var spectrumMagnitudes: [Float] { audioEngine.spectrumMagnitudes }
    var responseFrequencies: [Float] {
        EQResponse.logarithmicFrequencies(count: 192)
    }
    var responseGains: [Float] {
        let bands = currentPresetSnapshot().bands
        return responseFrequencies.map {
            EQResponse.magnitudeDB(bands: bands, at: Double($0))
        }
    }
    var editorBands: [EQBand] {
        activeParametricBands ?? zip(frequencies, gains).map {
            EQBand(
                frequency: $0.0,
                gain: $0.1,
                bandwidth: bandMode.defaultBandwidth
            )
        }
    }
    var editorGains: [Float] { editorBands.map(\.gain) }
    var editorFrequencies: [Float] { editorBands.map(\.frequency) }

    var frequencyLabels: [String] {
        frequencies.map(Self.frequencyLabel)
    }

    var hasProfileForCurrentDevice: Bool {
        guard let uid = audioEngine.outputDeviceUID else { return false }
        return presetStore.deviceProfile(for: uid) != nil
    }

    // MARK: - Main actions

    func toggleEQ() {
        eqEnabled.toggle()
    }

    func toggleBypass() {
        if isComparing {
            endDryComparison()
        } else {
            setBypassed(!isBypassed)
        }
    }

    func setBypassed(_ bypassed: Bool) {
        guard isBypassed != bypassed else { return }
        isBypassed = bypassed
        audioEngine.bypassed = bypassed
        updateStatus()
        refreshIcon?()
    }

    func beginDryComparison() {
        guard !isComparing,
              eqEnabled,
              !isBypassed,
              hasDryComparisonDifference
        else { return }
        bypassBeforeComparison = isBypassed
        isComparing = true
        setBypassed(true)
    }

    func endDryComparison() {
        guard isComparing else { return }
        isComparing = false
        setBypassed(bypassBeforeComparison)
    }

    func setSpectrumVisible(_ visible: Bool) {
        audioEngine.setSpectrumMonitoringEnabled(visible && !permission.shouldShowBanner)
    }

    func setGain(_ gain: Float, at index: Int) {
        guard gains.indices.contains(index), frequencies.indices.contains(index) else { return }
        let clamped = min(12, max(-12, abs(gain) < 0.25 ? 0 : gain))

        if var parametric = activeParametricBands {
            let target = frequencies[index]
            let responseDelta = clamped - gains[index]
            guard abs(responseDelta) >= 0.01 else { return }
            if let overlay = parametric.firstIndex(where: {
                $0.isUserOverlay && abs(log2(max(20, $0.frequency) / target)) < 0.01
            }) {
                parametric[overlay].gain = min(
                    24,
                    max(-24, parametric[overlay].gain + responseDelta)
                )
            } else {
                parametric.append(
                    EQBand(
                        frequency: target,
                        gain: responseDelta,
                        bandwidth: bandMode.defaultBandwidth,
                        isUserOverlay: true
                    )
                )
            }
            activeParametricBands = parametric
            selectedPresetName = "Custom"
            selectedUserPresetID = nil
            selectedHeadphoneName = nil
            isApplyingPreset = true
            gains = Self.approximateGains(from: parametric, mode: bandMode)
            isApplyingPreset = false
            finishFilterMutation()
            return
        }

        var copy = gains
        copy[index] = clamped
        gains = copy
        selectedPresetName = "Custom"
        selectedUserPresetID = nil
        selectedHeadphoneName = nil
        finishFilterMutation()
    }

    func resetBand(at index: Int) {
        setGain(0, at: index)
    }

    func setEditorBand(at index: Int, frequency: Float, gain: Float) {
        guard var bands = activeParametricBands, bands.indices.contains(index) else {
            setGain(gain, at: index)
            return
        }
        bands[index].frequency = min(20_000, max(20, frequency))
        bands[index].gain = min(24, max(-24, gain))
        activeParametricBands = bands
        markParametricEdit()
    }

    func addEditorBand(frequency: Float, gain: Float) {
        guard var bands = activeParametricBands else { return }
        bands.append(
            EQBand(
                frequency: min(20_000, max(20, frequency)),
                gain: min(24, max(-24, gain)),
                bandwidth: 1
            )
        )
        activeParametricBands = bands
        markParametricEdit()
    }

    func deleteEditorBand(at index: Int) {
        guard var bands = activeParametricBands, bands.indices.contains(index) else {
            return
        }
        bands.remove(at: index)
        activeParametricBands = bands
        markParametricEdit()
    }

    func setEditorBandType(_ type: EQFilterType, at index: Int) {
        guard var bands = activeParametricBands, bands.indices.contains(index) else {
            return
        }
        bands[index].filterType = type
        activeParametricBands = bands
        markParametricEdit()
    }

    func setEditorBandwidth(_ bandwidth: Float, at index: Int) {
        guard var bands = activeParametricBands, bands.indices.contains(index) else {
            return
        }
        bands[index].bandwidth = max(0.000_001, bandwidth)
        activeParametricBands = bands
        markParametricEdit()
    }

    func revertToSourceCurve() {
        guard var bands = activeParametricBands else { return }
        bands.removeAll(where: \.isUserOverlay)
        activeParametricBands = bands
        gains = Self.approximateGains(from: bands, mode: bandMode)
        selectedPresetName = selectedHeadphoneName ?? selectedPresetName
        finishFilterMutation()
    }

    func copyFiltersToPasteboard() {
        let text = EqualizerAPOExporter.export(currentPresetSnapshot())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        catalogNotice = "Copied \(currentPresetSnapshot().bands.filter(\.enabled).count) filters."
    }

    func flushPreferences() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        preferences.save()
    }

    private func markParametricEdit() {
        guard let bands = activeParametricBands else { return }
        gains = Self.approximateGains(from: bands, mode: bandMode)
        selectedPresetName = "Custom"
        selectedUserPresetID = nil
        finishFilterMutation()
    }

    func setPreampDB(_ value: Float) {
        if autoPreampEnabled {
            autoPreampEnabled = false
        }
        assignPreamp(min(6, max(-24, value)))
        persist()
    }

    func adjustPreamp(by delta: Float) {
        let stepped = ((preampDB + delta) * 2).rounded() / 2
        setPreampDB(stepped)
    }

    func setAutoPreampEnabled(_ enabled: Bool) {
        autoPreampEnabled = enabled
        refreshHeadroom(applyIfEnabled: enabled)
        pushToEngine()
        updateStatus()
        persist()
    }

    func matchRecommendedPreamp() {
        assignPreamp(recommendedPreampDB)
        persist()
    }

    func applyBuiltInPreset(_ preset: EQPreset) {
        applyPreset(preset, headphoneName: nil)
    }

    func applyUserPreset(_ userPreset: UserPreset) {
        // A saved headphone-derived curve belongs to the user's preset
        // library; keep that identity distinct from a catalog selection.
        applyPreset(
            userPreset.preset,
            headphoneName: nil,
            userPresetID: userPreset.id
        )
    }

    func applyHeadphone(_ preset: EQPreset) {
        applyPreset(preset, headphoneName: preset.name)
        presetStore.recordRecentHeadphone(named: preset.name)
        refreshCatalogResults()
        if !eqEnabled {
            eqEnabled = true
        }
    }

    func applyCatalogEntry(_ entry: HeadphoneCatalogEntry) {
        if entry.isTargetCurve {
            headphoneLoadError = nil
            catalogNotice = """
            \(entry.name) is reference-target metadata, not a standalone EQ. \
            Pair it with compatible measurement data before applying it.
            """
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
                updateStatus()
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

    // MARK: - Preset library

    @discardableResult
    func saveCurrentPreset(named name: String) -> Bool {
        do {
            let saved = try presetStore.saveUserPreset(currentPresetSnapshot(), named: name)
            selectedPresetName = saved.name
            selectedUserPresetID = saved.id
            selectedHeadphoneName = nil
            objectWillChange.send()
            persist()
            systemFeatureError = nil
            return true
        } catch {
            systemFeatureError = "Couldn’t save preset: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func renameUserPreset(_ userPreset: UserPreset, to name: String) -> Bool {
        do {
            let renamed = try presetStore.renameUserPreset(id: userPreset.id, to: name)
            if selectedUserPresetID == userPreset.id {
                selectedPresetName = renamed.name
            }
            objectWillChange.send()
            persist()
            systemFeatureError = nil
            return true
        } catch {
            systemFeatureError = "Couldn’t rename preset: \(error.localizedDescription)"
            return false
        }
    }

    func deleteUserPreset(_ userPreset: UserPreset) {
        _ = presetStore.deleteUserPreset(id: userPreset.id)
        if selectedUserPresetID == userPreset.id {
            selectedPresetName = "Custom"
            selectedUserPresetID = nil
        }
        objectWillChange.send()
        persist()
    }

    func toggleFavorite(_ userPreset: UserPreset) {
        _ = presetStore.toggleUserPresetFavorite(id: userPreset.id)
        objectWillChange.send()
    }

    func moveUserPreset(_ userPreset: UserPreset, by offset: Int) {
        guard let index = presetStore.userPresets.firstIndex(where: { $0.id == userPreset.id })
        else { return }
        if presetStore.moveUserPreset(id: userPreset.id, to: index + offset) {
            objectWillChange.send()
            persist()
        }
    }

    func toggleFavorite(_ entry: HeadphoneCatalogEntry) {
        _ = presetStore.toggleHeadphoneFavorite(named: entry.name)
        refreshCatalogResults()
        objectWillChange.send()
    }

    func isFavorite(_ entry: HeadphoneCatalogEntry) -> Bool {
        presetStore.isHeadphoneFavorite(named: entry.name)
    }

    // MARK: - Import

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
            updateStatus()
        } catch {
            statusText = error.localizedDescription
            headphoneLoadError = error.localizedDescription
        }
    }

    // MARK: - Device profiles

    func rememberCurrentDeviceProfile() {
        guard let uid = audioEngine.outputDeviceUID, !uid.isEmpty else {
            systemFeatureError = "The current output device does not expose a stable identifier."
            return
        }
        do {
            _ = try presetStore.saveDeviceProfile(
                deviceUID: uid,
                deviceName: audioEngine.outputDeviceName,
                preset: currentPresetSnapshot(),
                eqEnabled: eqEnabled
            )
            systemFeatureError = nil
            objectWillChange.send()
            persist()
        } catch {
            systemFeatureError = error.localizedDescription
        }
    }

    func forgetCurrentDeviceProfile() {
        guard let uid = audioEngine.outputDeviceUID else { return }
        _ = presetStore.deleteDeviceProfile(for: uid)
        objectWillChange.send()
        persist()
    }

    private func handleOutputDeviceChange(uid: String, name _: String) {
        guard lastOutputDeviceUID != uid else {
            updateStatus()
            return
        }
        lastOutputDeviceUID = uid
        guard !isApplyingDeviceProfile,
              let profile = presetStore.deviceProfile(for: uid)
        else {
            updateStatus()
            return
        }

        isApplyingDeviceProfile = true
        applyPreset(
            profile.preset,
            headphoneName: profile.preset.isHeadphone ? profile.preset.name : nil
        )
        if eqEnabled != profile.eqEnabled {
            eqEnabled = profile.eqEnabled
        }
        isApplyingDeviceProfile = false
        updateStatus()
    }

    // MARK: - System features and spatial controls

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.shared.setEnabled(enabled)
            refreshSystemFeatureStatus()
            systemFeatureError = nil
            persist()
        } catch {
            launchAtLogin = LoginItem.shared.isRegistered
            systemFeatureError = error.localizedDescription
        }
    }

    func refreshSystemFeatureStatus() {
        launchAtLogin = LoginItem.shared.isRegistered
        loginItemNotice = LoginItem.shared.status == .requiresApproval
            ? """
              Launch at login is waiting for approval in System Settings → \
              General → Login Items.
              """
            : nil
    }

    func setHotKeyEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try hotKeyManager.start(shortcut: .defaultToggleEQ) { [weak self] in
                    self?.toggleEQ()
                }
                hotKeyEnabled = true
                systemFeatureError = nil
            } catch {
                hotKeyEnabled = false
                systemFeatureError = error.localizedDescription
            }
        } else {
            hotKeyManager.stop()
            hotKeyEnabled = false
        }
        persist()
    }

    func setCrossfeedEnabled(_ enabled: Bool) {
        crossfeedEnabled = enabled
        audioEngine.setCrossfeedIntensity(enabled ? crossfeedAmount : 0)
        persist()
    }

    func setCrossfeedAmount(_ amount: Float) {
        crossfeedAmount = min(1, max(0, amount))
        audioEngine.setCrossfeedIntensity(crossfeedEnabled ? crossfeedAmount : 0)
        persist()
    }

    // MARK: - Permission

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

    func completePermissionOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        showPermissionOnboarding = false
        permission.userConfirmedGranted()
    }

    func refreshPermission() {
        permission.refresh()
        if permission.isGranted {
            UserDefaults.standard.set(true, forKey: onboardingKey)
        }
        updateStatus()
    }

    // MARK: - Engine bridge

    func currentPresetSnapshot() -> EQPreset {
        if let parametric = activeParametricBands {
            return EQPreset(
                name: selectedPresetName,
                preampDB: preampDB,
                bands: parametric,
                bandMode: .parametric,
                isHeadphone: selectedHeadphoneName != nil,
                source: "EQ for Mac"
            )
        }

        let bands = zip(frequencies, gains).map { frequency, gain in
            EQBand(
                frequency: frequency,
                gain: gain,
                bandwidth: bandMode.defaultBandwidth
            )
        }
        return EQPreset(
            name: selectedPresetName,
            preampDB: preampDB,
            bands: bands,
            bandMode: bandMode,
            source: "EQ for Mac"
        )
    }

    private func pushToEngine() {
        audioEngine.apply(preset: currentPresetSnapshot())
    }

    private func applyPreset(
        _ preset: EQPreset,
        headphoneName: String?,
        userPresetID: UUID? = nil
    ) {
        isApplyingPreset = true
        selectedPresetName = preset.name
        selectedUserPresetID = userPresetID
        selectedHeadphoneName = headphoneName

        if preset.bandMode == .parametric || preset.isHeadphone {
            activeParametricBands = preset.bands
            preampDB = min(6, max(-24, preset.preampDB))
            gains = Self.approximateGains(from: preset.bands, mode: bandMode)
        } else {
            activeParametricBands = nil
            gains = preset.bandMode == .fifteen
                ? Self.resampleGraphicGains(
                    preset.bands.map(\.gain),
                    from: EQBandMode.fifteen.frequencies,
                    to: frequencies
                )
                : normalizedGains(
                    preset.bands.map(\.gain),
                    count: frequencies.count
                )
            graphicGainsByMode[bandMode] = gains
            preampDB = min(6, max(-24, preset.preampDB))
        }
        isApplyingPreset = false

        refreshHeadroom(applyIfEnabled: true)
        pushToEngine()
        persist()
        updateStatus()
    }

    private func finishFilterMutation() {
        if activeParametricBands == nil {
            graphicGainsByMode[bandMode] = gains
        }
        refreshHeadroom(applyIfEnabled: true)
        pushToEngine()
        persist()
        updateStatus()
    }

    private func assignPreamp(_ value: Float) {
        preampDB = min(6, max(-24, value))
        pushToEngine()
        updateStatus()
    }

    private func refreshHeadroom(applyIfEnabled: Bool) {
        let bands = activeParametricBands ?? zip(frequencies, gains).map {
            EQBand(
                frequency: $0.0,
                gain: $0.1,
                bandwidth: bandMode.defaultBandwidth
            )
        }
        recommendedPreampDB = EQHeadroomCalculator.recommendedPreamp(for: bands)
        if applyIfEnabled, autoPreampEnabled,
           abs(preampDB - recommendedPreampDB) >= 0.01 {
            preampDB = recommendedPreampDB
        }
    }

    private func normalizedGains(_ values: [Float], count: Int) -> [Float] {
        if values.count == count { return values }
        if values.count < count {
            return values + Array(repeating: 0, count: count - values.count)
        }
        return Array(values.prefix(count))
    }

    /// Samples the exact rendered response at the overview-band centers.
    static func approximateGains(from bands: [EQBand], mode: EQBandMode) -> [Float] {
        mode.frequencies.map { center in
            max(
                -12,
                min(
                    12,
                    EQResponse.magnitudeDB(
                        bands: bands,
                        at: Double(center)
                    )
                )
            )
        }
    }

    static func resampleGraphicGains(
        _ gains: [Float],
        from sourceFrequencies: [Float],
        to destinationFrequencies: [Float]
    ) -> [Float] {
        let sourceCount = min(gains.count, sourceFrequencies.count)
        guard sourceCount > 0 else {
            return Array(repeating: 0, count: destinationFrequencies.count)
        }
        let sourceGains = Array(gains.prefix(sourceCount))
        let source = Array(sourceFrequencies.prefix(sourceCount))

        return destinationFrequencies.map { frequency in
            if frequency <= source[0] { return sourceGains[0] }
            if frequency >= source[sourceCount - 1] {
                return sourceGains[sourceCount - 1]
            }
            guard let upper = source.firstIndex(where: { $0 >= frequency }),
                  upper > 0
            else { return sourceGains[0] }
            let lower = upper - 1
            let logLower = log2(source[lower])
            let logUpper = log2(source[upper])
            let fraction = (log2(frequency) - logLower) / max(0.000_1, logUpper - logLower)
            return sourceGains[lower]
                + (sourceGains[upper] - sourceGains[lower]) * fraction
        }
    }

    // MARK: - Persistence

    private func restore() {
        isRestoring = true
        defer { isRestoring = false }

        let prefs = AppPreferences.load()
        preferences = prefs
        if let tenBand = prefs.tenBandGains {
            graphicGainsByMode[.ten] = normalizedGains(
                tenBand,
                count: EQBandMode.ten.bandCount
            )
        }
        let migratedFifteen = prefs.fifteenBandGains.map {
            Self.resampleGraphicGains(
                $0,
                from: EQBandMode.fifteen.frequencies,
                to: frequencies
            )
        }
        gains = graphicGainsByMode[bandMode]
            ?? migratedFifteen
            ?? normalizedGains(prefs.customGains, count: frequencies.count)
        graphicGainsByMode[bandMode] = gains
        preampDB = prefs.preampDB
        selectedPresetName = prefs.selectedPresetName
        selectedUserPresetID = prefs.selectedUserPresetID.flatMap { id in
            presetStore.userPresets.contains(where: { $0.id == id }) ? id : nil
        }
        selectedHeadphoneName = prefs.lastHeadphoneName
        activeParametricBands = prefs.activeParametricBands
        autoPreampEnabled = prefs.autoPreampEnabled
        crossfeedEnabled = prefs.crossfeedEnabled
        crossfeedAmount = min(1, max(0, prefs.crossfeedAmount))
        // SMAppService is authoritative: if the user disables the item in
        // System Settings, do not silently re-enable it from cached prefs.
        launchAtLogin = LoginItem.shared.isRegistered
        hotKeyEnabled = prefs.hotKeyEnabled

        if let parametric = activeParametricBands {
            gains = Self.approximateGains(from: parametric, mode: bandMode)
        } else if let headphone = prefs.lastHeadphoneName,
                  let preset = presetStore.headphone(named: headphone)
                    ?? presetStore.imported.first(where: { $0.name == headphone }) {
            activeParametricBands = preset.bands
            preampDB = min(6, max(-24, preset.preampDB))
            gains = Self.approximateGains(from: preset.bands, mode: bandMode)
        }

        refreshHeadroom(applyIfEnabled: true)
        eqEnabled = prefs.eqEnabled
    }

    private func persist() {
        guard !isRestoring else { return }
        preferences.eqEnabled = eqEnabled
        preferences.bandMode = bandMode
        var storedGains = gains
        while storedGains.count < 15 { storedGains.append(0) }
        preferences.customGains = Array(storedGains.prefix(15))
        preferences.tenBandGains = gains
        preferences.fifteenBandGains = nil
        preferences.preampDB = preampDB
        preferences.selectedPresetName = selectedPresetName
        preferences.selectedUserPresetID = selectedUserPresetID
        preferences.lastHeadphoneName = selectedHeadphoneName
        preferences.activeParametricBands = activeParametricBands
        preferences.autoPreampEnabled = autoPreampEnabled
        preferences.autoPreampDefaultEnabled = autoPreampEnabled
        preferences.launchAtLogin = launchAtLogin
        preferences.hotKeyEnabled = hotKeyEnabled
        preferences.hotKeyKeyCode = HotKeyManager.Shortcut.defaultToggleEQ.keyCode
        preferences.hotKeyModifiers = HotKeyManager.Shortcut.defaultToggleEQ.modifiers
        preferences.crossfeedEnabled = crossfeedEnabled
        preferences.crossfeedAmount = crossfeedAmount

        persistWorkItem?.cancel()
        let snapshot = preferences
        let work = DispatchWorkItem {
            snapshot.save()
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func configureSystemFeatures() {
        if hotKeyEnabled {
            setHotKeyEnabled(true)
        }
        refreshSystemFeatureStatus()
    }

    private func updateStatus() {
        if audioEngine.isRunning {
            permission.markEngineSucceeded()
        }
        if let error = audioEngine.errorMessage {
            statusText = error
        } else if eqEnabled, audioEngine.isRunning, isBypassed {
            statusText = "Bypassed · Level-matched dry · \(audioEngine.outputDeviceName)"
        } else if eqEnabled, audioEngine.isRunning {
            let name = selectedHeadphoneName ?? selectedPresetName
            statusText = "EQ on · \(name) · \(audioEngine.outputDeviceName)"
        } else if eqEnabled {
            statusText = "Starting…"
        } else {
            statusText = "EQ off · \(audioEngine.outputDeviceName)"
        }
    }

    func suggestedCustomPresetName() -> String {
        if selectedPresetName == "Flat" || selectedPresetName == "Custom" {
            return "My EQ"
        }
        return "\(selectedPresetName) Edit"
    }

    private func refreshCatalogResults() {
        catalogResults = presetStore.searchCatalog(
            headphoneSearch,
            limit: headphoneSearch.isEmpty ? 400 : 800
        )
    }

    private static func frequencyLabel(_ frequency: Float) -> String {
        if frequency >= 1_000 {
            let value = frequency / 1_000
            return value == floor(value)
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(Int(frequency))"
    }
}
