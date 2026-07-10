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

@MainActor
final class PortsViewModel: ObservableObject {
    @Published private(set) var rows: [PortRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    @Published var searchText = "" { didSet { rebuild() } }
    @Published var filter: PortFilter = .exposed { didSet { rebuild() } }
    /// When false (default), macOS/Apple system processes are hidden so only
    /// user-initiated apps (nginx, node, Docker, …) are listed.
    @Published var showSystem = false { didSet { rebuild() } }

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

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let entries = try await Task.detached(priority: .userInitiated) {
                try PortScanner.scan()
            }.value
            allEntries = entries
            lastError = nil
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }
        rebuild()
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
                connectionCount: max(established.count, 1)
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
