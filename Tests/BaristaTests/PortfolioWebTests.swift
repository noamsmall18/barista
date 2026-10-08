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

    func testSnapshotNetsAuthorizedNegativeCashAgainstPortfolioValue() throws {
        let config = StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 2], cash: -50)
        let quote = MarketQuote(symbol: "AAA", price: 100, change: 0, kind: .stock, sparkline: [])

        let payload = PortfolioWebSnapshot.make(config: config, quotes: [quote], indices: [])
        let summary = try XCTUnwrap(payload["summary"] as? [String: Any])
        let row = try XCTUnwrap((payload["quotes"] as? [[String: Any]])?.first)

        XCTAssertEqual(summary["cash"] as? Double, -50)
        XCTAssertEqual(summary["liveTotal"] as? Double, 150)
        XCTAssertEqual(summary["regularTotal"] as? Double, 150)
        XCTAssertEqual(try XCTUnwrap(row["weight"] as? Double), 200.0 / 150.0 * 100, accuracy: 0.0001)
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

    func testNotebookWritesRequireExactRouteSameOriginAndJSON() {
        let body = Data("{\"symbol\":\"AAPL\",\"note\":{\"thesis\":\"Evidence\",\"risks\":\"\",\"catalysts\":\"\"}}".utf8)
        func post(path: String = "/secret/workspace", origin: String? = "http://127.0.0.1:54321", type: String = "application/json") -> Data {
            var header = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            if let origin { header += "Origin: \(origin)\r\n" }
            return Data((header + "\r\n").utf8) + body
        }
        XCTAssertNotNil(PortfolioWebServer.authorizedPath(request: post(), origin: "http://127.0.0.1:54321", token: "secret"))
        for invalid in [post(path: "/secret/snapshot"), post(origin: nil), post(origin: "https://evil.example"), post(type: "text/plain")] {
            XCTAssertNil(PortfolioWebServer.authorizedPath(request: invalid, origin: "http://127.0.0.1:54321", token: "secret"))
        }
    }

    func testFragmentedNotebookBodyIsNotAuthorizedUntilComplete() {
        let body = Data("{\"symbol\":\"AAPL\",\"note\":{\"thesis\":\"☕\",\"risks\":\"\",\"catalysts\":\"\"}}".utf8)
        let header = Data("POST /secret/workspace HTTP/1.1\r\nHost: 127.0.0.1:54321\r\nOrigin: http://127.0.0.1:54321\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertEqual(PortfolioWebServer.requestLength(header), header.count + body.count)
        XCTAssertNil(PortfolioWebServer.authorizedPath(request: header, origin: "http://127.0.0.1:54321", token: "secret"))
        XCTAssertNotNil(PortfolioWebServer.authorizedPath(request: header + body, origin: "http://127.0.0.1:54321", token: "secret"))
        XCTAssertNil(PortfolioWebServer.authorizedPath(request: header + body + Data("extra".utf8), origin: "http://127.0.0.1:54321", token: "secret"))
        XCTAssertNil(PortfolioWebServer.requestLength(Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)))
        XCTAssertNil(PortfolioWebServer.requestLength(Data("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n".utf8)))
    }

    @MainActor
    func testDropdownResearchButtonLaunchesIndependentWorkspace() throws {
        var launches = 0
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: [], coins: []),
            notificationsEnabled: false, researchOpener: { launches += 1 })
        let root = widget.buildDropdownPopover()
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Open Research Workspace ↗" { return button }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        let action = try XCTUnwrap(button(in: root))
        action.performClick(nil)
        XCTAssertEqual(launches, 1, "The actual dropdown action must dispatch to the independent launcher")
        widget.stop()
        XCTAssertEqual(launches, 1, "Stopping the widget must not own or stop the research process")
    }

}
