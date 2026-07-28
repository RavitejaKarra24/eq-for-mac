import AppKit
import SwiftUI

extension Notification.Name {
    static let showEQForMacSettings = Notification.Name("EQForMac.showSettings")
}

@available(macOS 14.2, *)
@MainActor
final class SettingsWindowController {
    private let model: EQViewModel
    private var window: NSWindow?

    init(model: EQViewModel) {
        self.model = model
    }

    func show() {
        model.refreshSystemFeatureStatus()
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "EQ for Mac Settings"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.setContentSize(NSSize(width: 500, height: 570))
            created.minSize = NSSize(width: 460, height: 500)
            created.isReleasedWhenClosed = false
            created.center()
            created.setFrameAutosaveName("EQForMac.SettingsWindow")
            self.window = created
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@available(macOS 14.2, *)
private struct SettingsView: View {
    @ObservedObject var model: EQViewModel

    var body: some View {
        Form {
            Section("General") {
                settingToggle(
                    "Launch at login",
                    detail: "Start the menu-bar EQ automatically after you sign in.",
                    isOn: model.launchAtLogin,
                    action: model.setLaunchAtLogin
                )

                settingToggle(
                    "Global shortcut",
                    detail: "Press ⌥⌘E from any app to toggle the system EQ.",
                    isOn: model.hotKeyEnabled,
                    action: model.setHotKeyEnabled
                )

                Button("Open Screen & System Audio Settings") {
                    model.openPermissionSettings()
                }
                .buttonStyle(.link)
            }

            Section("Signal safety") {
                settingToggle(
                    "Clip-safe auto-preamp",
                    detail: "Continuously reserves headroom for the combined filter response.",
                    isOn: model.autoPreampEnabled,
                    action: model.setAutoPreampEnabled
                )

                LabeledContent("Recommended") {
                    HStack(spacing: 8) {
                        Text(String(format: "%+.1f dB", model.recommendedPreampDB))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Match") {
                            model.matchRecommendedPreamp()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Headphone spatial controls") {
                settingToggle(
                    "Crossfeed",
                    detail: "Blend a filtered, delayed opposite channel for a speaker-like image.",
                    isOn: model.crossfeedEnabled,
                    action: model.setCrossfeedEnabled
                )

                LabeledContent("Crossfeed amount") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.crossfeedAmount },
                                set: model.setCrossfeedAmount
                            ),
                            in: 0...1
                        )
                        Text("\(Int(model.crossfeedAmount * 100))%")
                            .frame(width: 38, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
                .disabled(!model.crossfeedEnabled)

                LabeledContent("Stereo width") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.stereoWidth },
                                set: model.setStereoWidth
                            ),
                            in: 0...2,
                            step: 0.05
                        )
                        Text("\(Int(model.stereoWidth * 100))%")
                            .frame(width: 42, alignment: .trailing)
                            .monospacedDigit()
                    }
                }

                LabeledContent("Balance") {
                    HStack {
                        Text("L")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.balance },
                                set: model.setBalance
                            ),
                            in: -1...1,
                            step: 0.05
                        )
                        Text("R")
                            .foregroundStyle(.secondary)
                    }
                }

                settingToggle(
                    "Mono fold-down",
                    detail: "Mix left and right equally into both output channels.",
                    isOn: model.monoEnabled,
                    action: model.setMonoEnabled
                )
            }

            Section("Output profile") {
                LabeledContent("Current output") {
                    Text(model.audioEngine.outputDeviceName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Button(
                        model.hasProfileForCurrentDevice
                            ? "Update profile for this output"
                            : "Remember EQ for this output"
                    ) {
                        model.rememberCurrentDeviceProfile()
                    }
                    Button("Forget") {
                        model.forgetCurrentDeviceProfile()
                    }
                    .disabled(!model.hasProfileForCurrentDevice)
                    Spacer()
                }
            }

            if let error = model.systemFeatureError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let notice = model.loginItemNotice {
                Section {
                    Label(notice, systemImage: "person.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items Settings") {
                        LoginItem.shared.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
            }

            Section("About") {
                LabeledContent("EQ for Mac") {
                    Text("Driver-free · offline-first")
                        .foregroundStyle(.secondary)
                }
                Text("System audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .frame(minWidth: 460, minHeight: 500)
        .onAppear {
            model.refreshSystemFeatureStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refreshSystemFeatureStatus()
        }
    }

    private func settingToggle(
        _ title: String,
        detail: String,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(
            isOn: Binding(get: { isOn }, set: action)
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
