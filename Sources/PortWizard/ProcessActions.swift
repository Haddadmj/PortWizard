import AppKit
import Foundation

/// Actions the user can take on a process owning a port.
enum ProcessActions {

    /// Send a signal to a pid. Returns true if the syscall succeeded.
    /// `SIGTERM` for a graceful quit, `SIGKILL` to force.
    @discardableResult
    static func signal(pid: Int32, sig: Int32) -> Bool {
        kill(pid, sig) == 0
    }

    /// Best-effort absolute path to a process's executable, via `ps`.
    static func executablePath(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// Reveal the owning executable in Finder, if its path can be resolved.
    static func revealInFinder(pid: Int32) {
        guard let path = executablePath(pid: pid) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
