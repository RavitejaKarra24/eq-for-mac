import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Tracks whether system-audio capture is allowed.
///
/// `CGPreflightScreenCaptureAccess()` is unreliable for ad-hoc / menu-bar apps:
/// it often stays `false` even after the user grants Screen & System Audio Recording.
/// We therefore also treat a successful process-tap probe (or a running EQ engine)
/// as proof of permission.
@available(macOS 14.2, *)
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var isGranted = false
    /// Show the banner only when we believe permission is missing.
    @Published private(set) var shouldShowBanner = false

    private let dismissedKey = "EQForMac.permissionBannerDismissed"
    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        installObservers()
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func refresh() {
        let preflight = CGPreflightScreenCaptureAccess()
        let probed = preflight ? true : probeProcessTapPermission()
        let granted = preflight || probed || UserDefaults.standard.bool(forKey: "EQForMac.audioPermissionOK")
        isGranted = granted

        let dismissed = UserDefaults.standard.bool(forKey: dismissedKey)
        // Banner only when not granted and user hasn't dismissed after checking.
        shouldShowBanner = !granted && !dismissed
    }

    /// Call when the EQ engine starts successfully — strongest signal.
    func markEngineSucceeded() {
        UserDefaults.standard.set(true, forKey: "EQForMac.audioPermissionOK")
        isGranted = true
        shouldShowBanner = false
    }

    func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
        // Re-check shortly after the system dialog / Settings return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refresh()
        }
    }

    func openSystemSettings() {
        // macOS Ventura+ privacy pane for Screen & System Audio Recording
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ]
        for s in urls {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }

    /// User says they already granted — re-probe and hide if OK, else hide after confirm.
    func userConfirmedGranted() {
        refresh()
        if isGranted {
            shouldShowBanner = false
            return
        }
        // Soft dismiss so a stuck preflight doesn't nag forever.
        UserDefaults.standard.set(true, forKey: dismissedKey)
        shouldShowBanner = false
    }

    // MARK: - Private

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        )
    }

    /// Non-destructive probe: create an *unmuted* global tap and destroy it.
    /// If TCC blocks process taps, creation fails.
    private func probeProcessTapPermission() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.name = "EQForMac-PermissionProbe"
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        if status == noErr, tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            UserDefaults.standard.set(true, forKey: "EQForMac.audioPermissionOK")
            return true
        }
        return false
    }
}
