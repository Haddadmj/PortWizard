import Foundation
import SwiftUI

/// A port grouped with the process(es) using it, ready for display.
///
/// lsof reports one row per file descriptor, so a single listening port often
/// appears twice (IPv4 + IPv6). We collapse those into one row keyed by
/// (port, protocol, command, listening-vs-connected).
struct PortRow: Identifiable, Hashable {
    let id: String
    let port: Int
    let netProtocol: NetProtocol
    let command: String
    let pid: Int32
    let user: String
    let isListening: Bool
    let isPublicBind: Bool
    /// Distinct local bind hosts collapsed into this row (e.g. `*`, `127.0.0.1`).
    let hosts: [String]
    /// Number of connections collapsed here (established rows only).
    let connectionCount: Int
    /// Absolute path to the owning executable, if resolved.
    let executablePath: String?

    /// A host suitable for building a URL — a concrete loopback/interface
    /// address, mapping wildcard binds to `localhost`.
    var reachableHost: String {
        if let concrete = hosts.first(where: { $0 != "*" && $0 != "0.0.0.0" && $0 != "::" }) {
            return concrete == "::1" ? "localhost" : concrete
        }
        return "localhost"
    }

    /// Only TCP listeners are plausibly openable in a browser.
    var isBrowsable: Bool { isListening && netProtocol == .tcp }

    var protocolLabel: String { netProtocol.rawValue }

    var hostSummary: String {
        hosts.joined(separator: ", ")
    }
}

/// Which kinds of ports to show.
enum PortFilter: String, CaseIterable, Identifiable {
    case exposed = "Listening"
    case connections = "Connections"
    case all = "All"
    var id: String { rawValue }
}

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
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    /// True while a modal (e.g. the kill confirmation dialog) is on screen. The
    /// AppDelegate watches this to stop the transient popover auto-closing —
    /// otherwise the dialog steals key focus and the popover dismisses with it.
    @Published var modalActive = false

    @Published var searchText = "" { didSet { rebuild() } }
    @Published var filter: PortFilter = .exposed { didSet { rebuild() } }
    /// When false (default), macOS/Apple system processes are hidden so only
    /// user-initiated apps (nginx, node, Docker, …) are listed.
    @Published var showSystem = false { didSet { rebuild() } }

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
            if notificationsEnabled {
                notifier.requestAuthorization()
            } else {
                notifier.reset()
            }
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
        notifySystemServices = UserDefaults.standard.bool(forKey: Self.notifySystemKey)
        mutedCommands = Set(
            UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? []
        )
        notifier.includeSystem = notifySystemServices
        notifier.mutedCommands = mutedCommands

        notificationsEnabled = UserDefaults.standard.bool(forKey: Self.notifyKey)
        if notificationsEnabled { notifier.requestAuthorization() }
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

    /// All entries from the most recent scan, before filtering.
    private var allEntries: [PortEntry] = []

    /// Entries after applying the show-system toggle — the pool everything else
    /// (counts, grouping, search) works from.
    private var visibleEntries: [PortEntry] {
        showSystem ? allEntries : allEntries.filter { !$0.isSystem }
    }

    /// Number of hidden system listening ports, for the "show system" hint.
    var hiddenSystemCount: Int {
        showSystem ? 0 : Set(allEntries.filter { $0.isSystem && $0.isListening }
            .map { "\($0.port)/\($0.netProtocol.rawValue)" }).count
    }

    /// Number of exposed (listening) ports currently shown — the menu-bar badge.
    var listeningCount: Int {
        Set(visibleEntries.filter(\.isListening)
            .map { "\($0.port)/\($0.netProtocol.rawValue)" }).count
    }

    /// How long the loading state stays up for a refresh the user asked for.
    ///
    /// A local `lsof` scan returns in well under a frame, so an indicator tied
    /// strictly to the work appears and disappears without ever being seen —
    /// which makes a refresh that worked look like it did nothing.
    ///
    /// Background re-scans deliberately skip the hold: the cadence goes down to
    /// two seconds, and holding there would leave the indicator up almost
    /// permanently, which is its own kind of lie.
    private static let minimumVisibleRefresh: TimeInterval = 0.6

    /// - Parameter userInitiated: whether someone is watching for a result —
    ///   the refresh button, or opening the panel. Background timer re-scans
    ///   pass `false`.
    func refresh(userInitiated: Bool = false) async {
        isLoading = true
        let startedAt = Date()
        defer { isLoading = false }
        do {
            let entries = try await Task.detached(priority: .userInitiated) {
                try PortScanner.scan()
            }.value
            allEntries = entries
            lastError = nil
            lastUpdated = Date()
            AppInfo.prune(livePIDs: Set(entries.map(\.pid)))
            notifier.handle(entries: entries)
        } catch {
            lastError = error.localizedDescription
        }
        rebuild()

        guard userInitiated else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < Self.minimumVisibleRefresh {
            try? await Task.sleep(for: .seconds(Self.minimumVisibleRefresh - elapsed))
        }
    }

    /// Collapse raw entries into display rows, applying the active filter/search.
    private func rebuild() {
        // Group by a stable key so IPv4/IPv6 duplicates merge.
        struct Key: Hashable {
            let port: Int
            let proto: NetProtocol
            let command: String
            let pid: Int32
            let listening: Bool
        }
        var groups: [Key: [PortEntry]] = [:]
        for e in visibleEntries {
            switch filter {
            case .exposed where !e.isListening: continue
            case .connections where e.isListening: continue
            default: break
            }
            let key = Key(port: e.port, proto: e.netProtocol,
                         command: e.command, pid: e.pid, listening: e.isListening)
            groups[key, default: []].append(e)
        }

        var built: [PortRow] = groups.map { key, members in
            let hosts = orderedUnique(members.map(\.localHost))
            let anyPublic = members.contains(where: \.isPublicBind)
            let established = members.filter { $0.state == "ESTABLISHED" || $0.remote != nil }
            return PortRow(
                id: "\(key.pid)-\(key.proto.rawValue)-\(key.port)-\(key.listening)",
                port: key.port,
                netProtocol: key.proto,
                command: key.command,
                pid: key.pid,
                user: members.first?.user ?? "",
                isListening: key.listening,
                isPublicBind: anyPublic,
                hosts: hosts,
                connectionCount: max(established.count, 1),
                executablePath: members.first?.executablePath
            )
        }

        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            built = built.filter { row in
                row.command.lowercased().contains(q)
                    || String(row.port).contains(q)
                    || row.hostSummary.lowercased().contains(q)
                    || String(row.pid).contains(q)
            }
        }

        // Listening first, then by port ascending, then command.
        built.sort {
            if $0.isListening != $1.isListening { return $0.isListening && !$1.isListening }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.command.localizedCaseInsensitiveCompare($1.command) == .orderedAscending
        }
        rows = built
    }

    private func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for i in items where seen.insert(i).inserted { out.append(i) }
        return out
    }
}
