import AppKit
import SwiftUI

@available(macOS 14.2, *)
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let viewModel: EQViewModel
    private var popover: NSPopover!
    private var eventMonitor: Any?

    init(viewModel: EQViewModel) {
        self.viewModel = viewModel
        super.init()
        setupStatusItem()
        setupPopover()
        viewModel.refreshIcon = { [weak self] in
            self?.updateIcon()
        }
        updateIcon()
        // Refresh only — don't force the TCC dialog every launch if already granted.
        viewModel.refreshPermission()
        if viewModel.permissionHint {
            viewModel.requestPermissionIfNeeded()
        }
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
        popover.contentSize = NSSize(width: 440, height: 640)
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

    // MARK: - Icon

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if viewModel.eqEnabled && viewModel.audioEngine.isRunning {
            symbol = "slider.vertical.3"
        } else if viewModel.eqEnabled {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "slider.horizontal.3"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EQ for Mac")
        button.image?.isTemplate = true
        button.appearsDisabled = !viewModel.eqEnabled
        button.toolTip = viewModel.eqEnabled
            ? "EQ for Mac — ON (\(viewModel.selectedPresetName))"
            : "EQ for Mac — OFF"
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
