import XCTest
import Cocoa
@testable import Barista

@MainActor
final class MarketbarWindowControlsTests: XCTestCase {
    private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    private func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testSearchAndSortControlsKeepFilteredSelectionAcrossLiveUpdates() throws {
        _ = NSApplication.shared
        let config = StockTickerConfig(symbols: ["AAPL", "MSFT"], coins: [], holdings: ["AAPL": 2, "MSFT": 1], cash: 100)
        let quotes = [
            MarketQuote(symbol: "AAPL", price: 200, change: 1.2, kind: .stock, sparkline: [198, 199, 200]),
            MarketQuote(symbol: "MSFT", price: 400, change: -0.4, kind: .stock, sparkline: [402, 401, 400])
        ]
        let widget = StockTickerWidget(config: config, notificationsEnabled: false, initialQuotes: quotes)
        let controller = MarketbarWindowController(widget: widget)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        defer { _ = controller.windowShouldClose(window) }
        let content = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(allViews(content).compactMap { $0 as? NSSearchField }.first)
        let table = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTableView }.first)

        search.stringValue = "msft"
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(table.numberOfRows, 1)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        widget.setCash(250)
        turnRunLoop()
        XCTAssertEqual(search.stringValue, "msft")
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, 0)

        let nav = try XCTUnwrap(allViews(content).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 })
        nav.selectedSegment = 1
        nav.sendAction(nav.action, to: nav.target)
        XCTAssertTrue(allViews(content).compactMap { $0 as? NSButton }.contains { $0.title == "Enable ultra-fast free refresh" })
    }

    func testMixedCurrencyPortfolioHidesAggregateAndHistoryChart() throws {
        _ = NSApplication.shared
        var config = StockTickerConfig(symbols: ["AAPL", "SAP"], coins: [],
                                       holdings: ["AAPL": 2, "SAP": 3], cash: 500)
        config.costBasis = ["AAPL": 100, "SAP": 80]
        let apple = MarketQuote(symbol: "AAPL", price: 200, change: 1.2, kind: .stock, sparkline: [198, 199, 200])
        var sap = MarketQuote(symbol: "SAP", price: 100, change: -0.4, kind: .stock, sparkline: [101, 100, 100])
        sap.currency = "EUR"
        let widget = StockTickerWidget(config: config, notificationsEnabled: false, initialQuotes: [apple, sap])
        let controller = MarketbarWindowController(widget: widget)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        defer { _ = controller.windowShouldClose(window) }
        let content = try XCTUnwrap(window.contentView)
        let total = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "marketbar.portfolio.total" })
        let chart = try XCTUnwrap(allViews(content).compactMap { $0 as? PortfolioChartView }.first { $0.identifier?.rawValue == "marketbar.portfolio.chart" })
        let chartEmpty = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "marketbar.portfolio.chart-empty" })

        XCTAssertEqual(total.stringValue, "—")
        XCTAssertTrue(chart.samples.isEmpty)
        XCTAssertFalse(chartEmpty.isHidden)
        XCTAssertTrue(chartEmpty.stringValue.contains("mixed currencies"))
        XCTAssertTrue(allViews(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("mixed currencies") })
    }
}
