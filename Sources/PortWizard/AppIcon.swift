import AppKit

/// Resolves the icon for an app bundle.
///
/// Keyed by bundle path rather than pid: an icon belongs to the bundle, so
/// every helper of an app shares one entry and a reused pid can't show a stale
/// icon. The set of bundles on a machine is small enough to never evict.
@MainActor
enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(forBundle path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
