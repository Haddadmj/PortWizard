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
struct PortEntry: Identifiable, Hashable, Sendable {
    let id = UUID()

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

    /// A listening socket is "exposed" — accepting inbound connections.
    var isListening: Bool { state == "LISTEN" }

    /// True when bound to a wildcard/all-interfaces address (reachable off-host).
    var isPublicBind: Bool {
        localHost == "*" || localHost == "0.0.0.0" || localHost == "::"
    }
}
