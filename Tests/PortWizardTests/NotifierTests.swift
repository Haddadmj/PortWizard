import XCTest
@testable import PortWizard

/// Covers which exposed ports are allowed to raise a notification.
///
/// The regression these guard: Apple's Continuity daemons (`rapportd`,
/// `sharingd`, `identityservicesd`) bind *ephemeral* wildcard ports that change
/// on every rebind, so an unfiltered diff notified about them endlessly.
@MainActor
final class NotifierTests: XCTestCase {

    private func entry(
        command: String,
        path: String?,
        port: Int,
        host: String = "*",
        state: String? = "LISTEN",
        user: String = "mohammad"
    ) -> PortEntry {
        var e = PortEntry(
            pid: 1, command: command, user: user, netProtocol: .tcp,
            family: "IPv4", localHost: host, port: port, remote: nil, state: state
        )
        e.executablePath = path
        return e
    }

    func testSystemDaemonsAreNotNotifiableByDefault() {
        let notifier = PortNotifier()
        for (command, path) in [
            ("rapportd", "/usr/libexec/rapportd"),
            ("sharingd", "/usr/libexec/sharingd"),
            ("ControlCenter", "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")
        ] {
            XCTAssertFalse(
                notifier.isNotifiable(entry(command: command, path: path, port: 51754)),
                "\(command) should be silent by default"
            )
        }
    }

    func testSystemDaemonsNotifyWhenIncludeSystemIsOn() {
        let notifier = PortNotifier()
        notifier.includeSystem = true
        XCTAssertTrue(notifier.isNotifiable(
            entry(command: "rapportd", path: "/usr/libexec/rapportd", port: 51754)
        ))
    }

    func testUserProcessIsNotifiable() {
        let notifier = PortNotifier()
        XCTAssertTrue(notifier.isNotifiable(
            entry(command: "node", path: "/opt/homebrew/bin/node", port: 8080)
        ))
    }

    func testMutedCommandIsNotNotifiable() {
        let notifier = PortNotifier()
        notifier.mutedCommands = ["node"]
        XCTAssertFalse(notifier.isNotifiable(
            entry(command: "node", path: "/opt/homebrew/bin/node", port: 8080)
        ))
    }

    func testLocalhostAndNonListeningAreNotNotifiable() {
        let notifier = PortNotifier()
        XCTAssertFalse(notifier.isNotifiable(
            entry(command: "node", path: "/opt/homebrew/bin/node", port: 8080, host: "127.0.0.1")
        ))
        XCTAssertFalse(notifier.isNotifiable(
            entry(command: "node", path: "/opt/homebrew/bin/node", port: 8080, state: "ESTABLISHED")
        ))
    }

    func testLANBindIsNotifiable() {
        XCTAssertTrue(PortNotifier().isNotifiable(
            entry(command: "node", path: "/opt/homebrew/bin/node", port: 8080, host: "192.168.1.4")
        ))
    }

    private func udp(port: Int) -> PortEntry {
        PortEntry(pid: 1, command: "dnsd", user: "mohammad", netProtocol: .udp,
                  family: "IPv4", localHost: "*", port: port, remote: nil, state: nil,
                  executablePath: "/opt/homebrew/bin/dnsd")
    }

    func testUDPNotifiesOnlyBelowTheEphemeralRange() {
        let notifier = PortNotifier()
        XCTAssertTrue(notifier.isNotifiable(udp(port: 53)))
        XCTAssertFalse(notifier.isNotifiable(udp(port: 51754)))
    }

    // MARK: - Diffing

    /// A notifier that records what it would have posted.
    private func recordingNotifier() -> (PortNotifier, () -> [Int]) {
        let notifier = PortNotifier()
        notifier.enabled = true
        notifier.authorized = true
        let posted = Posted()
        notifier.post = { posted.ports.append($0.port) }
        return (notifier, { posted.ports })
    }

    private final class Posted { var ports: [Int] = [] }

    private func node(_ port: Int) -> PortEntry {
        entry(command: "node", path: "/opt/homebrew/bin/node", port: port)
    }

    func testFirstScanIsABaselineAndLaterOnesNotify() {
        let (notifier, posted) = recordingNotifier()
        notifier.handle(entries: [node(8080)])
        XCTAssertEqual(posted(), [])
        notifier.handle(entries: [node(8080), node(3000)])
        XCTAssertEqual(posted(), [3000])
    }

    func testTurningNotificationsOffSilencesThem() {
        let (notifier, posted) = recordingNotifier()
        notifier.handle(entries: [node(8080)])
        notifier.enabled = false
        notifier.handle(entries: [node(8080), node(3000)])
        notifier.handle(entries: [node(8080), node(3000), node(4000)])
        XCTAssertEqual(posted(), [])
    }

    func testReEnablingStartsFromAFreshBaseline() {
        let (notifier, posted) = recordingNotifier()
        notifier.handle(entries: [node(8080)])
        notifier.enabled = false
        notifier.enabled = true
        notifier.handle(entries: [node(8080), node(3000)])
        XCTAssertEqual(posted(), [])
    }

    func testKeyDistinguishesDifferentProcessesOnTheSamePort() {
        let node = entry(command: "node", path: nil, port: 8080)
        let python = entry(command: "python3", path: nil, port: 8080)
        XCTAssertNotEqual(PortNotifier.key(for: node), PortNotifier.key(for: python))
    }

    func testKeyIgnoresPIDSoRestartsDoNotRenotify() {
        var restarted = entry(command: "node", path: nil, port: 8080)
        restarted = PortEntry(
            pid: 999, command: restarted.command, user: restarted.user,
            netProtocol: .tcp, family: "IPv4", localHost: "*", port: 8080,
            remote: nil, state: "LISTEN"
        )
        let original = entry(command: "node", path: nil, port: 8080)
        XCTAssertEqual(PortNotifier.key(for: original), PortNotifier.key(for: restarted))
    }
}
