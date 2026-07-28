import Foundation
import ServiceManagement

/// Controls whether the main app is launched when the user logs in.
///
/// `SMAppService` requires the app to run from a code-signed application
/// bundle. The raw SwiftPM executable is therefore expected to report
/// ``Status/unavailable``.
@available(macOS 13.0, *)
@MainActor
final class LoginItem {
    enum Status: Equatable, Sendable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable
    }

    enum LoginItemError: LocalizedError, Equatable {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Launch at login is unavailable outside the packaged app."
            }
        }
    }

    static let shared = LoginItem()

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: Status {
        switch service.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    /// Whether macOS currently permits the app to launch at login.
    var isEnabled: Bool {
        status == .enabled
    }

    /// Whether the service has been registered, including pending approval.
    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Enables or disables launch at login.
    ///
    /// The operation is idempotent. When the service requires approval it is
    /// already registered, so callers can present that state and invoke
    /// ``openSystemSettings()`` instead of attempting another registration.
    func setEnabled(_ enabled: Bool) throws {
        switch (enabled, status) {
        case (true, .disabled):
            try service.register()
        case (true, .unavailable):
            throw LoginItemError.unavailable
        case (false, .enabled), (false, .requiresApproval):
            try service.unregister()
        case (true, .enabled), (true, .requiresApproval),
             (false, .disabled), (false, .unavailable):
            return
        }
    }

    /// Opens System Settings at General → Login Items.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
