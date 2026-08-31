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
    private var clickOutsideMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIcon.menuBar()
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // We manage dismissal ourselves (see clickOutsideMonitor) rather than
        // using .transient: toggling a live popover's behaviour to keep it open
        // during a modal dialog breaks transient's click-outside monitor, so we
        // own that logic instead and can suspend it while a dialog is showing.
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PortsView(model: model) { NSApp.terminate(nil) }
        )

        // Close the popover on a click anywhere outside our app — unless a modal
        // dialog (the kill confirmation) is currently up. Global monitors only
        // fire for events delivered to *other* apps, so clicks inside the
        // popover never reach here.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, !self.model.modalActive else { return }
                self.popover.performClose(nil)
            }
        }

        // Initial scan, then keep the list + badge fresh on the chosen cadence.
        Task { await model.refresh(); updateBadge() }

        // Reschedule the auto-refresh timer whenever the user changes the
        // interval in the popover footer.
        model.$refreshInterval
            .sink { [weak self] interval in self?.scheduleAutoRefresh(interval) }
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
