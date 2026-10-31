import Foundation
import UserNotifications

/// Posts a local notification when a process starts listening on a
/// network-reachable port, which is both a convenience ("your dev server is
/// up") and a light security signal ("what just opened a port to the network?").
///
/// Notifications require an app bundle: `UNUserNotificationCenter.current()`
/// raises an exception without one, so under `swift run` nothing touches it.
@MainActor
final class PortNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// The user's switch. While off, scans neither notify nor keep a baseline,
    /// so turning it back on starts from a clean one.
    var enabled = false {
        didSet { if !enabled { reset() } }
    }

    /// Whether macOS has granted permission to post.
    var authorized = false

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

    /// Delivers one notification. Replaceable so the diffing can be tested
    /// without a notification center.
    var post: (PortEntry) -> Void = PortNotifier.deliver

    /// Where UDP's ephemeral range starts on macOS. Clients bind unconnected
    /// sockets up here all the time, so only ports below it are worth a banner.
    static let firstEphemeralPort = 49152

    /// Ask macOS for permission and report the answer. Prompts only the first
    /// time, so it is also how a later change in System Settings gets noticed.
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return completion(false) }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorized = granted
            completion(granted)
        }
    }

    /// Without this, macOS withholds the banner while the panel is open, because
    /// that makes this the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
        if entry.netProtocol == .udp, entry.port >= Self.firstEphemeralPort { return false }
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

    /// Diff the current exposed ports against the last scan and notify about
    /// any that are newly present.
    func handle(entries: [PortEntry]) {
        guard enabled else { return }

        let exposed = entries.filter(isNotifiable)
        let current = Dictionary(
            exposed.map { (Self.key(for: $0), $0) },
            uniquingKeysWith: { a, _ in a }
        )

        defer { known = Set(current.keys) }
        // First scan just establishes the baseline — don't fire for everything.
        guard let previous = known, authorized else { return }

        for (key, entry) in current where !previous.contains(key) {
            post(entry)
        }
    }

    private nonisolated static func deliver(_ entry: PortEntry) {
        let content = UNMutableNotificationContent()
        content.title = "New port exposed: \(entry.port)/\(entry.netProtocol.rawValue)"
        content.body = entry.isWildcardBind
            ? "\(entry.command) is now listening on all interfaces."
            : "\(entry.command) is now listening on \(entry.localHost)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
