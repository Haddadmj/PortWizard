import Foundation

/// Runs `lsof` and parses its machine-readable output into `PortEntry` values.
///
/// We use `lsof -F` (field output) rather than the human table because the
/// table columns shift around depending on address length and state, which
/// makes it fragile to parse. The `-F` format emits one `<tag><value>` token
/// per line and is stable across macOS versions.
enum PortScanner {

    /// Error surfaced when `lsof` cannot be run or fails hard.
    enum ScanError: Error, LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let msg): return "Could not run lsof: \(msg)"
            }
        }
    }

    /// Scan all IPv4/IPv6 TCP and UDP sockets on the system.
    ///
    /// Requires no elevated privileges for the current user's processes; other
    /// users' sockets are included by name where lsof permits.
    static func scan() throws -> [PortEntry] {
        // -n: no DNS, -P: numeric ports, -i: internet files only.
        // Field output tags: p(pid) c(command) L(login) f(fd) t(type)
        // P(protocol) n(name) T(TCP info incl. TST=state).
        let output = try run(arguments: ["-nP", "-i", "-FpcLftnPT"])
        var entries = parse(output)

        // Enrich with executable paths in one batched `ps` call so system vs.
        // user processes can be told apart (see PortEntry.isSystem).
        let paths = executablePaths()
        for i in entries.indices {
            entries[i].executablePath = paths[entries[i].pid]
        }
        return entries
    }

    /// Build a pid → executable-path map for all running processes via one
    /// `ps` invocation. `comm` on macOS reports the full executable path.
    static func executablePaths() -> [Int32: String] {
        guard let output = try? run(
            executable: "/bin/ps",
            arguments: ["-axww", "-o", "pid=", "-o", "comm="]
        ) else { return [:] }

        var map: [Int32: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            let path = trimmed[trimmed.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { map[pid] = path }
        }
        return map
    }

    /// Parse `lsof -F` output into per-socket entries.
    ///
    /// lsof emits a "process set" (p/c/L lines) followed by one "file set"
    /// (f/t/P/n/T… lines) per open descriptor. We carry the current process
    /// context forward and flush an entry at each file boundary.
    static func parse(_ output: String) -> [PortEntry] {
        var entries: [PortEntry] = []

        var pid: Int32 = 0
        var command = ""
        var user = ""

        // Per-file accumulators.
        var family = ""
        var proto: NetProtocol?
        var name: String?
        var state: String?
        var haveFile = false

        func flush() {
            guard haveFile, let proto, let name,
                  let parsed = parseName(name) else {
                haveFile = false
                return
            }
            entries.append(
                PortEntry(
                    pid: pid,
                    command: command,
                    user: user,
                    netProtocol: proto,
                    family: family,
                    localHost: parsed.host,
                    port: parsed.port,
                    remote: parsed.remote,
                    state: state
                )
            )
            haveFile = false
        }

        func resetFile() {
            family = ""
            proto = nil
            name = nil
            state = nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())

            switch tag {
            case "p":
                flush()
                pid = Int32(value) ?? 0
                command = ""
                user = ""
                resetFile()
            case "c":
                command = value
            case "L":
                user = value
            case "f":
                // New file descriptor: flush the previous one, start fresh.
                flush()
                resetFile()
                haveFile = true
            case "t":
                family = value
            case "P":
                proto = NetProtocol(rawValue: value)
            case "n":
                name = value
            case "T":
                // e.g. "ST=LISTEN", "QR=0", "QS=0". We only want the state.
                if value.hasPrefix("ST=") {
                    state = String(value.dropFirst(3))
                }
            default:
                break
            }
        }
        flush()
        return entries
    }

    /// Split an lsof `n` name into local host/port and optional remote endpoint.
    ///
    /// Handles forms like:
    ///   `*:51033`
    ///   `127.0.0.1:8080`
    ///   `[::1]:8080`
    ///   `192.168.1.4:52012->140.82.112.25:443`
    ///   `*:*` (UDP unbound — skipped, port unparseable)
    static func parseName(_ name: String) -> (host: String, port: Int, remote: String?)? {
        let parts = name.components(separatedBy: "->")
        let local = parts[0]
        let remote = parts.count > 1 ? parts[1] : nil

        guard let (host, port) = splitHostPort(local), port > 0 else { return nil }
        return (host, port, remote)
    }

    /// Split `host:port`, tolerating bracketed IPv6 (`[::1]:80`) and bare IPv6.
    private static func splitHostPort(_ s: String) -> (String, Int)? {
        // Bracketed IPv6: [host]:port
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s.index(close, offsetBy: 1)
            guard after < s.endIndex, s[after] == ":" else { return nil }
            let portStr = String(s[s.index(after: after)...])
            guard let port = Int(portStr) else { return nil }
            return (host, port)
        }

        // Otherwise the port is whatever follows the final colon.
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        let portStr = String(s[s.index(after: colon)...])
        guard let port = Int(portStr) else { return nil }
        return (host.isEmpty ? "*" : host, port)
    }

    /// Run a process and return its stdout as a UTF-8 string.
    private static func run(
        executable: String = "/usr/sbin/lsof",
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ScanError.launchFailed(error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof exits non-zero (1) when some sockets are inaccessible even though
        // it printed usable output, so we don't treat exit status as fatal.
        return String(data: data, encoding: .utf8) ?? ""
    }
}
