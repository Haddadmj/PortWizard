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
            button.image = StatusIcon.shared
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            // Right-click needs to reach us too, so the settings menu can be
            // opened without first opening the panel.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// Left-click opens the port list; right-click opens the settings menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        // The menu and the popover would otherwise sit on top of each other.
        if popover.isShown { popover.performClose(nil) }
        contextMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    /// The right-click menu: the notification switches, the mute list, and Quit.
    ///
    /// Built fresh on every click rather than kept around, because its contents
    /// are the current settings — a stale copy would show stale checkmarks.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        // Automatic enabling looks for a responder that implements each action
        // and would re-enable the system-services item we deliberately grey out.
        menu.autoenablesItems = false

        let notify = NSMenuItem(
            title: "Notify About Newly Exposed Ports",
            action: #selector(toggleNotifications), keyEquivalent: ""
        )
        notify.target = self
        notify.state = model.notificationsEnabled ? .on : .off
        menu.addItem(notify)

        let system = NSMenuItem(
            title: "Include macOS System Services",
            action: #selector(toggleSystemNotifications), keyEquivalent: ""
        )
        system.target = self
        system.state = model.notifySystemServices ? .on : .off
        system.isEnabled = model.notificationsEnabled
        system.toolTip = "Apple's Continuity daemons rebind ephemeral ports "
            + "constantly, so each rebind reads as a newly exposed port."
        menu.addItem(system)

        menu.addItem(.separator())
        menu.addItem(label("Muted Processes"))

        if model.mutedCommands.isEmpty {
            menu.addItem(label("None — mute one from its row in the panel"))
        } else {
            for command in model.mutedCommands.sorted() {
                let item = NSMenuItem(
                    title: command, action: #selector(unmute(_:)), keyEquivalent: ""
                )
                item.target = self
                item.state = .on
                item.representedObject = command
                item.toolTip = "Unmute \(command)"
                menu.addItem(item)
            }
            let all = NSMenuItem(
                title: "Unmute All", action: #selector(unmuteAll), keyEquivalent: ""
            )
            all.target = self
            menu.addItem(all)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Port Wizard", action: #selector(quit), keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// An inert label — a section heading or a placeholder, not a command.
    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleNotifications() {
        model.notificationsEnabled.toggle()
    }

    @objc private func toggleSystemNotifications() {
        model.notifySystemServices.toggle()
    }

    @objc private func unmute(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        model.toggleMute(command)
    }

    @objc private func unmuteAll() {
        model.unmuteAll()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
