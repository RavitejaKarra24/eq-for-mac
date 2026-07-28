import AppKit
import SwiftUI

@available(macOS 14.2, *)
struct EQPopoverView: View {
    @ObservedObject var model: EQViewModel
    @ObservedObject private var presetStore: PresetStore
    @ObservedObject private var permission = PermissionMonitor.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCatalogExpanded = false
    @State private var isNamingPreset = false
    @State private var renamingPresetID: UUID?
    @State private var presetNameDraft = ""

    init(model: EQViewModel) {
        self.model = model
        _presetStore = ObservedObject(wrappedValue: model.presetStore)
    }

    private var mainCatalogResults: [HeadphoneCatalogEntry] {
        guard model.headphoneSearch.isEmpty else { return model.catalogResults }
        let featuredNames = Set(
            (model.presetStore.favoriteHeadphones + model.presetStore.recentHeadphones)
                .map { $0.name.lowercased() }
        )
        return model.catalogResults.filter {
            !featuredNames.contains($0.name.lowercased())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if permission.shouldShowBanner {
                permissionBanner
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    eqBoard
                    preampRow
                    builtInPresets
                    headphoneSection
                    footer
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 500, height: 560)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: permission.shouldShowBanner)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.eqEnabled)
        .onAppear {
            model.refreshPermission()
            model.setSpectrumVisible(!reduceMotion)
        }
        .onDisappear {
            model.endDryComparison()
            model.setSpectrumVisible(false)
        }
        .onChange(of: reduceMotion) { _, isReduced in
            model.setSpectrumVisible(!isReduced)
        }
        .onChange(of: permission.shouldShowBanner) { _, _ in
            model.setSpectrumVisible(!reduceMotion)
        }
        .sheet(isPresented: $model.showPermissionOnboarding) {
            PermissionOnboardingView(model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // Status glyph
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(model.eqEnabled
                              ? Color.accentColor.opacity(0.18)
                              : Color.primary.opacity(0.06))
                        .frame(width: 32, height: 32)
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.eqEnabled ? Color.accentColor : .secondary)
                        .symbolEffect(.pulse, options: .repeating, isActive: model.eqEnabled && model.audioEngine.isRunning && !reduceMotion)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("EQ for Mac")
                            .font(.system(.headline, design: .default).weight(.semibold))
                        if model.eqEnabled && model.audioEngine.isRunning {
                            LiveBadge()
                        }
                    }
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            // Power control
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System EQ")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        model.eqEnabled
                            ? (model.isBypassed ? "Temporarily bypassed — dry signal" : "Shaping all system audio")
                            : "Off — dry signal"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(model.eqEnabled ? "ON" : "OFF")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(model.eqEnabled ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
                    .accessibilityHidden(true)

                Toggle("System EQ", isOn: $model.eqEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .help("Apply EQ to all system audio (browser, Spotify, Apple Music, …)")

                Divider()
                    .frame(height: 20)

                Button {
                    model.toggleBypass()
                } label: {
                    Label(
                        model.isBypassed ? "Resume" : "Bypass",
                        systemImage: model.isBypassed ? "play.fill" : "pause.fill"
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(model.isBypassed ? .orange : .secondary)
                .disabled(!model.eqEnabled)
                .help(model.isBypassed ? "Resume processed audio" : "Bypass EQ (⌘B)")
                .keyboardShortcut("b", modifiers: .command)

                DryCompareControl(
                    isActive: model.isComparing,
                    isEnabled: model.eqEnabled
                        && !model.isBypassed
                        && model.hasDryComparisonDifference,
                    helpText: dryComparisonHelp,
                    onPress: model.beginDryComparison,
                    onRelease: model.endDryComparison
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.eqEnabled
                          ? Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10)
                          : Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        model.eqEnabled
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: model.eqEnabled ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10) : .clear,
                radius: 10,
                y: 2
            )
        }
    }

    // MARK: - Permission

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Allow Screen & System Audio Recording so EQ can tap system audio. If you already allowed it, confirm below.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Button("Guided Setup") {
                    model.showPermissionOnboarding = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Request Access") {
                    model.requestPermissionIfNeeded()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)

                Button("I’ve granted access") {
                    model.dismissPermissionBanner()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
        }
        .onAppear {
            model.refreshPermission()
        }
    }

    private var dryComparisonHelp: String {
        if !model.eqEnabled {
            return "Turn on System EQ before comparing."
        }
        if model.isBypassed {
            return "Resume processing before starting A/B comparison."
        }
        if !model.hasDryComparisonDifference {
            return "The current curve has no active filter shaping, so A and B are identical."
        }
        return "Press and hold to hear level-matched dry audio; release to resume EQ."
    }

    // MARK: - EQ Board (hero)

    private var eqBoard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Equalizer")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(model.selectedPresetName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))

                if model.hasUserOverlays {
                    Button("Revert source") {
                        model.revertToSourceCurve()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .help("Remove curve edits and restore the imported filters")
                }

                Button {
                    model.copyFiltersToPasteboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Equalizer APO filters")

                Button("Reset") {
                    model.resetFlat()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help("Reset all bands to 0 dB")
            }

            LiveEQCurveSurface(
                audioEngine: model.audioEngine,
                gains: model.editorGains,
                frequencies: model.editorFrequencies,
                responseGains: model.responseGains,
                responseFrequencies: model.responseFrequencies,
                isEditable: model.eqEnabled,
                allowsParametricEditing: model.hasParametricFilters,
                onBandChange: { index, frequency, gain in
                    model.setEditorBand(
                        at: index,
                        frequency: frequency,
                        gain: gain
                    )
                },
                onResetBand: { index in
                    model.setEditorBand(
                        at: index,
                        frequency: model.editorFrequencies[index],
                        gain: 0
                    )
                },
                onAddBand: model.addEditorBand,
                onDeleteBand: model.deleteEditorBand,
                onFilterTypeChange: { index, type in
                    model.setEditorBandType(type, at: index)
                },
                onBandwidthChange: { index, bandwidth in
                    model.setEditorBandwidth(bandwidth, at: index)
                }
            )
            .frame(height: 190)
            .opacity(model.eqEnabled ? 1 : 0.50)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .help("Drag a node to adjust gain; the line is the exact rendered response")
        }
    }

    // MARK: - Preamp

    private var preampRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Label("Preamp", systemImage: "dial.low")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { model.preampDB },
                        set: { model.setPreampDB($0) }
                    ),
                    in: -24...6,
                    step: 0.5
                )
                .controlSize(.small)
                .tint(model.preampDB < -0.1 ? .orange : .accentColor)
                .help("Overall gain before EQ — lower to avoid clipping")

                Text(String(format: "%+.1f dB", model.preampDB))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(abs(model.preampDB) < 0.05 ? .secondary : .primary)
                    .frame(width: 62, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }

            HStack(spacing: 8) {
                Toggle(
                    "Auto headroom",
                    isOn: Binding(
                        get: { model.autoPreampEnabled },
                        set: { model.setAutoPreampEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)

                Spacer()

                Text("Safe: \(String(format: "%+.1f dB", model.recommendedPreampDB))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                if abs(model.preampDB - model.recommendedPreampDB) >= 0.1 {
                    Button("Match") {
                        model.matchRecommendedPreamp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Apply the calculated clip-safe preamp")
                }
            }

            HStack(spacing: 8) {
                Text(
                    "Latency: \(Int(model.audioEngine.measuredLatencyMilliseconds.rounded())) ms"
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

                Spacer()

                Picker(
                    "Latency budget",
                    selection: Binding(
                        get: { model.audioEngine.latencyMode },
                        set: { model.audioEngine.setLatencyMode($0) }
                    )
                ) {
                    ForEach(AudioEngine.LatencyMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .controlSize(.mini)
                .help("Trade queue safety against audio/video latency")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025))
        }
    }

    // MARK: - Presets

    private var builtInPresets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Presets", systemImage: "square.stack.3d.up")
                Spacer()
                Button {
                    presetNameDraft = model.suggestedCustomPresetName()
                    renamingPresetID = nil
                    isNamingPreset = true
                    model.systemFeatureError = nil
                } label: {
                    Label("Save current", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Save the current EQ as a reusable preset")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.presetStore.favoriteUserPresets) { userPreset in
                        userPresetChip(userPreset)
                    }
                    ForEach(model.presetStore.builtIn) { preset in
                        let selected = model.selectedPresetName == preset.name
                            && model.selectedUserPresetID == nil
                            && model.selectedHeadphoneName == nil
                        Button {
                            model.applyBuiltInPreset(preset)
                        } label: {
                            Text(preset.name)
                                .font(.caption.weight(selected ? .semibold : .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background {
                                    Capsule(style: .continuous)
                                        .fill(selected
                                              ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.16)
                                              : Color.primary.opacity(0.06))
                                }
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(
                                            selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                                            lineWidth: 1
                                        )
                                }
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .help("Apply \(preset.name) preset")
                    }
                }
                .padding(.vertical, 1)
            }

            if model.presetStore.userPresets.contains(where: { !$0.isFavorite }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.presetStore.userPresets.filter { !$0.isFavorite }) { userPreset in
                            userPresetChip(userPreset)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            if isNamingPreset || renamingPresetID != nil {
                presetNameEditor
            }
        }
    }

    private var presetNameEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(renamingPresetID == nil ? "Save current EQ" : "Rename preset")
                .font(.caption.weight(.semibold))
            HStack(spacing: 6) {
                TextField("Preset name", text: $presetNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(performPresetNameAction)
                Button(renamingPresetID == nil ? "Save" : "Rename") {
                    performPresetNameAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
                Button("Cancel") {
                    closePresetNameEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let error = model.systemFeatureError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
    }

    private func performPresetNameAction() {
        let name = presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let succeeded: Bool
        if let id = renamingPresetID,
           let preset = model.presetStore.userPreset(id: id) {
            succeeded = model.renameUserPreset(preset, to: name)
        } else {
            succeeded = model.saveCurrentPreset(named: name)
        }
        if succeeded {
            closePresetNameEditor()
        }
    }

    private func closePresetNameEditor() {
        isNamingPreset = false
        renamingPresetID = nil
        presetNameDraft = ""
        model.systemFeatureError = nil
    }

    private func userPresetChip(_ userPreset: UserPreset) -> some View {
        let selected = model.selectedUserPresetID == userPreset.id
        return Button {
            model.applyUserPreset(userPreset)
        } label: {
            HStack(spacing: 4) {
                if userPreset.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                }
                Text(userPreset.name)
                    .lineLimit(1)
            }
            .font(.caption.weight(selected ? .semibold : .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.16)
                            : Color.primary.opacity(0.06)
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(userPreset.isFavorite ? "Remove Favorite" : "Favorite") {
                model.toggleFavorite(userPreset)
            }
            Button("Rename…") {
                presetNameDraft = userPreset.name
                isNamingPreset = false
                renamingPresetID = userPreset.id
                model.systemFeatureError = nil
            }
            Button("Move Earlier") {
                model.moveUserPreset(userPreset, by: -1)
            }
            Button("Move Later") {
                model.moveUserPreset(userPreset, by: 1)
            }
            Divider()
            Button("Delete", role: .destructive) {
                model.deleteUserPreset(userPreset)
            }
        }
        .help("Apply \(userPreset.name); right-click to manage")
    }

    // MARK: - Headphone catalog

    private var headphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        isCatalogExpanded.toggle()
                    }
                } label: {
                    Label(
                        isCatalogExpanded ? "Hide headphone search" : "Find headphone correction",
                        systemImage: isCatalogExpanded ? "chevron.up" : "headphones"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                Spacer()
                if model.isLoadingHeadphone {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text("\(model.presetStore.catalogCount.formatted())")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }

            if isCatalogExpanded {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search models, brands…", text: $model.headphoneSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !model.headphoneSearch.isEmpty {
                    Button {
                        model.headphoneSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            if let err = model.headphoneLoadError {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if let notice = model.catalogNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.headphoneSearch.isEmpty,
                       !model.presetStore.favoriteHeadphones.isEmpty {
                        sectionLabel("Favorites")
                        ForEach(model.presetStore.favoriteHeadphones) { entry in
                            catalogRow(entry)
                        }
                    }

                    if model.headphoneSearch.isEmpty,
                       !model.presetStore.recentHeadphones.isEmpty {
                        sectionLabel("Recently applied")
                        ForEach(model.presetStore.recentHeadphones.prefix(6)) { entry in
                            catalogRow(entry)
                        }
                    }

                    if !model.presetStore.imported.isEmpty {
                        sectionLabel("Imported")
                        ForEach(model.presetStore.imported) { preset in
                            ImportedRow(
                                preset: preset,
                                isSelected: model.selectedHeadphoneName == preset.name,
                                isLoading: model.isLoadingHeadphone
                            ) {
                                model.applyHeadphone(preset)
                            }
                        }
                    }

                    sectionLabel(
                        "Catalog · \(model.presetStore.withEQCount.formatted()) offline EQ"
                    )
                    ForEach(mainCatalogResults) { entry in
                        catalogRow(entry)
                    }

                    if model.catalogResults.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "waveform.slash")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text("No matches")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("Try another spelling, or import a PEQdB / AutoEQ .txt")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    if model.headphoneSearch.isEmpty
                        && model.presetStore.catalogCount > model.catalogResults.count {
                        Text("Showing first \(model.catalogResults.count). Type to search all \(model.presetStore.catalogCount.formatted()).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 200)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                model.importEQFile()
            } label: {
                Label("Import EQ file…", systemImage: "square.and.arrow.down")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Import Equalizer APO / PEQdB / AutoEQ parametric .txt")
            }
        }
    }

    private func catalogRow(_ entry: HeadphoneCatalogEntry) -> some View {
        CatalogRow(
            entry: entry,
            isSelected: model.selectedHeadphoneName == entry.name,
            isLoading: model.isLoadingHeadphone,
            isFavorite: model.isFavorite(entry),
            action: {
                model.applyCatalogEntry(entry)
            },
            toggleFavorite: {
                model.toggleFavorite(entry)
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Applies to every app · lives in the menu bar")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Settings…") {
                NotificationCenter.default.post(name: .showEQForMacSettings, object: nil)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .keyboardShortcut(",", modifiers: .command)
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .help("Quit EQ for Mac")
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 2)
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

}

// MARK: - Isolated spectrum surface

/// Keeps 30 fps analyzer publications from invalidating the catalog, presets,
/// and rest of the popover.
@available(macOS 14.2, *)
private struct LiveEQCurveSurface: View {
    @ObservedObject var audioEngine: AudioEngine
    var gains: [Float]
    var frequencies: [Float]
    var responseGains: [Float]
    var responseFrequencies: [Float]
    var isEditable: Bool
    var allowsParametricEditing: Bool
    var onBandChange: (Int, Float, Float) -> Void
    var onResetBand: (Int) -> Void
    var onAddBand: (Float, Float) -> Void
    var onDeleteBand: (Int) -> Void
    var onFilterTypeChange: (Int, EQFilterType) -> Void
    var onBandwidthChange: (Int, Float) -> Void

    var body: some View {
        EQCurveView(
            gains: gains,
            frequencies: frequencies,
            responseGains: responseGains,
            responseFrequencies: responseFrequencies,
            spectrumMagnitudes: audioEngine.spectrumMagnitudes,
            isEditable: isEditable,
            allowsParametricEditing: allowsParametricEditing,
            onBandChange: onBandChange,
            onResetBand: onResetBand,
            onAddBand: onAddBand,
            onDeleteBand: onDeleteBand,
            onFilterTypeChange: onFilterTypeChange,
            onBandwidthChange: onBandwidthChange
        )
    }
}

// MARK: - Hold-to-compare control

private struct DryCompareControl: View {
    var isActive: Bool
    var isEnabled: Bool
    var helpText: String
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Text(isActive ? "B · DRY" : "A · EQ")
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .foregroundStyle(isActive ? Color.orange : Color.primary)
            .frame(width: 52, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.orange.opacity(0.16) : Color.primary.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.orange.opacity(0.55) : Color.primary.opacity(0.10),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onRelease()
                    }
            )
            .onDisappear {
                if isPressed {
                    isPressed = false
                    onRelease()
                }
            }
            .help(helpText)
            .accessibilityElement()
            .accessibilityLabel("A/B audio comparison")
            .accessibilityValue(isActive ? "B, level-matched dry" : "A, processed EQ")
            .accessibilityHint(
                isEnabled
                    ? "Press and hold for dry audio, then release to resume EQ."
                    : helpText
            )
    }
}

// MARK: - Live badge

private struct LiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 1 : 0.45)
                .shadow(color: .green.opacity(0.7), radius: pulse ? 3 : 0)
            Text("LIVE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.green.opacity(0.12)))
        .onAppear {
            guard !reduceMotion else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel("EQ is live")
    }
}

// MARK: - Catalog rows

private struct CatalogRow: View {
    let entry: HeadphoneCatalogEntry
    var isSelected: Bool
    var isLoading: Bool
    var isFavorite: Bool
    var action: () -> Void
    var toggleFavorite: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var iconName: String {
        if isSelected { return "checkmark.circle.fill" }
        if entry.isTargetCurve { return "waveform.path" }
        if entry.hasEQ { return "headphones" }
        return "ear"
    }

    private var subtitle: String {
        if entry.isTargetCurve {
            return "Target · \(entry.targetCategory ?? "Reference") · PEQdB Studio"
        }
        if entry.hasEQ {
            return entry.source.map { "Offline · \($0)" } ?? "Offline EQ"
        }
        return "No published AutoEQ · import .txt"
    }

    private var badge: (text: String, emphasis: Bool) {
        if entry.isTargetCurve { return ("target", false) }
        if entry.hasEQ { return ("EQ", true) }
        return ("import", false)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(badge.text)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(badge.emphasis ? Color.secondary : Color.secondary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.primary.opacity(isSelected ? 0.08 : 0.04))
                        )
                }
                .padding(.leading, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.75))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Pin to favorites")
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        }
        .padding(.horizontal, 4)
        .onHover { isHovering = $0 }
        .help(entry.name)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.12)
        }
        if isHovering {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }
}

private struct ImportedRow: View {
    let preset: EQPreset
    var isSelected: Bool
    var isLoading: Bool
    var action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "doc.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(preset.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("file")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .disabled(isLoading)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.12)
        }
        if isHovering {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }
}
