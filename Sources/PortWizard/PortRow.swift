import Foundation

/// A port grouped with the process using it, ready for display.
///
/// lsof reports one row per file descriptor, so a single listening port often
/// appears twice (IPv4 + IPv6). We collapse those into one row keyed by
/// (port, protocol, command, pid, listening-vs-connected).
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
    /// Distinct remote endpoints collapsed into this row (connections only).
    let remotes: [String]
    /// Absolute path to the owning executable, if resolved.
    let executablePath: String?

    /// The `.app` this process belongs to, if any.
    var appBundlePath: String? { Self.appBundle(containing: executablePath) }

    /// The app's name when it has a bundle, so a helper process reads as the
    /// app the user knows (`Brave Browser`, not `Brave Browser Helper`).
    /// Everything else — node, nginx, postgres — goes by its command name.
    var displayName: String {
        guard let bundle = appBundlePath else { return command }
        return URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
    }

    /// The outermost `.app` in an executable path. Outermost because helpers
    /// are themselves `.app`s nested inside the app they serve.
    static func appBundle(containing path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<path.index(before: range.upperBound)])
    }

    /// A host suitable for building an address — a concrete interface address,
    /// mapping wildcard and IPv6 loopback binds to `localhost`. A remaining
    /// IPv6 address is bracketed, without which its colons read as the port's.
    var reachableHost: String {
        guard let concrete = hosts.first(where: { !PortEntry.wildcardHosts.contains($0) }),
              concrete != "::1"
        else { return "localhost" }
        return concrete.contains(":") ? "[\(concrete)]" : concrete
    }

    var address: String { "\(reachableHost):\(port)" }

    /// Where a browser would reach this port, or nil if it isn't plausibly a
    /// web server: only TCP listeners qualify.
    var url: URL? {
        guard isListening, netProtocol == .tcp else { return nil }
        let scheme = port == 443 || port == 8443 ? "https" : "http"
        return URL(string: "\(scheme)://\(address)")
    }

    var protocolLabel: String { netProtocol.rawValue }

    var hostSummary: String {
        hosts.map { PortEntry.wildcardHosts.contains($0) ? "all interfaces" : $0 }
            .joined(separator: ", ")
    }

    var section: PortSection {
        guard isListening else { return .connections }
        return isPublicBind ? .exposed : .local
    }

    /// Whether this row matches a lowercased, trimmed search query.
    func matches(_ query: String) -> Bool {
        displayName.lowercased().contains(query)
            || command.lowercased().contains(query)
            || String(port).contains(query)
            || String(pid).contains(query)
            || hosts.contains { $0.lowercased().contains(query) }
            || remotes.contains { $0.lowercased().contains(query) }
    }

    /// Collapse raw entries into sorted display rows for a filter and search.
    static func build(
        from entries: [PortEntry], filter: PortFilter, search: String = ""
    ) -> [PortRow] {
        struct Key: Hashable {
            let port: Int
            let proto: NetProtocol
            let command: String
            let pid: Int32
            let listening: Bool
        }
        var groups: [Key: [PortEntry]] = [:]
        for e in entries {
            switch filter {
            case .listening where !e.isListening: continue
            case .connections where e.isListening: continue
            default: break
            }
            let key = Key(port: e.port, proto: e.netProtocol,
                          command: e.command, pid: e.pid, listening: e.isListening)
            groups[key, default: []].append(e)
        }

        var built: [PortRow] = groups.map { key, members in
            PortRow(
                id: "\(key.pid)-\(key.proto.rawValue)-\(key.port)-\(key.listening)",
                port: key.port,
                netProtocol: key.proto,
                command: key.command,
                pid: key.pid,
                user: members.first?.user ?? "",
                isListening: key.listening,
                isPublicBind: members.contains(where: \.isPublicBind),
                hosts: orderedUnique(members.map(\.localHost)),
                remotes: orderedUnique(members.compactMap(\.remote)),
                executablePath: members.first?.executablePath
            )
        }

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { built = built.filter { $0.matches(query) } }

        // The pid is the last tie-break because `groups` iterates in a random
        // order: without it, two workers sharing a port swap places every scan.
        built.sort {
            if $0.section != $1.section { return $0.section < $1.section }
            if $0.port != $1.port { return $0.port < $1.port }
            let names = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if names != .orderedSame { return names == .orderedAscending }
            return $0.pid < $1.pid
        }
        return built
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// How the panel groups its rows, most urgent first.
enum PortSection: Int, CaseIterable, Comparable, Identifiable {
    case exposed, local, connections

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .exposed: return "Reachable from the network"
        case .local: return "This Mac only"
        case .connections: return "Connections"
        }
    }

    var symbol: String {
        switch self {
        case .exposed: return "globe"
        case .local: return "lock"
        case .connections: return "arrow.left.arrow.right"
        }
    }

    static func < (a: PortSection, b: PortSection) -> Bool { a.rawValue < b.rawValue }
}

/// Which kinds of ports to show.
enum PortFilter: String, CaseIterable, Identifiable {
    case listening = "Listening"
    case connections = "Connections"
    case all = "All"
    var id: String { rawValue }
}
