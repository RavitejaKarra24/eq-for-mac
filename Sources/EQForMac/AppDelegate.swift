import AppKit
import CoreGraphics

@available(macOS 14.2, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private var audioEngine: AudioEngine!
    private var presetStore: PresetStore!
    private var viewModel: EQViewModel!
    private var wasRunningBeforeSleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only — no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Check permission without nagging if already granted (CGPreflight is flaky).
        PermissionMonitor.shared.refresh()
        if PermissionMonitor.shared.shouldShowBanner {
            PermissionMonitor.shared.requestAccess()
        }

        audioEngine = AudioEngine()
        presetStore = PresetStore()
        viewModel = EQViewModel(audioEngine: audioEngine, presetStore: presetStore)
        menuBarController = MenuBarController(viewModel: viewModel)

        // Sleep / wake: pause and resume the engine cleanly.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSleep()
            }
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }

        // Minimal Edit menu so text fields support copy/paste in the popover.
        installMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioEngine?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // No dock icon normally; if somehow reopened, no-op.
        return false
    }

    // MARK: - Sleep / wake

    private func handleSleep() {
        wasRunningBeforeSleep = audioEngine.isRunning
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func handleWake() {
        if wasRunningBeforeSleep && viewModel.eqEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.audioEngine.setEnabled(true)
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit EQ for Mac",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Entry point

@main
enum EQForMacMain {
    // Strong reference — NSApplication.delegate is weak.
    nonisolated(unsafe) static var retainedDelegate: AnyObject?

    static func main() {
        let app = NSApplication.shared

        if #available(macOS 14.2, *) {
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            retainedDelegate = delegate
            app.delegate = delegate
            app.run()
        } else {
            app.setActivationPolicy(.regular)
            let alert = NSAlert()
            alert.messageText = "macOS 14.2 or newer required"
            alert.informativeText = """
            EQ for Mac uses Core Audio Taps (introduced in macOS 14.2) to apply \
            equalization to all system audio without installing a virtual driver.
            """
            alert.runModal()
        }
    }
}
