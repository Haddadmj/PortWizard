import AppKit
import Combine
import SwiftUI

/// The deep link to this Mac's notification preferences.
enum NotificationSettings {
    @MainActor static func open() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Owns the menu-bar status item and the popover that hosts the SwiftUI UI.
///
/// The whole app lives in the menu bar (LSUIElement); there is no dock icon or
/// main window. Clicking the status item toggles a popover with the port list.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PortsView(
                model: model,
                onClose: { [weak self] in self?.popover.performClose(nil) },
                onQuit: { NSApp.terminate(nil) }
            )
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

        // The badge follows the model rather than the timer, so anything that
        // changes the count — the eye toggle, a kill, a manual refresh — shows up.
        model.$listeningCount
            .removeDuplicates()
            .sink { [weak self] count in
                self?.statusItem.button?.title = count > 0 ? " \(count)" : ""
            }
            .store(in: &cancellables)

        // Initial scan, then keep the list + badge fresh on the chosen cadence.
        Task { await model.refresh() }

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
            Task { @MainActor in await self?.model.refresh() }
        }
        // There is no precision to protect here, and a little slack lets macOS
        // batch the wake-ups of an app that is always running.
        refreshTimer?.tolerance = seconds * 0.1
    }

    /// Left-click opens the port list; right-click (or control-click, its
    /// equivalent on a trackpad or one-button mouse) opens the settings menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
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

        if model.notificationsEnabled && model.notificationsBlocked {
            let settings = NSMenuItem(
                title: "Allow Notifications in System Settings…",
                action: #selector(openNotificationSettings), keyEquivalent: ""
            )
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
        }

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(label(["Port Wizard", version].compactMap(\.self).joined(separator: " ")))
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

    @objc private func openNotificationSettings() {
        NotificationSettings.open()
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
            model.syncNotificationPermission()
            Task { await model.refresh(userInitiated: true) }
            // An agent app isn't active by default; until it is, keystrokes keep
            // going to the app underneath instead of the filter field.
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Hand focus back to whichever app was in use before the panel opened.
    func popoverDidClose(_ notification: Notification) {
        NSApp.hide(nil)
    }
}
