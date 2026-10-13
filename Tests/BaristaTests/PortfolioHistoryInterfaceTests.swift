import XCTest
import Cocoa
@testable import Barista

@MainActor
final class PortfolioHistoryInterfaceTests: XCTestCase {
    private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    private func widget() throws -> StockTickerWidget {
        let start = ISO8601DateFormatter().date(from: "2026-10-09T14:00:00Z")!
        let values: [Double] = [100_000, 100_010, 99_000, 100_015, 100_020]
        let points = values.enumerated().map { PortfolioHistoryService.Point(time: start.addingTimeInterval(Double($0.offset) * 600), value: $0.element) }
        let prefs = InMemoryTestPreferences(suiteName: "history-ui-\(UUID().uuidString)")!
        prefs.set(try JSONEncoder().encode(["test": points]), forKey: "barista.portfolioHistory")
        let history = PortfolioHistoryService(defaults: prefs, clock: { start.addingTimeInterval(3600) })
        var config = StockTickerConfig(symbols: ["AAA"], coins: [])
        config.portfolios = [Portfolio(id: "test", name: "Disposable chart fixture", holdings: ["AAA": 1000])]
        config.activePortfolioID = "test"
        config.historyRange = .all
        return StockTickerWidget(config: config, notificationsEnabled: false,
                                 initialQuotes: [MarketQuote(symbol: "AAA", price: 100, change: 0, kind: .stock, sparkline: [])], historyService: history)
    }

    func testDropdownRawControlRebuildsTheActualChartAndPreservesHoldings() throws {
        _ = NSApplication.shared
        let widget = try widget()
        let original = widget.config.portfolios
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        func chart() throws -> PortfolioChartView {
            try XCTUnwrap(allViews(content).compactMap { $0 as? PortfolioChartView }.first)
        }
        func raw() throws -> NSButton {
            try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "portfolio.history.raw" })
        }
        XCTAssertEqual(try chart().samples.count, 4)
        try raw().performClick(nil)
        XCTAssertTrue(widget.config.historyShowsRaw)
        XCTAssertEqual(try chart().samples.count, 5)
        XCTAssertEqual(try chart().samples.map(\.value).min(), 99_000)
        try raw().performClick(nil)
        XCTAssertEqual(try chart().samples.count, 4)
        XCTAssertEqual(widget.config.portfolios, original)
        let saved = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(widget.config))
        XCTAssertFalse(saved.historyShowsRaw)
    }

    func testNativeRangeAndRawControlsUpdateTheVisibleChart() throws {
        _ = NSApplication.shared
        let widget = try widget()
        let controller = MarketbarWindowController(widget: widget)
        let window = try XCTUnwrap(controller.window)
        defer { _ = controller.windowShouldClose(window) }
        let content = try XCTUnwrap(window.contentView)
        let range = try XCTUnwrap(allViews(content).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 6 })
        range.selectedSegment = 5
        XCTAssertTrue(range.sendAction(range.action!, to: range.target))
        let chart = try XCTUnwrap(allViews(content).compactMap { $0 as? PortfolioChartView }.first)
        XCTAssertEqual(chart.samples.count, 4)
        let raw = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "portfolio.history.raw" })
        raw.performClick(nil)
        XCTAssertEqual(chart.samples.count, 5)
        raw.performClick(nil)
        XCTAssertEqual(chart.samples.count, 4)
    }

    func testChartKeyboardInspectionAndShrinkingRangeClearInvalidHover() throws {
        let chart = PortfolioChartView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        chart.samples = [.init(date: .distantPast, value: 100), .init(date: .distantFuture, value: 110)]
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        chart.keyDown(with: right)
        XCTAssertEqual(chart.hoverIndex, 0)
        chart.keyDown(with: right)
        XCTAssertEqual(chart.hoverIndex, 1)
        chart.samples = [.init(date: .distantPast, value: 100)]
        XCTAssertNil(chart.hoverIndex)
    }
}

@MainActor
final class PortfolioIntradayHistoryTests: XCTestCase {
    func testOneDayCurveDoesNotInventMinutesAcrossAWeekendGap() throws {
        let dates = ["2026-10-09T19:50:00Z", "2026-10-09T20:00:00Z", "2026-10-12T13:30:00Z", "2026-10-12T13:40:00Z"]
            .map { ISO8601DateFormatter().date(from: $0)! }
        var quote = MarketQuote(symbol: "AAA", price: 103, change: 0, kind: .stock, sparkline: [])
        quote.minuteTimes = dates.map(\.timeIntervalSince1970)
        quote.minuteCloses = [100, 101, 102, 103]
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 1]),
                                       notificationsEnabled: false, initialQuotes: [quote])
        let series = try XCTUnwrap(widget.intradayPortfolioSeries())
        XCTAssertEqual(series.map(\.date), Array(dates.suffix(2)))
        XCTAssertEqual(series.map(\.value), [102, 103])
    }
}

@MainActor
final class PortfolioRecordedDayTests: XCTestCase {
    func testRecordedDaySurvivesALaterHoldingEditInsteadOfRepricingItsPast() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-09T14:00:00Z")!
        let points = [PortfolioHistoryService.Point(time: start, value: 1000),
                      PortfolioHistoryService.Point(time: start.addingTimeInterval(600), value: 1010)]
        let prefs = InMemoryTestPreferences(suiteName: "recorded-day-\(UUID().uuidString)")!
        let original = try JSONEncoder().encode(["test": points])
        prefs.set(original, forKey: "barista.portfolioHistory")
        let history = PortfolioHistoryService(defaults: prefs, clock: { start.addingTimeInterval(1200) })
        var config = StockTickerConfig(symbols: ["AAA"], coins: [])
        config.portfolios = [Portfolio(id: "test", name: "Disposable", holdings: ["AAA": 1000])]
        config.activePortfolioID = "test"
        var quote = MarketQuote(symbol: "AAA", price: 101, change: 1, kind: .stock, sparkline: [])
        quote.minuteTimes = points.map { $0.time.timeIntervalSince1970 }
        quote.minuteCloses = [100, 101]
        let widget = StockTickerWidget(config: config, notificationsEnabled: false, initialQuotes: [quote], historyService: history)
        XCTAssertEqual(widget.portfolioHistoryPoints(range: .today).map(\.value), [1000, 1010])
        XCTAssertEqual(prefs.data(forKey: "barista.portfolioHistory"), original)
    }

    func testBenchmarkCannotUseAFutureSessionAsIfItWereObservedEarlier() {
        let start = ISO8601DateFormatter().date(from: "2026-10-09T14:00:00Z")!
        var quote = MarketQuote(symbol: "SPY", price: 600, change: 0, kind: .stock, sparkline: [])
        quote.minuteTimes = [start.addingTimeInterval(3600).timeIntervalSince1970, start.addingTimeInterval(3660).timeIntervalSince1970]
        quote.minuteCloses = [599, 600]
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["SPY"], coins: []), notificationsEnabled: false, initialQuotes: [quote])
        XCTAssertNil(widget.intradayBenchmarkSeries(matching: [start, start.addingTimeInterval(600)], startingAt: 1000))
    }
}
