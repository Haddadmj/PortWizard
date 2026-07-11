import AppKit
import Combine
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
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

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

        // Initial scan, then keep the list + badge fresh on the chosen cadence.
        Task { await model.refresh(); updateBadge() }

        // Reschedule the auto-refresh timer whenever the user changes the
        // interval in the popover footer.
        model.$refreshInterval
            .sink { [weak self] interval in self?.scheduleAutoRefresh(interval) }
            .store(in: &cancellables)

        // Hold the popover open while a modal dialog is showing, then restore
        // transient (click-outside-to-close) behaviour.
        model.$modalActive
            .sink { [weak self] active in
                self?.popover.behavior = active ? .applicationDefined : .transient
            }
            .store(in: &cancellables)
    }

    /// (Re)install the background re-scan timer for the given interval, or tear
    /// it down entirely when set to Manual.
    private func scheduleAutoRefresh(_ interval: RefreshInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let seconds = interval.seconds else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.model.refresh()
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
