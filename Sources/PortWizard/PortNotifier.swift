import Foundation
import UserNotifications

/// Posts a local notification when a process starts listening on a
/// network-reachable port (a wildcard/all-interfaces bind), which is both a
/// convenience ("your dev server is up") and a light security signal ("what
/// just opened a port to the network?").
///
/// Notifications require a signed app bundle; when run via `swift run` the
/// UNUserNotificationCenter calls are simply no-ops that fail silently.
@MainActor
final class PortNotifier {
    private var authorized = false
    /// Exposed-port keys seen on the previous scan, to diff against.
    private var known: Set<String>?

    /// Whether macOS/Apple daemons may notify. Off by default: Continuity
    /// services (`rapportd`, `sharingd`, `identityservicesd`) bind *ephemeral*
    /// wildcard ports that change on every rebind, so each rebind looks like a
    /// brand-new exposed port and notifies again — forever.
    var includeSystem = false

    /// Command names the user has muted by hand, for the non-Apple processes
    /// that are just as chatty (Docker, Dropbox, a hot-reloading dev server).
    var mutedCommands: Set<String> = []

    /// Ask the user for notification permission. Call when the feature is
    /// enabled from the UI.
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    /// Forget the baseline so re-enabling doesn't replay old ports as "new".
    ///
    /// Also called whenever the mute set or the system-services switch changes:
    /// ports that were filtered out were never recorded in `known`, so without
    /// a fresh baseline un-muting would fire for every one of them at once.
    func reset() { known = nil }

    /// Whether this socket is allowed to raise a notification at all.
    func isNotifiable(_ entry: PortEntry) -> Bool {
        guard entry.isListening, entry.isPublicBind else { return false }
        guard includeSystem || !entry.isSystem else { return false }
        return !mutedCommands.contains(entry.command)
    }

    /// Identity of an exposed port for diffing purposes.
    ///
    /// The command name is part of the key, not just the port: when one process
    /// hands port 8080 to a different one that is a real change worth hearing
    /// about, and a port-only key would swallow it. The *pid* deliberately is
    /// not — restarting the same dev server would otherwise notify every time.
    static func key(for entry: PortEntry) -> String {
        "\(entry.command)|\(entry.port)/\(entry.netProtocol.rawValue)"
    }

    /// Diff the current exposed (public-bind, listening) ports against the last
    /// scan and notify about any that are newly present.
    func handle(entries: [PortEntry]) {
        let exposed = entries.filter(isNotifiable)
        let current = Dictionary(
            exposed.map { (Self.key(for: $0), $0) },
            uniquingKeysWith: { a, _ in a }
        )

        defer { known = Set(current.keys) }
        // First scan just establishes the baseline — don't fire for everything.
        guard let previous = known, authorized else { return }

        for (key, entry) in current where !previous.contains(key) {
            notify(entry)
        }
    }

    private func notify(_ entry: PortEntry) {
        let content = UNMutableNotificationContent()
        content.title = "New port exposed: \(entry.port)/\(entry.netProtocol.rawValue)"
        content.body = "\(entry.command) is now listening on all interfaces."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
