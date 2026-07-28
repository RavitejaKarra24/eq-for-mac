import Carbon.HIToolbox
import Foundation

private let eqForMacHotKeySignature: OSType = 0x4551_464D // "EQFM"
private let eqForMacHotKeyIdentifier: UInt32 = 1

private let eqForMacHotKeyEventHandler: EventHandlerUPP = {
    _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let parameterStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard parameterStatus == noErr,
          hotKeyID.signature == eqForMacHotKeySignature
    else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let identifier = hotKeyID.id
    Task { @MainActor [manager] in
        manager.handleHotKey(identifier: identifier)
    }
    return noErr
}

/// Registers one application-wide keyboard shortcut with the Carbon Hot Key API.
///
/// Carbon remains the system API that can register a shortcut without requiring
/// Accessibility permission. Instances are main-actor isolated because Carbon's
/// application event target is tied to the main event loop.
@MainActor
final class HotKeyManager {
    struct Shortcut: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
        let displayName: String

        init(keyCode: UInt32, modifiers: UInt32, displayName: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.displayName = displayName
        }

        /// Option-Command-E, used to toggle EQ globally.
        static let defaultToggleEQ = Shortcut(
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: UInt32(cmdKey | optionKey),
            displayName: "⌥⌘E"
        )
    }

    enum RegistrationError: LocalizedError, Equatable {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .eventHandler(status):
                return "Could not install the global hotkey event handler (OSStatus \(status))."
            case let .hotKey(status):
                return "Could not register the global hotkey (OSStatus \(status))."
            }
        }
    }

    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    private var onPressed: (@MainActor () -> Void)?

    private(set) var registeredShortcut: Shortcut?

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// Starts listening for a shortcut, replacing any prior registration.
    func start(
        shortcut: Shortcut = .defaultToggleEQ,
        onPressed: @escaping @MainActor () -> Void
    ) throws {
        stop()
        try installEventHandlerIfNeeded()

        var newHotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: eqForMacHotKeySignature,
            id: eqForMacHotKeyIdentifier
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &newHotKeyRef
        )
        guard status == noErr, let newHotKeyRef else {
            throw RegistrationError.hotKey(status)
        }

        self.onPressed = onPressed
        hotKeyRef = newHotKeyRef
        registeredShortcut = shortcut
    }

    /// Stops listening while keeping the reusable Carbon event handler installed.
    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
        onPressed = nil
    }

    fileprivate func handleHotKey(identifier: UInt32) {
        guard identifier == eqForMacHotKeyIdentifier, isRegistered else { return }
        onPressed?()
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var newEventHandlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            eqForMacHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &newEventHandlerRef
        )
        guard status == noErr, let newEventHandlerRef else {
            throw RegistrationError.eventHandler(status)
        }
        eventHandlerRef = newEventHandlerRef
    }
}
