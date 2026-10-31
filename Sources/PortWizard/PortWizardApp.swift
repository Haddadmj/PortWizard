import AppKit

/// Plain AppKit rather than a SwiftUI `App`: that protocol demands at least one
/// scene, and the empty `Settings` scene that satisfied it opens as a blank
/// window at launch on recent macOS. A menu-bar agent has no scenes to declare.
@main
enum PortWizardApp {
    @MainActor static func main() {
        // Headless mode: `PortWizard --scan` prints the current port table to
        // stdout and exits, without launching the menu-bar UI. Handy for CI
        // smoke tests and quick terminal use.
        if CommandLine.arguments.contains("--scan") {
            HeadlessScan.runAndExit()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Info.plist says the same, but `swift run` has no Info.plist.
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Never drawn, since an agent app has no menu bar of its own, but it is
    /// where AppKit looks up key equivalents: without the Edit menu, ⌘V and ⌘A
    /// do nothing in the filter field.
    @MainActor private static func mainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Port Wizard",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let menu = NSMenu()
        menu.addItem(withTitle: "Port Wizard", action: nil, keyEquivalent: "").submenu = appMenu
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return menu
    }
}

/// Prints a port report to stdout and exits — used by `--scan`.
enum HeadlessScan {
    static func runAndExit() -> Never {
        do {
            // Hide macOS/Apple system processes by default; pass --all to include them.
            let includeSystem = CommandLine.arguments.contains("--all")
            print(report(try PortScanner.scan(), includeSystem: includeSystem), terminator: "")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func report(_ entries: [PortEntry], includeSystem: Bool) -> String {
        let listening = entries
            .filter { $0.isListening && (includeSystem || !$0.isSystem) }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
        let hidden = includeSystem ? 0 : entries.filter { $0.isListening && $0.isSystem }.count
        let suffix = hidden > 0 ? " (\(hidden) system hidden — pass --all to show)" : ""

        var lines = [
            "Port Wizard — \(listening.count) listening socket(s)\(suffix)",
            "",
            row("PORT", "PROTO", "ADDRESS", "APP (PID)")
        ]
        for e in listening {
            // Bracketed, so an IPv6 host can't be mistaken for part of the port.
            let host = e.localHost.contains(":") ? "[\(e.localHost)]" : e.localHost
            lines.append(row(String(e.port), e.netProtocol.rawValue,
                             "\(host):\(e.port)", "\(e.command) (\(e.pid))"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One table line. Padded by hand because `String(format:)` ignores the
    /// width of a `%@`, which left the columns unaligned.
    private static func row(_ port: String, _ proto: String, _ address: String, _ app: String) -> String {
        "\(pad(port, 8))\(pad(proto, 7))\(pad(address, 23))\(app)"
    }

    /// Pads without truncating: a long IPv6 address pushes its row out of line
    /// rather than losing the digits that identify it.
    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(1, width - text.count))
    }
}
