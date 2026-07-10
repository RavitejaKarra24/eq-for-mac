import AppKit
import SwiftUI

@available(macOS 14.2, *)
struct EQPopoverView: View {
    @ObservedObject var model: EQViewModel
    @ObservedObject private var permission = PermissionMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed header — always visible (not inside scroll)
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if permission.shouldShowBanner {
                permissionBanner
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    bandModePicker
                    eqSliders
                    preampRow
                    Divider()
                    builtInPresets
                    Divider()
                    headphoneSection
                    Divider()
                    footer
                }
                .padding(14)
            }
        }
        .frame(width: 440, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshPermission()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("EQ for Mac")
                        .font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            // Large, hard-to-miss EQ power switch
            HStack(spacing: 12) {
                Text("System EQ")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(model.eqEnabled ? "ON" : "OFF")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(model.eqEnabled ? Color.green : Color.secondary)
                    .frame(minWidth: 32, alignment: .trailing)

                Toggle("", isOn: $model.eqEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.regular)
                    .help("Apply EQ to all system audio (browser, Spotify, Apple Music, …)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.eqEnabled
                          ? Color.accentColor.opacity(0.18)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        model.eqEnabled ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25),
                        lineWidth: 1
                    )
            )
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "If EQ won’t start, allow Screen & System Audio Recording for EQ for Mac. If you already allowed it, tap “I’ve granted access”.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Grant Permission") {
                    model.requestPermissionIfNeeded()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Settings") {
                    model.openPermissionSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("I’ve granted access") {
                    model.dismissPermissionBanner()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            model.refreshPermission()
        }
    }

    private var bandModePicker: some View {
        HStack {
            Text("Bands")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $model.bandMode) {
                Text("10-band").tag(EQBandMode.ten)
                Text("15-band").tag(EQBandMode.fifteen)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)

            Spacer()

            Button("Reset") {
                model.resetFlat()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var eqSliders: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(model.gains.indices), id: \.self) { index in
                    VStack(spacing: 4) {
                        Text(gainLabel(model.gains[index]))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(height: 12)

                        VerticalSlider(value: binding(for: index), range: -12...12, height: 120)
                            .frame(maxWidth: .infinity)

                        Text(model.frequencyLabels[index])
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 160)

            Text("Drag sliders to shape system audio · \(model.selectedPresetName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var preampRow: some View {
        HStack(spacing: 10) {
            Text("Preamp")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Slider(value: $model.preampDB, in: -12...6, step: 0.5)
            Text(String(format: "%+.1f dB", model.preampDB))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var builtInPresets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.presetStore.builtIn) { preset in
                        Button(preset.name) {
                            model.applyBuiltInPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.selectedPresetName == preset.name && model.selectedHeadphoneName == nil
                              ? Color.accentColor : Color.secondary)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var headphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search graphs")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.isLoadingHeadphone {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(model.presetStore.catalogCount.formatted()) graphs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            TextField("Search graphs…", text: $model.headphoneSearch)
                .textFieldStyle(.roundedBorder)

            if let err = model.headphoneLoadError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.presetStore.imported.isEmpty {
                        sectionLabel("Imported")
                        ForEach(model.presetStore.imported) { preset in
                            importedRow(preset)
                        }
                    }

                    sectionLabel(
                        "PEQdB · \(model.presetStore.catalogCount.formatted()) graphs · \(model.presetStore.withEQCount.formatted()) offline EQ"
                    )
                    ForEach(model.catalogResults) { entry in
                        catalogRow(entry)
                    }

                    if model.catalogResults.isEmpty {
                        Text("No matches. Try another spelling or import a PEQdB .txt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }

                    if model.headphoneSearch.isEmpty && model.presetStore.catalogCount > model.catalogResults.count {
                        Text("Showing first \(model.catalogResults.count). Type to search all \(model.presetStore.catalogCount.formatted()).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    }
                }
            }
            .frame(height: 220)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button {
                    model.importEQFile()
                } label: {
                    Label("Import EQ file…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)

                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Applies to all apps · menu bar only")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit EQ for Mac") {
                NSApp.terminate(nil)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func catalogRow(_ entry: HeadphoneCatalogEntry) -> some View {
        let selected = model.selectedHeadphoneName == entry.name
        return Button {
            model.applyCatalogEntry(entry)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : (entry.hasEQ ? "headphones" : "ear"))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.hasEQ
                         ? (entry.source.map { "Offline · \($0)" } ?? "Offline EQ")
                         : "No published AutoEQ · import .txt to apply")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if entry.hasEQ {
                    Text("EQ")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("import")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .disabled(model.isLoadingHeadphone)
    }

    private func importedRow(_ preset: EQPreset) -> some View {
        Button {
            model.applyHeadphone(preset)
        } label: {
            HStack {
                Image(systemName: model.selectedHeadphoneName == preset.name
                      ? "checkmark.circle.fill" : "doc.badge.plus")
                    .foregroundStyle(
                        model.selectedHeadphoneName == preset.name ? Color.accentColor : .secondary
                    )
                    .frame(width: 16)
                Text(preset.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            model.selectedHeadphoneName == preset.name
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private func binding(for index: Int) -> Binding<Float> {
        Binding(
            get: {
                guard index < model.gains.count else { return 0 }
                return model.gains[index]
            },
            set: { newValue in
                guard index < model.gains.count else { return }
                // Clear parametric override when user manually edits a band.
                var copy = model.gains
                copy[index] = newValue
                model.gains = copy
            }
        )
    }

    private func gainLabel(_ g: Float) -> String {
        if abs(g) < 0.05 { return "0" }
        return String(format: "%+.0f", g)
    }
}
