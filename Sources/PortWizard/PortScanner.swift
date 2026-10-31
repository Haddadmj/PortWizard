import Darwin
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
        case timedOut

        var errorDescription: String? {
            switch self {
            case .launchFailed(let msg): return "Could not run lsof: \(msg)"
            case .timedOut: return "lsof took too long to answer, so the scan was abandoned."
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

        // Enrich with executable paths so system vs. user processes can be told
        // apart (see PortEntry.isSystem). One lookup per process, not per socket.
        var paths: [Int32: String] = [:]
        for i in entries.indices {
            let pid = entries[i].pid
            if paths[pid] == nil { paths[pid] = executablePath(pid: pid) }
            entries[i].executablePath = paths[pid]
        }
        return entries
    }

    /// The absolute path of a process's executable, from the kernel. Unlike
    /// `ps -o comm`, which reports argv[0], this stays absolute however the
    /// process was launched — `node` from a shell included.
    static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
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

    /// How long `lsof` gets before the scan is abandoned. A healthy scan takes
    /// a fraction of a second; a wedged one must not stall every later refresh.
    private static let timeout: TimeInterval = 15

    /// Run `lsof` and return its stdout.
    private static func run(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        // Not a Pipe: nothing would drain it, and enough warnings on an unread
        // pipe would block lsof forever.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ScanError.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal { throw ScanError.timedOut }
        // lsof exits non-zero (1) when some sockets are inaccessible even though
        // it printed usable output, so we don't treat exit status as fatal.
        // Lossy on purpose: one process name that isn't valid UTF-8 must not
        // turn the whole scan into an empty list.
        return String(decoding: data, as: UTF8.self)
    }
}
