import Foundation

/// Transport protocol of a socket.
enum NetProtocol: String, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

/// One open network socket owned by a process, as reported by `lsof`.
///
/// A single process (PID) can own many sockets, so `PortEntry` is deliberately
/// per-socket. The UI groups these by process/port for display.
struct PortEntry: Hashable, Sendable {
    /// Owning process id.
    let pid: Int32
    /// Owning process command name, e.g. `node`, `rapportd`, `Google Chrome H`.
    let command: String
    /// User the process runs as (login name from lsof, may be a uid string).
    let user: String

    let netProtocol: NetProtocol
    /// `IPv4` / `IPv6`.
    let family: String

    /// Local bind host, e.g. `*`, `127.0.0.1`, `::1`, `192.168.1.4`.
    let localHost: String
    /// Local port number.
    let port: Int
    /// Remote endpoint `host:port` for established connections, else nil.
    let remote: String?

    /// TCP state such as `LISTEN`, `ESTABLISHED`. nil for UDP.
    let state: String?

    /// Absolute path to the owning executable, resolved via `proc_pidpath`
    /// after the scan. nil when it could not be determined (e.g. permission denied).
    var executablePath: String?

    /// Whether this socket accepts inbound traffic: a TCP listener, or a UDP
    /// socket with no fixed peer. UDP has no states, so the missing peer is the
    /// only signal — a DNS server on 53 would otherwise never count as open.
    var isListening: Bool {
        state == "LISTEN" || (netProtocol == .udp && remote == nil)
    }

    /// The bind hosts that mean "every interface".
    static let wildcardHosts: Set<String> = ["*", "0.0.0.0", "::"]

    var isWildcardBind: Bool { Self.wildcardHosts.contains(localHost) }

    /// Whether the bind can only be reached from this Mac.
    var isLoopback: Bool {
        localHost == "localhost" || localHost == "::1"
            || localHost.hasPrefix("127.") || localHost.hasPrefix("::ffff:127.")
            || localHost.hasSuffix("%lo0")
    }

    /// True when reachable off-host: a wildcard bind, or a bind to one specific
    /// interface such as `192.168.1.4`, which is just as open to that network.
    var isPublicBind: Bool { !isLoopback }

    /// Whether this belongs to macOS/Apple itself rather than something the user
    /// started (a dev server, a database, Docker, …).
    ///
    /// The primary signal is the executable's path: Apple daemons live under
    /// `/System`, `/usr/libexec`, `/usr/sbin`, etc., while user software lives
    /// in Homebrew/`/usr/local`, `/Applications`, or the home directory. Path is
    /// preferred over owning user because user dev tools (nginx, Docker) often
    /// run as root, and Apple agents often run as the logged-in user.
    var isSystem: Bool {
        if let path = executablePath, !path.isEmpty {
            return Self.systemPathPrefixes.contains { path.hasPrefix($0) }
        }
        // Path unknown: fall back to the owning user and a few well-known daemons.
        if user == "root" || user.hasPrefix("_") { return true }
        return Self.knownSystemCommands.contains(command)
    }

    /// Executable-path prefixes that mark an Apple/system process. Deliberately
    /// conservative — `/usr/bin` and `/usr/local` are excluded so a dev server
    /// launched from them still shows up.
    static let systemPathPrefixes = [
        "/System/",
        "/Library/Apple/",
        "/Library/CoreServices/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/"
    ]

    /// Fallback list of Apple daemon command names, used only when the
    /// executable path can't be resolved.
    static let knownSystemCommands: Set<String> = [
        "rapportd", "mDNSResponder", "ControlCenter", "sharingd", "remoted",
        "launchd", "configd", "netbiosd", "apsd", "identityservicesd",
        "nsurlsessiond", "cloudd", "trustd", "AirPlayXPCHelper", "corednsd"
    ]
}
