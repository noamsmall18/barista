import XCTest
import Cocoa
@testable import Barista

final class PortfolioWebTests: XCTestCase {
    private func request(_ path: String = "/secret/snapshot", headers: String = "Host: 127.0.0.1:54321\r\n") -> Data {
        Data("GET \(path) HTTP/1.1\r\n\(headers)\r\n".utf8)
    }

    func testLocalSessionRequestAndQueryAreAccepted() {
        let path = PortfolioWebServer.authorizedPath(request: request("/secret/chart?symbol=AAPL&range=1D"),
            origin: "http://127.0.0.1:54321", token: "secret")
        XCTAssertEqual(path?.path, "/secret/chart")
        XCTAssertEqual(path?.queryItems?.first?.value, "AAPL")
    }

    func testRejectsOtherSessionsOriginsAndRebindingHosts() {
        for data in [request("/other/snapshot"), request("/secretish/snapshot"),
                     request(headers: "Host: attacker.example\r\n"),
                     request(headers: "Host: 127.0.0.1:54321\r\nOrigin: https://attacker.example\r\n"),
                     request(headers: "Host: 127.0.0.1:54321\r\nHost: attacker.example\r\n"),
                     request(headers: "Host: 127.0.0.1:54321\r\nContent-Length: 12\r\n")] {
            XCTAssertNil(PortfolioWebServer.authorizedPath(request: data, origin: "http://127.0.0.1:54321", token: "secret"))
        }
    }

    func testMissingHoldingsStayMissingAndNonFiniteValuesAreJSONSafe() throws {
        let config = StockTickerConfig(symbols: ["MISSING"], coins: [], holdings: ["MISSING": 2], cash: 100)
        let payload = PortfolioWebSnapshot.make(config: config, quotes: [], indices: [])
        XCTAssertEqual(payload["missingSymbols"] as? [String], ["MISSING"])
        XCTAssertTrue(PortfolioWebSnapshot.number(Double.nan) is NSNull)
        XCTAssertTrue(PortfolioWebSnapshot.number(Double.infinity) is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testPanelFitsSecondaryScreenWithNegativeCoordinates() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let frame = StatusDropdownPanel.placement(anchor: NSRect(x: -20, y: 875, width: 20, height: 25),
            size: NSSize(width: 460, height: 1200), screen: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertLessThan(frame.maxY, 875)
        XCTAssertTrue(StatusDropdownPanel.spaceBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(StatusDropdownPanel.spaceBehavior.contains(.canJoinAllApplications))
    }
}
