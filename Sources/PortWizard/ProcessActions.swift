import AppKit
import Foundation

/// Actions the user can take on a process owning a port.
enum ProcessActions {

    /// Why a signal could not be delivered.
    enum SignalError: Error, LocalizedError {
        case notPermitted(pid: Int32)
        case failed(pid: Int32, code: Int32)

        var errorDescription: String? {
            switch self {
            case .notPermitted(let pid):
                return "macOS didn't allow quitting PID \(pid). It belongs to another user."
            case .failed(let pid, let code):
                return "Couldn't signal PID \(pid): \(String(cString: strerror(code)))."
            }
        }
    }

    /// Send a signal to a pid: `SIGTERM` for a graceful quit, `SIGKILL` to force.
    ///
    /// A pid below 2 is refused outright. `kill` treats 0 as "my whole process
    /// group" and -1 as "everything I may signal", and 1 is launchd — none of
    /// them can be what a row meant.
    static func signal(pid: Int32, sig: Int32) throws {
        guard pid > 1 else { throw SignalError.failed(pid: pid, code: EINVAL) }
        guard kill(pid, sig) != 0 else { return }
        switch errno {
        case ESRCH: return // Already gone, which is what the user wanted.
        case EPERM: throw SignalError.notPermitted(pid: pid)
        case let code: throw SignalError.failed(pid: pid, code: code)
        }
    }

    /// Reveal an executable in Finder.
    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
