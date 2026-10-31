import XCTest
@testable import PortWizard

final class PortRowTests: XCTestCase {

    private func entry(
        pid: Int32 = 1,
        command: String = "node",
        proto: NetProtocol = .tcp,
        host: String = "127.0.0.1",
        port: Int = 8080,
        remote: String? = nil,
        state: String? = "LISTEN",
        path: String? = nil
    ) -> PortEntry {
        PortEntry(pid: pid, command: command, user: "mohammad", netProtocol: proto,
                  family: "IPv4", localHost: host, port: port, remote: remote,
                  state: state, executablePath: path)
    }

    private func onlyRow(_ entries: PortEntry...) throws -> PortRow {
        let rows = PortRow.build(from: entries, filter: .all)
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first)
    }

    // MARK: - Exposure

    func testLoopbackBindsAreNotPublic() {
        for host in ["127.0.0.1", "127.0.1.1", "::1", "localhost", "::ffff:127.0.0.1", "fe80::1%lo0"] {
            XCTAssertFalse(entry(host: host).isPublicBind, host)
        }
    }

    func testWildcardAndInterfaceBindsArePublic() {
        for host in ["*", "0.0.0.0", "::", "192.168.1.4", "2001:db8::1"] {
            XCTAssertTrue(entry(host: host).isPublicBind, host)
        }
    }

    func testUnconnectedUDPIsListeningButConnectedUDPIsNot() {
        XCTAssertTrue(entry(proto: .udp, host: "*", port: 53, state: nil).isListening)
        XCTAssertFalse(entry(proto: .udp, remote: "1.1.1.1:443", state: nil).isListening)
    }

    // MARK: - Addresses

    func testURLBracketsIPv6() throws {
        let row = try onlyRow(entry(host: "2001:db8::1"))
        XCTAssertEqual(row.address, "[2001:db8::1]:8080")
        XCTAssertEqual(row.url?.absoluteString, "http://[2001:db8::1]:8080")
    }

    func testWildcardAndIPv6LoopbackBecomeLocalhost() throws {
        XCTAssertEqual(try onlyRow(entry(host: "*")).url?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(try onlyRow(entry(host: "::1")).url?.absoluteString, "http://localhost:8080")
    }

    func testTLSPortsUseHTTPS() throws {
        XCTAssertEqual(try onlyRow(entry(port: 443)).url?.scheme, "https")
    }

    func testOnlyTCPListenersHaveAURL() throws {
        XCTAssertNil(try onlyRow(entry(proto: .udp, state: nil)).url)
        XCTAssertNil(try onlyRow(entry(remote: "1.1.1.1:443", state: "ESTABLISHED")).url)
    }

    // MARK: - App names

    func testHelperResolvesToItsOutermostApp() throws {
        let path = "/Applications/Brave Browser.app/Contents/Frameworks/Brave.framework"
            + "/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"
        let row = try onlyRow(entry(command: "Brave Browser H", path: path))
        XCTAssertEqual(row.appBundlePath, "/Applications/Brave Browser.app")
        XCTAssertEqual(row.displayName, "Brave Browser")
    }

    func testBareExecutableKeepsItsCommandName() throws {
        let row = try onlyRow(entry(path: "/opt/homebrew/bin/node"))
        XCTAssertNil(row.appBundlePath)
        XCTAssertEqual(row.displayName, "node")
    }

    // MARK: - Grouping

    func testIPv4AndIPv6BindsMergeIntoOneRow() throws {
        let row = try onlyRow(entry(host: "*"), entry(host: "::1"))
        XCTAssertEqual(row.hosts, ["*", "::1"])
        XCTAssertTrue(row.isPublicBind)
    }

    func testFiltersSplitListenersFromConnections() {
        let entries = [entry(), entry(port: 5000, remote: "1.1.1.1:443", state: "ESTABLISHED")]
        XCTAssertEqual(PortRow.build(from: entries, filter: .listening).map(\.port), [8080])
        XCTAssertEqual(PortRow.build(from: entries, filter: .connections).map(\.port), [5000])
        XCTAssertEqual(PortRow.build(from: entries, filter: .all).count, 2)
    }

    func testConnectionRowCollectsRemotes() throws {
        let row = try onlyRow(
            entry(remote: "1.1.1.1:443", state: "ESTABLISHED"),
            entry(remote: "8.8.8.8:443", state: "ESTABLISHED")
        )
        XCTAssertEqual(row.remotes, ["1.1.1.1:443", "8.8.8.8:443"])
    }

    func testSortsExposedThenLocalThenConnections() {
        let rows = PortRow.build(from: [
            entry(port: 1, remote: "1.1.1.1:443", state: "ESTABLISHED"),
            entry(port: 2),
            entry(host: "*", port: 3)
        ], filter: .all)
        XCTAssertEqual(rows.map(\.section), [.exposed, .local, .connections])
    }

    func testWorkersSharingAPortKeepAStableOrder() {
        let workers = (1...20).map { entry(pid: Int32($0)) }
        for _ in 0..<5 {
            XCTAssertEqual(
                PortRow.build(from: workers.shuffled(), filter: .all).map(\.pid),
                (1...20).map { Int32($0) }
            )
        }
    }

    // MARK: - Search

    func testSearchCoversNameCommandPortPIDAndAddresses() {
        let chrome = entry(
            pid: 777, command: "Google Chrome H", host: "192.168.1.4", port: 5000,
            remote: "140.82.112.25:443", state: "ESTABLISHED",
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        for query in ["google chrome", "chrome h", "5000", "777", "192.168", "140.82"] {
            XCTAssertEqual(PortRow.build(from: [chrome], filter: .all, search: query).count, 1, query)
        }
        XCTAssertTrue(PortRow.build(from: [chrome], filter: .all, search: "nginx").isEmpty)
    }

    func testSearchIgnoresCaseAndSurroundingSpace() {
        XCTAssertEqual(PortRow.build(from: [entry()], filter: .all, search: "  NODE ").count, 1)
    }

    // MARK: - Headless report

    func testReportColumnsLineUp() {
        let report = HeadlessScan.report(
            [entry(port: 7265), entry(command: "ollama", port: 11434)], includeSystem: true
        )
        let lines = report.split(separator: "\n").suffix(3).map(String.init)
        let addressColumn = lines[0].distance(
            from: lines[0].startIndex, to: lines[0].range(of: "ADDRESS")!.lowerBound
        )
        for line in lines.dropFirst() {
            let column = line.distance(
                from: line.startIndex, to: line.range(of: "127.0.0.1")!.lowerBound
            )
            XCTAssertEqual(column, addressColumn, line)
        }
    }

    func testReportCountsHiddenSystemSockets() {
        let system = entry(command: "rapportd", path: "/usr/libexec/rapportd")
        XCTAssertTrue(HeadlessScan.report([system], includeSystem: false).contains("1 system hidden"))
        XCTAssertFalse(HeadlessScan.report([system], includeSystem: true).contains("hidden"))
    }

    // MARK: - Signals

    func testSignalRefusesPIDsThatMeanSomethingElse() {
        for pid: Int32 in [-1, 0, 1] {
            XCTAssertThrowsError(try ProcessActions.signal(pid: pid, sig: 0), "\(pid)")
        }
    }
}
