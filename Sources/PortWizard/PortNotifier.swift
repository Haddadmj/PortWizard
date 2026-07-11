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

    /// Ask the user for notification permission. Call when the feature is
    /// enabled from the UI.
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    /// Forget the baseline so re-enabling doesn't replay old ports as "new".
    func reset() { known = nil }

    /// Diff the current exposed (public-bind, listening) ports against the last
    /// scan and notify about any that are newly present.
    func handle(entries: [PortEntry]) {
        let exposed = entries.filter { $0.isListening && $0.isPublicBind }
        let current = Dictionary(
            exposed.map { ("\($0.port)/\($0.netProtocol.rawValue)", $0) },
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
