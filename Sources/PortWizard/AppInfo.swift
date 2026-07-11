import AppKit

/// Resolves a friendly display name and icon for a process id.
///
/// GUI apps (VS Code, Docker, Chrome) are registered with Launch Services, so
/// `NSRunningApplication` gives us their real name and icon. CLI tools and
/// daemons (node, nginx, postgres) are not, so we fall back to the lsof command
/// name and a generic terminal glyph.
///
/// Results are cached per pid — icons and names don't change over a process's
/// lifetime, and lookups happen on every row render.
@MainActor
enum AppInfo {
    struct Info {
        let name: String
        let icon: NSImage?
    }

    private static var cache: [Int32: Info] = [:]

    /// Generic icon used when a process has no Launch Services bundle.
    private static let fallbackIcon = NSImage(
        systemSymbolName: "terminal", accessibilityDescription: nil
    )

    static func lookup(pid: Int32, fallbackCommand: String) -> Info {
        if let hit = cache[pid] { return hit }

        var info = Info(name: fallbackCommand, icon: fallbackIcon)
        if let app = NSRunningApplication(processIdentifier: pid) {
            let name = app.localizedName?.isEmpty == false
                ? app.localizedName! : fallbackCommand
            info = Info(name: name, icon: app.icon ?? fallbackIcon)
        }
        cache[pid] = info
        return info
    }

    /// Drop cached entries whose pids are no longer present, so a reused pid
    /// doesn't show a stale icon. Called after each scan with the live pids.
    static func prune(livePIDs: Set<Int32>) {
        cache = cache.filter { livePIDs.contains($0.key) }
    }
}
