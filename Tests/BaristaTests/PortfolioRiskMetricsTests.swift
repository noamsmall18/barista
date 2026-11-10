import XCTest
import Cocoa
@testable import Barista

@MainActor
final class PortfolioRiskMetricsTests: XCTestCase {
    /// Monday 5 October 2026, 11:00 in New York.
    private let monday = ISO8601DateFormatter().date(from: "2026-10-05T15:00:00Z")!
    /// Daily returns of +1%, -0.5%, +2%, 0% and +1%.
    private let closes: [Double] = [100_000, 101_000, 100_495, 102_504.9, 102_504.9, 103_529.949]
    /// Consecutive sessions: the first week, then the following Monday.
    private let sessionOffsets = [0, 1, 2, 3, 4, 7, 8, 9, 10, 11]

    private func day(_ index: Int) -> Date { monday.addingTimeInterval(Double(sessionOffsets[index]) * 86_400) }
    private func series(_ values: [Double]) -> [(time: Date, value: Double)] {
        values.enumerated().map { (time: day($0.offset), value: $0.element) }
    }
    private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    private func texts(_ root: NSView) -> [String] { allViews(root).compactMap { ($0 as? NSTextField)?.stringValue } }

    // MARK: - Calculation

    func testSharpeAnnualizesExcessDailyReturnsOverSampleDeviation() {
        let metrics = PortfolioRiskMetrics.compute(points: series(closes), continuous: false, riskFreePercent: 4)
        XCTAssertEqual(metrics.dailyReturns, 5)
        XCTAssertEqual(try XCTUnwrap(metrics.sharpe), 11.142308749866883, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics.annualVolatilityPercent), 15.472556349873168, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics.periodReturnPercent), 3.529949, accuracy: 1e-9)
        XCTAssertTrue(metrics.isPreliminary)
        XCTAssertEqual(metrics.coverageText, "5 trading days · early")

        let noRiskFree = PortfolioRiskMetrics.compute(points: series(closes), continuous: false, riskFreePercent: 0)
        XCTAssertEqual(try XCTUnwrap(noRiskFree.sharpe), 11.400830994643377, accuracy: 1e-9)
        let crypto = PortfolioRiskMetrics.compute(points: series(closes), continuous: true, riskFreePercent: 4)
        XCTAssertEqual(try XCTUnwrap(crypto.sharpe), 13.506093580557526, accuracy: 1e-9,
                       "a continuously traded portfolio annualizes over calendar days")
    }

    func testShortFlatAndInvalidHistoriesReportNoRatioRatherThanAGuess() {
        let short = PortfolioRiskMetrics.compute(points: series(Array(closes.prefix(4))), continuous: false)
        XCTAssertNil(short.sharpe)
        XCTAssertEqual(short.dailyReturns, 3)
        XCTAssertEqual(short.coverageText, "Needs 2 more trading days of history")
        XCTAssertNotNil(short.periodReturnPercent)

        let flat = PortfolioRiskMetrics.compute(points: series(Array(repeating: 50_000, count: 7)), continuous: false)
        XCTAssertNil(flat.sharpe, "no variation must not divide by zero")
        XCTAssertEqual(flat.coverageText, "No variation in recorded returns yet")

        XCTAssertEqual(PortfolioRiskMetrics.compute(points: [], continuous: false), .empty)
        let invalid = PortfolioRiskMetrics.compute(points: series([100, .nan, -5, 0, .infinity, 101]), continuous: false)
        XCTAssertEqual(invalid.dailyReturns, 1, "non-finite and non-positive values are never used")
    }

    func testIntradayObservationsCollapseToOneCloseOnTheirTradingDay() {
        var points = series(closes)
        // Minute-level noise earlier in each session must not count as extra days.
        points += closes.indices.map { (time: day($0).addingTimeInterval(-3_600), value: closes[$0] * 0.5) }
        let metrics = PortfolioRiskMetrics.compute(points: points.shuffled(), continuous: false, riskFreePercent: 4)
        XCTAssertEqual(metrics.dailyReturns, 5)
        XCTAssertEqual(try XCTUnwrap(metrics.sharpe), 11.142308749866883, accuracy: 1e-9)

        let cal = PortfolioTradingCalendar.calendar
        let fridayOvernight = ISO8601DateFormatter().date(from: "2026-10-09T01:30:00Z")! // Thursday 21:30 ET
        XCTAssertEqual(PortfolioRiskMetrics.tradingDay(for: fridayOvernight, continuous: false),
                       cal.startOfDay(for: day(4)), "overnight trading belongs to the next session")
        let saturday = day(4).addingTimeInterval(86_400)
        XCTAssertEqual(PortfolioRiskMetrics.tradingDay(for: saturday, continuous: false),
                       cal.startOfDay(for: day(5)), "a closed day rolls forward to Monday")
        XCTAssertEqual(PortfolioRiskMetrics.tradingDay(for: saturday, continuous: true), cal.startOfDay(for: saturday))
    }

    // MARK: - Portfolios

    private func widget(extra: [String: [PortfolioHistoryService.Point]] = [:],
                        combined: Bool = false) throws -> StockTickerWidget {
        func points(_ values: [Double]) -> [PortfolioHistoryService.Point] {
            values.enumerated().map { PortfolioHistoryService.Point(time: day($0.offset), value: $0.element) }
        }
        var stored: [String: [PortfolioHistoryService.Point]] = [
            "growth": points(closes),
            "income": points([50_000, 50_100, 50_050, 50_200, 50_150, 50_300, 50_280, 50_400]),
            "new": points([10_000, 10_050])
        ]
        stored.merge(extra) { _, new in new }
        let prefs = InMemoryTestPreferences(suiteName: "risk-\(UUID().uuidString)")!
        prefs.set(try JSONEncoder().encode(stored), forKey: "barista.portfolioHistory")
        let history = PortfolioHistoryService(defaults: prefs, clock: { self.day(9) })
        var config = StockTickerConfig(symbols: ["AAA"], coins: [])
        config.portfolios = [Portfolio(id: "growth", name: "Growth", holdings: ["AAA": 1000], cash: 500),
                             Portfolio(id: "income", name: "Income", holdings: ["AAA": 500]),
                             Portfolio(id: "new", name: "Brand new", holdings: ["AAA": 100])]
        config.activePortfolioID = "growth"
        config.historyRange = .all
        if combined {
            config.combinedPortfolioEnabled = true
            config.combinedPortfolioHistoryID = "combined-history"
        }
        return StockTickerWidget(config: config, notificationsEnabled: false,
                                 initialQuotes: [MarketQuote(symbol: "AAA", price: 100, change: 0.4, kind: .stock,
                                                             sparkline: [99, 100])],
                                 historyService: history)
    }

    func testEveryPortfolioGetsItsOwnRatioFromItsOwnHistory() throws {
        let widget = try widget()
        let rows = widget.portfolioRiskRows()
        XCTAssertEqual(rows.map(\.name), ["Growth", "Income", "Brand new"])
        XCTAssertEqual(rows.map(\.isActive), [true, false, false])
        XCTAssertEqual(try XCTUnwrap(rows[0].metrics.sharpe), 11.142308749866883, accuracy: 1e-9)
        XCTAssertEqual(rows[1].metrics.dailyReturns, 7)
        XCTAssertNotNil(rows[1].metrics.sharpe)
        XCTAssertNotEqual(rows[0].metrics.sharpe, rows[1].metrics.sharpe)
        XCTAssertNil(rows[2].metrics.sharpe)
        XCTAssertEqual(rows[2].metrics.coverageText, "Needs 4 more trading days of history")
        XCTAssertEqual(widget.activePortfolioRiskMetrics(), rows[0].metrics)

        widget.selectPortfolio(id: "income")
        XCTAssertEqual(widget.portfolioRiskRows().map(\.isActive), [false, true, false])
        XCTAssertEqual(widget.activePortfolioRiskMetrics(), rows[1].metrics)
    }

    func testDepositsAndTradesDoNotCountAsReturns() throws {
        // The same market path as Growth, with $50,000 added on the third day.
        var deposited = closes.enumerated().map { PortfolioHistoryService.Point(time: day($0.offset), value: $0.element) }
        for index in 2..<deposited.count { deposited[index].value += 50_000 * closes[index] / closes[2] }
        deposited[2].flow = 50_000
        let widget = try widget(extra: ["income": deposited])
        let rows = widget.portfolioRiskRows()
        XCTAssertEqual(try XCTUnwrap(rows[1].metrics.sharpe), try XCTUnwrap(rows[0].metrics.sharpe), accuracy: 1e-6,
                       "a cash flow must not be read as a gain")
    }

    func testCombinedPortfolioLeadsAndRiskFreeRateIsSavedAndValidated() throws {
        let combinedHistory = closes.enumerated().map {
            PortfolioHistoryService.Point(time: day($0.offset), value: $0.element * 2)
        }
        let widget = try widget(extra: ["combined-history": combinedHistory], combined: true)
        let rows = widget.portfolioRiskRows()
        XCTAssertEqual(rows.map(\.name), [Portfolio.combinedName, "Growth", "Income", "Brand new"])
        XCTAssertEqual(try XCTUnwrap(rows[0].metrics.sharpe), 11.142308749866883, accuracy: 1e-9)

        XCTAssertEqual(widget.config.riskFreeRatePercent, PortfolioRiskMetrics.defaultRiskFreePercent)
        XCTAssertFalse(widget.setRiskFreeRate(percent: -1))
        XCTAssertFalse(widget.setRiskFreeRate(percent: .nan))
        XCTAssertFalse(widget.setRiskFreeRate(percent: 40))
        XCTAssertEqual(widget.config.riskFreeRatePercent, PortfolioRiskMetrics.defaultRiskFreePercent)
        let original = widget.config.portfolios
        XCTAssertTrue(widget.setRiskFreeRate(percent: 0))
        XCTAssertEqual(try XCTUnwrap(widget.portfolioRiskRows()[1].metrics.sharpe), 11.400830994643377, accuracy: 1e-9,
                       "a new rate must not be served from the cache")
        XCTAssertEqual(widget.config.portfolios, original)

        let saved = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(widget.config))
        XCTAssertEqual(saved.riskFreeRatePercent, 0)
        let legacy = try JSONDecoder().decode(StockTickerConfig.self, from: Data(#"{"symbols":["AAA"]}"#.utf8))
        XCTAssertEqual(legacy.riskFreeRatePercent, PortfolioRiskMetrics.defaultRiskFreePercent)
        let corrupt = try JSONDecoder().decode(StockTickerConfig.self, from: Data(#"{"riskFreeRatePercent":900}"#.utf8))
        XCTAssertEqual(corrupt.riskFreeRatePercent, PortfolioRiskMetrics.defaultRiskFreePercent)
    }

    // MARK: - Interface

    func testWindowShowsActiveRatioAndOneRowPerPortfolioAndFollowsSelection() throws {
        _ = NSApplication.shared
        let widget = try widget()
        let controller = MarketbarWindowController(widget: widget)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        defer { _ = controller.windowShouldClose(window) }
        let content = try XCTUnwrap(window.contentView)
        func field(_ id: String) throws -> NSTextField {
            try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id })
        }
        XCTAssertEqual(try field("marketbar.portfolio.sharpe").stringValue, "11.14")
        XCTAssertEqual(try field("marketbar.portfolio.sharpe-detail").stringValue, "5 trading days · early · volatility 15.5%")
        XCTAssertEqual(try field("marketbar.risk.sharpe.growth").stringValue, "11.14")
        XCTAssertNotEqual(try field("marketbar.risk.sharpe.income").stringValue, "—")
        XCTAssertEqual(try field("marketbar.risk.sharpe.new").stringValue, "—")
        XCTAssertTrue(texts(content).contains("Needs 4 more trading days of history"))
        let rate = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "marketbar.risk.rate" })
        XCTAssertEqual(rate.title, "Risk-free 4.00%…")

        // Everything the overview showed before the redesign is still on screen.
        let shown = texts(content)
        for expected in ["LIVE PORTFOLIO VALUE", "MARKET PULSE", "UNREALIZED RETURN", "REALIZED YTD", "ALLOCATION",
                         "CASH", "VALUE OVER TIME", "Watchlist", "S&P 500 · SPY", "NASDAQ 100 · QQQ", "Dow Jones · DIA"] {
            XCTAssertTrue(shown.contains(expected), "missing \(expected)")
        }
        XCTAssertTrue(shown.contains { $0.contains("vs previous close") })
        XCTAssertTrue(shown.contains("$500.00"), "cash stays visible")
        XCTAssertTrue(shown.contains("1 position"))
        XCTAssertTrue(shown.contains { $0.contains("Largest holding AAA") })
        XCTAssertTrue(shown.contains { $0.contains("invested") })
        XCTAssertTrue(shown.contains("Record position cost basis to track total return."))
        XCTAssertTrue(allViews(content).compactMap { ($0 as? NSButton)?.title }.contains("Edit cash"))

        if let page = allViews(content).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView is NSStackView })?.documentView {
            try UIPreview.save(page, named: "marketbar-page-sharpe", background: window.backgroundColor)
        }

        widget.selectPortfolio(id: "new")
        let deadline = Date().addingTimeInterval(2)
        while try field("marketbar.portfolio.sharpe").stringValue != "—", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(try field("marketbar.portfolio.sharpe").stringValue, "—")
        XCTAssertEqual(try field("marketbar.portfolio.sharpe-detail").stringValue, "Needs 4 more trading days of history")
        XCTAssertEqual(try field("marketbar.risk.sharpe.growth").stringValue, "11.14", "other portfolios keep their rows")
        try UIPreview.save(content, named: "marketbar-window-sharpe", background: window.backgroundColor)
    }

    func testDropdownShowsTheActivePortfoliosRatio() throws {
        _ = NSApplication.shared
        let widget = try widget()
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        func sharpe() throws -> String {
            try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "portfolio.sharpe" }).stringValue
        }
        XCTAssertEqual(try sharpe(), "11.14 · 5 trading days · early")
        XCTAssertTrue(texts(content).contains("Sharpe ratio"))
        try UIPreview.save(content, named: "dropdown-sharpe", background: Theme.bg)
    }
}
