import SwiftUI

@main
struct PortWizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless mode: `PortWizard --scan` prints the current port table to
        // stdout and exits, without launching the menu-bar UI. Handy for CI
        // smoke tests and quick terminal use.
        if CommandLine.arguments.contains("--scan") {
            HeadlessScan.runAndExit()
        }
    }

    var body: some Scene {
        // The UI lives entirely in the AppDelegate's NSStatusItem popover; this
        // empty Settings scene just satisfies the App protocol's scene requirement.
        Settings { EmptyView() }
    }
}

/// Prints a port report to stdout and exits — used by `--scan`.
enum HeadlessScan {
    static func runAndExit() -> Never {
        do {
            let entries = try PortScanner.scan()
            let listening = entries.filter(\.isListening)
                .sorted { $0.port < $1.port }
            print("Port Wizard — \(listening.count) listening socket(s)\n")
            print("PORT    PROTO  ADDRESS                APP (PID)")
            for e in listening {
                let addr = "\(e.localHost):\(e.port)"
                print(String(format: "%-7d %-6@ %-22@ %@ (%d)",
                             e.port, e.netProtocol.rawValue as NSString,
                             addr as NSString, e.command as NSString, e.pid))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
