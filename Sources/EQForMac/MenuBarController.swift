import AppKit
import SwiftUI

@available(macOS 14.2, *)
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let viewModel: EQViewModel
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var settingsWindowController: SettingsWindowController!
    private var lastScrollAdjustment = Date.distantPast

    init(viewModel: EQViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
        setupPopover()
        settingsWindowController = SettingsWindowController(model: viewModel)
        installScrollMonitors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsFromNotification(_:)),
            name: .showEQForMacSettings,
            object: nil
        )
        viewModel.refreshIcon = { [weak self] in
            self?.updateIcon()
        }
        updateIcon()
        // The guided onboarding in the panel decides when to request access.
        viewModel.refreshPermission()
    }

    deinit {
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
        }
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "slider.vertical.3",
                accessibilityDescription: "EQ for Mac"
            )
            button.image?.isTemplate = true
            button.toolTip = "EQ for Mac"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Send both left and right mouse clicks to our action.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 700)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: EQPopoverView(model: viewModel)
        )
    }

    // MARK: - Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp
            || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else if event.modifierFlags.contains(.option) {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            removeEventMonitor()
        } else {
            viewModel.refreshPermission()
            // Refresh hosting view content size after first show
            popover.contentViewController = NSHostingController(
                rootView: EQPopoverView(model: viewModel)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.isHighlighted = true
            installEventMonitor()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        if popover.isShown {
            popover.performClose(nil)
            removeEventMonitor()
        }

        let menu = NSMenu()

        let title = NSMenuItem(title: "EQ for Mac", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: viewModel.eqEnabled ? "Turn EQ Off" : "Turn EQ On",
            action: #selector(toggleEQFromMenu(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let open = NSMenuItem(
            title: "Show EQ Panel",
            action: #selector(openPanelFromMenu(_:)),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit EQ for Mac",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        // Pop up under the status item.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear so left-click goes back to our custom action.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func toggleEQFromMenu(_ sender: Any?) {
        viewModel.toggleEQ()
        updateIcon()
    }

    @objc private func openPanelFromMenu(_ sender: Any?) {
        togglePopover()
    }

    @objc private func quitApp(_ sender: Any?) {
        viewModel.audioEngine.stop()
        NSApp.terminate(nil)
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        settingsWindowController.show()
    }

    @objc private func showSettingsFromNotification(_ notification: Notification) {
        if popover.isShown {
            popover.performClose(nil)
            removeEventMonitor()
        }
        settingsWindowController.show()
    }

    // MARK: - Compact controls

    private func showQuickMenu() {
        if popover.isShown {
            popover.performClose(nil)
            removeEventMonitor()
        }

        let menu = NSMenu()
        let status = NSMenuItem(
            title: "\(viewModel.selectedPresetName) · \(String(format: "%+.1f dB", viewModel.preampDB))",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let bypass = NSMenuItem(
            title: viewModel.isBypassed ? "Resume Processing" : "Bypass",
            action: #selector(toggleBypassFromMenu(_:)),
            keyEquivalent: "b"
        )
        bypass.target = self
        menu.addItem(bypass)

        let down = NSMenuItem(
            title: "Preamp −0.5 dB",
            action: #selector(lowerPreampFromMenu(_:)),
            keyEquivalent: ""
        )
        down.target = self
        menu.addItem(down)

        let up = NSMenuItem(
            title: "Preamp +0.5 dB",
            action: #selector(raisePreampFromMenu(_:)),
            keyEquivalent: ""
        )
        up.target = self
        menu.addItem(up)

        menu.addItem(.separator())
        for preset in viewModel.presetStore.builtIn.prefix(6) {
            let item = NSMenuItem(
                title: preset.name,
                action: #selector(applyPresetFromQuickMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset
            item.state = viewModel.selectedUserPresetID == nil
                && viewModel.selectedHeadphoneName == nil
                && viewModel.selectedPresetName == preset.name
                ? .on
                : .off
            menu.addItem(item)
        }

        present(menu: menu)
    }

    @objc private func toggleBypassFromMenu(_ sender: Any?) {
        viewModel.toggleBypass()
    }

    @objc private func lowerPreampFromMenu(_ sender: Any?) {
        viewModel.adjustPreamp(by: -0.5)
    }

    @objc private func raisePreampFromMenu(_ sender: Any?) {
        viewModel.adjustPreamp(by: 0.5)
    }

    @objc private func applyPresetFromQuickMenu(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? EQPreset else { return }
        viewModel.applyBuiltInPreset(preset)
    }

    private func present(menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - Icon

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if viewModel.eqEnabled && viewModel.audioEngine.isRunning && viewModel.isBypassed {
            symbol = "waveform.slash"
        } else if viewModel.eqEnabled && viewModel.audioEngine.isRunning {
            symbol = "slider.vertical.3"
        } else if viewModel.eqEnabled {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "slider.horizontal.3"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EQ for Mac")
        button.image?.isTemplate = true
        button.appearsDisabled = !viewModel.eqEnabled
        if viewModel.eqEnabled {
            let state = viewModel.isBypassed ? "BYPASSED" : "ON"
            button.toolTip = """
            EQ for Mac — \(state)
            \(viewModel.selectedPresetName) · \(String(format: "%+.1f dB", viewModel.preampDB))
            Scroll to adjust preamp · Option-click for quick controls
            """
        } else {
            button.toolTip = "EQ for Mac — OFF · Option-click for quick controls"
        }
    }

    // MARK: - Scroll-to-adjust preamp

    private func installScrollMonitors() {
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self, self.pointerIsOverStatusItem() else { return event }
            self.handleStatusItemScroll(event)
            return nil
        }

        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            Task { @MainActor in
                guard let self, self.pointerIsOverStatusItem() else { return }
                self.handleStatusItemScroll(event)
            }
        }
    }

    private func pointerIsOverStatusItem() -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        return rectOnScreen.contains(NSEvent.mouseLocation)
    }

    private func handleStatusItemScroll(_ event: NSEvent) {
        guard abs(event.scrollingDeltaY) >= 0.1,
              Date().timeIntervalSince(lastScrollAdjustment) >= 0.055
        else { return }
        lastScrollAdjustment = Date()
        viewModel.adjustPreamp(by: event.scrollingDeltaY > 0 ? 0.5 : -0.5)
        updateIcon()
    }

    // MARK: - Click-outside to dismiss

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
            self.statusItem.button?.isHighlighted = false
            self.removeEventMonitor()
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
