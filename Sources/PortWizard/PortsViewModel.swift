import Foundation
import SwiftUI

/// How often the port list re-scans in the background.
enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60

    var id: Int { rawValue }

    /// Timer period, or nil when auto-refresh is off (manual only).
    var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }

    /// Compact label for the footer button.
    var shortLabel: String { self == .off ? "Manual" : "\(rawValue)s" }

    /// Descriptive label for the menu.
    var menuLabel: String {
        switch self {
        case .off: return "Manual (off)"
        case .twoSeconds: return "Every 2 seconds"
        case .fiveSeconds: return "Every 5 seconds"
        case .tenSeconds: return "Every 10 seconds"
        case .thirtySeconds: return "Every 30 seconds"
        case .sixtySeconds: return "Every minute"
        }
    }
}

@MainActor
final class PortsViewModel: ObservableObject {
    @Published private(set) var rows: [PortRow] = []
    /// True while someone is waiting on a refresh. Background re-scans leave it
    /// alone, or the footer would flicker on every tick.
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    /// Why the last quit or force-kill failed, until it is dismissed.
    @Published var actionError: String?

    /// Distinct listening ports currently shown — the menu-bar badge.
    @Published private(set) var listeningCount = 0
    /// System rows the active filter would show if system processes weren't hidden.
    @Published private(set) var hiddenSystemCount = 0

    /// True when notifications are switched on here but denied in System Settings.
    @Published private(set) var notificationsBlocked = false

    /// True while the kill confirmation is on screen. The AppDelegate reads this
    /// so a click outside doesn't close the panel out from under the dialog.
    var modalActive = false

    @Published var searchText = "" { didSet { rebuild() } }
    @Published var filter: PortFilter = .listening { didSet { rebuild() } }
    /// When false (default), macOS/Apple system processes are hidden so only
    /// user-initiated apps (nginx, node, Docker, …) are listed.
    @Published var showSystem = false {
        didSet {
            UserDefaults.standard.set(showSystem, forKey: Self.showSystemKey)
            rebuild()
        }
    }

    /// Background re-scan cadence. Persisted so it survives relaunches; the
    /// AppDelegate observes this to (re)schedule its timer.
    @Published var refreshInterval: RefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: Self.intervalKey)
        }
    }

    /// Notify when a process newly starts listening on a network-exposed port.
    @Published var notificationsEnabled = false {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notifyKey)
            notifier.enabled = notificationsEnabled
            syncNotificationPermission()
        }
    }

    /// Whether macOS/Apple daemons are allowed to notify. Off by default —
    /// Continuity services rebind ephemeral wildcard ports constantly, so every
    /// rebind reads as a newly exposed port.
    @Published var notifySystemServices = false {
        didSet {
            UserDefaults.standard.set(notifySystemServices, forKey: Self.notifySystemKey)
            notifier.includeSystem = notifySystemServices
            notifier.reset()
        }
    }

    /// Command names muted from notifications by hand — the escape hatch for
    /// chatty processes that aren't Apple daemons and so aren't covered by
    /// `notifySystemServices`.
    @Published private(set) var mutedCommands: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(mutedCommands.sorted(), forKey: Self.mutedKey)
            notifier.mutedCommands = mutedCommands
            notifier.reset()
        }
    }

    private static let intervalKey = "refreshIntervalSeconds"
    private static let showSystemKey = "showSystemProcesses"
    private static let notifyKey = "notificationsEnabled"
    private static let notifySystemKey = "notifySystemServices"
    private static let mutedKey = "mutedCommands"
    private let notifier = PortNotifier()

    init() {
        // Default to 5s — frequent enough to feel live without hammering lsof.
        let stored = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
        refreshInterval = stored.flatMap(RefreshInterval.init(rawValue:)) ?? .fiveSeconds

        // didSet does not run for these during init, so the notifier is synced
        // by hand rather than relying on the property observers.
        showSystem = UserDefaults.standard.bool(forKey: Self.showSystemKey)
        notifySystemServices = UserDefaults.standard.bool(forKey: Self.notifySystemKey)
        mutedCommands = Set(
            UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? []
        )
        notifier.includeSystem = notifySystemServices
        notifier.mutedCommands = mutedCommands

        notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notifyKey)
        notifier.enabled = notificationsEnabled
        syncNotificationPermission()
    }

    /// Re-check permission when notifications matter, so a change made in System
    /// Settings shows up here. A no-op while the switch is off.
    func syncNotificationPermission() {
        guard notificationsEnabled else {
            notificationsBlocked = false
            return
        }
        notifier.requestAuthorization { [weak self] granted in
            self?.notificationsBlocked = !granted
        }
    }

    /// Whether `command` is currently muted from notifications.
    func isMuted(_ command: String) -> Bool { mutedCommands.contains(command) }

    /// Mute or unmute every port owned by `command`.
    func toggleMute(_ command: String) {
        if mutedCommands.contains(command) {
            mutedCommands.remove(command)
        } else {
            mutedCommands.insert(command)
        }
    }

    /// Clear the whole mute list.
    func unmuteAll() {
        guard !mutedCommands.isEmpty else { return }
        mutedCommands.removeAll()
    }

    /// Signal a row's process, then re-scan once it has had a moment to exit.
    ///
    /// The row can be seconds old by the time the dialog is answered, so the pid
    /// is only trusted if the latest scan still has the same command behind it —
    /// otherwise a reused pid would have an innocent process killed.
    func terminate(_ row: PortRow, signal: Int32) {
        actionError = nil
        if allEntries.contains(where: { $0.pid == row.pid && $0.command == row.command }) {
            do {
                try ProcessActions.signal(pid: row.pid, sig: signal)
            } catch {
                actionError = error.localizedDescription
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            await refresh(userInitiated: true)
        }
    }

    /// All entries from the most recent scan, before filtering.
    private var allEntries: [PortEntry] = []

    /// The scan currently running, if any. Scans can outlast the two-second
    /// cadence, and overlapping ones could finish out of order and overwrite a
    /// newer result with an older one.
    private var scanTask: Task<Void, Never>?
    /// Refreshes someone is waiting on; the loading state lasts until the last.
    private var visibleRefreshes = 0

    /// How long the loading state stays up for a refresh the user asked for.
    ///
    /// A local `lsof` scan returns in well under a frame, so an indicator tied
    /// strictly to the work appears and disappears without ever being seen —
    /// which makes a refresh that worked look like it did nothing.
    private static let minimumVisibleRefresh: TimeInterval = 0.6

    /// - Parameter userInitiated: whether someone is watching for a result —
    ///   the refresh button, opening the panel, or a kill. Background timer
    ///   re-scans pass `false` and are dropped if a scan is already running;
    ///   a watched refresh waits and scans afresh, since the running scan may
    ///   predate whatever prompted it.
    func refresh(userInitiated: Bool = false) async {
        if userInitiated {
            visibleRefreshes += 1
            isLoading = true
        }
        defer {
            if userInitiated {
                visibleRefreshes -= 1
                isLoading = visibleRefreshes > 0
            }
        }
        let startedAt = Date()

        if let running = scanTask {
            guard userInitiated else { return }
            await running.value
        }
        if scanTask == nil {
            scanTask = Task {
                await performScan()
                scanTask = nil
            }
        }
        await scanTask?.value

        guard userInitiated else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < Self.minimumVisibleRefresh {
            try? await Task.sleep(for: .seconds(Self.minimumVisibleRefresh - elapsed))
        }
    }

    private func performScan() async {
        do {
            let entries = try await Task.detached(priority: .userInitiated) {
                try PortScanner.scan()
            }.value
            allEntries = entries
            lastError = nil
            lastUpdated = Date()
            notifier.handle(entries: entries)
        } catch {
            lastError = error.localizedDescription
        }
        rebuild()
    }

    /// Recompute everything derived from the latest scan and the active filters.
    private func rebuild() {
        let visible = showSystem ? allEntries : allEntries.filter { !$0.isSystem }
        rows = PortRow.build(from: visible, filter: filter, search: searchText)

        listeningCount = Set(visible.filter(\.isListening)
            .map { "\($0.port)/\($0.netProtocol.rawValue)" }).count
        hiddenSystemCount = showSystem ? 0 : PortRow.build(
            from: allEntries.filter(\.isSystem), filter: filter
        ).count
    }
}
