import AppKit
import SwiftUI

/// Owns the menu-bar status item and the popover that hosts the SwiftUI UI.
///
/// The whole app lives in the menu bar (LSUIElement); there is no dock icon or
/// main window. Clicking the status item toggles a popover with the port list.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = PortsViewModel()
    private var badgeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "network",
                accessibilityDescription: "Port Wizard"
            )
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PortsView(model: model) { NSApp.terminate(nil) }
        )

        // Keep the menu-bar badge (listening-port count) fresh in the background.
        Task { await model.refresh(); updateBadge() }
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.popover.isShown { await self.model.refresh() }
                self.updateBadge()
            }
        }
    }

    private func updateBadge() {
        let count = model.listeningCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            Task { await model.refresh(); updateBadge() }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
