import XCTest
@testable import PortWizard

final class ParserTests: XCTestCase {

    func testParsesListeningTCP() {
        let sample = """
        p984
        crapportd
        Lmohammad
        f10
        tIPv4
        PTCP
        n*:51033
        TST=LISTEN
        TQR=0
        TQS=0
        f11
        tIPv6
        PTCP
        n[::1]:51033
        TST=LISTEN
        """
        let entries = PortScanner.parse(sample)
        XCTAssertEqual(entries.count, 2)

        let first = entries[0]
        XCTAssertEqual(first.pid, 984)
        XCTAssertEqual(first.command, "rapportd")
        XCTAssertEqual(first.user, "mohammad")
        XCTAssertEqual(first.netProtocol, .tcp)
        XCTAssertEqual(first.localHost, "*")
        XCTAssertEqual(first.port, 51033)
        XCTAssertEqual(first.state, "LISTEN")
        XCTAssertTrue(first.isListening)
        XCTAssertTrue(first.isPublicBind)

        // IPv6 bracketed loopback.
        XCTAssertEqual(entries[1].localHost, "::1")
        XCTAssertEqual(entries[1].port, 51033)
        XCTAssertFalse(entries[1].isPublicBind)
    }

    func testParsesEstablishedConnectionWithRemote() {
        let sample = """
        p1200
        cnode
        Lmohammad
        f23
        tIPv4
        PTCP
        n192.168.1.4:52012->140.82.112.25:443
        TST=ESTABLISHED
        """
        let entries = PortScanner.parse(sample)
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.localHost, "192.168.1.4")
        XCTAssertEqual(e.port, 52012)
        XCTAssertEqual(e.remote, "140.82.112.25:443")
        XCTAssertEqual(e.state, "ESTABLISHED")
        XCTAssertFalse(e.isListening)
    }

    func testParsesUDPWithoutState() {
        let sample = """
        p500
        cmDNSResponder
        L_mdnsresponder
        f8
        tIPv4
        PUDP
        n*:5353
        """
        let entries = PortScanner.parse(sample)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].netProtocol, .udp)
        XCTAssertEqual(entries[0].port, 5353)
        XCTAssertNil(entries[0].state)
    }

    func testSkipsUnparseableWildcardPort() {
        // UDP sockets sometimes report `*:*` — no concrete port to show.
        let sample = """
        p600
        cfoo
        Lmohammad
        f9
        tIPv4
        PUDP
        n*:*
        """
        XCTAssertTrue(PortScanner.parse(sample).isEmpty)
    }

    func testNameParsingBracketedIPv6() {
        let r = PortScanner.parseName("[fe80::1]:8080")
        XCTAssertEqual(r?.host, "fe80::1")
        XCTAssertEqual(r?.port, 8080)
        XCTAssertNil(r?.remote)
    }

    func testNameParsingIPv4WithRemote() {
        let r = PortScanner.parseName("127.0.0.1:3000->127.0.0.1:60000")
        XCTAssertEqual(r?.host, "127.0.0.1")
        XCTAssertEqual(r?.port, 3000)
        XCTAssertEqual(r?.remote, "127.0.0.1:60000")
    }
}
