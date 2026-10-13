import XCTest
import Cocoa
@testable import Barista

final class PortfolioHistoryTests: XCTestCase {
    private func date(_ stamp: String) -> Date {
        ISO8601DateFormatter().date(from: stamp)!
    }

    private func defaults(_ points: [PortfolioHistoryService.Point] = []) throws -> UserDefaults {
        let defaults = InMemoryTestPreferences(suiteName: "history-tests-\(UUID().uuidString)")!
        if !points.isEmpty { defaults.set(try JSONEncoder().encode(["test": points]), forKey: "barista.portfolioHistory") }
        return defaults
    }

    func testWeekendAndHolidayObservationsDoNotFillTheChart() throws {
        let saved = [
            ("2026-10-09T19:50:00Z", 100_000.0), // Friday
            ("2026-10-10T16:00:00Z", 100_000.0), // Saturday
            ("2026-10-11T16:00:00Z", 100_000.0), // Sunday
            ("2026-10-12T14:00:00Z", 100_100.0)  // Columbus Day is open
        ].map { PortfolioHistoryService.Point(time: date($0.0), value: $0.1) }
        let history = PortfolioHistoryService(defaults: try defaults(saved))
        XCTAssertEqual(history.points(for: "test", range: .all).map(\.value), [100_000, 100_100])
    }

    func testLegacyIsolatedThousandDollarDipIsHiddenWithoutDeletingRawData() throws {
        let values: [Double] = [100_000, 100_010, 99_000, 100_015, 100_020]
        let start = date("2026-10-09T14:00:00Z")
        let saved = values.enumerated().map { PortfolioHistoryService.Point(time: start.addingTimeInterval(Double($0.offset) * 600), value: $0.element) }
        let defaults = try defaults(saved)
        let original = defaults.data(forKey: "barista.portfolioHistory")
        let history = PortfolioHistoryService(defaults: defaults)
        XCTAssertEqual(history.points(for: "test", range: .all).map(\.value), [100_000, 100_010, 100_015, 100_020])
        XCTAssertEqual(defaults.data(forKey: "barista.portfolioHistory"), original)
    }

    func testDailySeptember22DipIsFilteredAcrossEveryLongRangeWithoutChangingRaw() throws {
        let stamps = ["2026-09-18T19:50:00Z", "2026-09-21T19:50:00Z", "2026-09-22T19:50:00Z",
                      "2026-09-23T19:50:00Z", "2026-09-24T19:50:00Z"]
        for badValue in [99_000.0, 101_000.0] {
            let values = [100_000, 100_010, badValue, 100_015, 100_020]
            let saved = zip(stamps, values).map { PortfolioHistoryService.Point(time: date($0.0), value: $0.1) }
            let prefs = try defaults(saved)
            let original = prefs.data(forKey: "barista.portfolioHistory")
            let history = PortfolioHistoryService(defaults: prefs, clock: { self.date("2026-09-25T19:50:00Z") })
            for range in PortfolioHistoryService.Range.allCases where !range.isIntraday {
                XCTAssertEqual(history.points(for: "test", range: range), [saved[0], saved[1], saved[3], saved[4]], range.label)
                XCTAssertEqual(history.points(for: "test", range: range, raw: true), saved, range.label)
            }
            XCTAssertEqual(prefs.data(forKey: "barista.portfolioHistory"), original)
        }
    }

    func testTwoBadReadingsRecoveringAcrossSessionsDoNotDistortHistory() throws {
        let stamps = ["2026-09-22T22:40:00Z", "2026-09-22T23:40:00Z", "2026-09-23T14:10:00Z",
                      "2026-09-23T15:30:00Z", "2026-09-23T17:00:00Z", "2026-09-23T18:20:00Z"]
        let values: [Double] = [100_000, 100_010, 99_000, 99_010, 100_015, 100_020]
        let saved = zip(stamps, values).map { PortfolioHistoryService.Point(time: date($0.0), value: $0.1) }
        let history = PortfolioHistoryService(defaults: try defaults(saved))
        XCTAssertEqual(history.points(for: "test", range: .all), [saved[0], saved[1], saved[4], saved[5]])
        XCTAssertEqual(history.points(for: "test", range: .all, raw: true), saved)
    }

    func testAnomalyDecisionDoesNotDependOnObservationCadence() {
        let values: [Double] = [100_000, 100_010, 99_000, 100_015, 100_020]
        let intervals: [TimeInterval] = [60, 3600, 86_400, 7 * 86_400]
        for interval in intervals {
            let saved = values.enumerated().map {
                PortfolioHistoryService.Point(time: date("2026-09-01T14:00:00Z").addingTimeInterval(Double($0.offset) * interval), value: $0.element)
            }
            XCTAssertEqual(PortfolioHistoryService.removingIsolatedGlitches(saved), [saved[0], saved[1], saved[3], saved[4]])
        }
    }

    func testDailyFilterPreservesSustainedLossEndpointsAndUnconfirmedRecoveries() {
        let sequences: [[Double]] = [
            [100_000, 100_010, 99_000, 99_010, 99_020, 100_015, 100_020],
            [100_000, 100_010, 99_000, 99_010, 99_020, 99_030],
            [99_000, 100_000, 100_010, 100_015, 100_020],
            [100_000, 100_010, 100_015, 100_020, 99_000],
            [100_000, 100_010, 99_000, 100_015]
        ]
        for values in sequences {
            let saved = values.enumerated().map {
                PortfolioHistoryService.Point(time: date("2026-09-01T14:00:00Z").addingTimeInterval(Double($0.offset) * 86_400), value: $0.element)
            }
            XCTAssertEqual(PortfolioHistoryService.removingIsolatedGlitches(saved), saved)
        }
    }

    func testKnownFlowsAndCompositionChangesAreNeverClassifiedAsAnomalies() {
        let values: [Double] = [100_000, 100_010, 99_000, 100_015, 100_020]
        let saved = values.enumerated().map {
            PortfolioHistoryService.Point(time: date("2026-09-01T14:00:00Z").addingTimeInterval(Double($0.offset) * 86_400),
                                          value: $0.element, holdings: ["AAA": 10], cash: 0)
        }
        for changedIndex in saved.indices {
            var flow = saved
            flow[changedIndex].flow = 1000
            XCTAssertEqual(PortfolioHistoryService.removingIsolatedGlitches(flow), flow)
            var holdings = saved
            holdings[changedIndex].holdings = ["AAA": 20]
            XCTAssertEqual(PortfolioHistoryService.removingIsolatedGlitches(holdings), holdings)
            var cash = saved
            cash[changedIndex].cash = 1000
            XCTAssertEqual(PortfolioHistoryService.removingIsolatedGlitches(cash), cash)
        }
    }

    func testSustainedLossAndOpeningGapArePreserved() throws {
        let saved = [
            ("2026-10-09T19:30:00Z", 100_000.0),
            ("2026-10-09T19:40:00Z", 99_000.0),
            ("2026-10-09T19:50:00Z", 98_990.0),
            ("2026-10-12T13:30:00Z", 97_000.0)
        ].map { PortfolioHistoryService.Point(time: date($0.0), value: $0.1) }
        let history = PortfolioHistoryService(defaults: try defaults(saved))
        XCTAssertEqual(history.points(for: "test", range: .all), saved)
    }

    func testFrequentRefreshesStillProduceTenMinuteHistory() throws {
        var now = date("2026-10-09T14:00:00Z")
        let history = PortfolioHistoryService(defaults: try defaults(), clock: { now })
        for i in 0..<31 {
            now = date("2026-10-09T14:00:00Z").addingTimeInterval(Double(i) * 60)
            history.record(portfolioID: "test", value: 100_000 + Double(i))
            history.flushPendingWrites()
        }
        XCTAssertEqual(history.sampleCount(for: "test"), 4)
    }

    func testNewWeekendPointsAreNotRecorded() throws {
        let history = PortfolioHistoryService(defaults: try defaults(), clock: { self.date("2026-10-10T16:00:00Z") })
        history.record(portfolioID: "test", value: 100_000)
        history.flushPendingWrites()
        XCTAssertEqual(history.sampleCount(for: "test"), 0)
    }

    func testSixMonthAndAllHistoryAreNotSilentlyTruncatedAt120Days() throws {
        let saved = [PortfolioHistoryService.Point(time: date("2026-04-09T19:00:00Z"), value: 100_000)]
        let history = PortfolioHistoryService(defaults: try defaults(saved), clock: { self.date("2026-10-09T19:00:00Z") })
        history.record(portfolioID: "test", value: 110_000)
        history.flushPendingWrites()
        XCTAssertEqual(history.points(for: "test", range: .all).count, 2)
    }
    func testFlowsNeutralizeEditsButPreserveSubsequentMarketReturns() throws {
        var now = date("2026-10-09T14:00:00Z")
        let history = PortfolioHistoryService(defaults: try defaults(), clock: { now })
        func record(_ qty: Double, _ price: Double, _ cash: Double = 0) {
            history.record(portfolioID: "test", value: qty * price + cash,
                           valuation: .init(holdings: ["AAA": qty], cash: cash, prices: ["AAA": price]))
            history.flushPendingWrites()
        }
        record(10, 100)
        now = now.addingTimeInterval(600)
        record(20, 100) // changing quantity is held pending
        XCTAssertEqual(history.sampleCount(for: "test"), 1)
        now = now.addingTimeInterval(120)
        record(20, 100)
        now = now.addingTimeInterval(600)
        record(20, 110)
        let clean = history.points(for: "test", range: .all)
        XCTAssertEqual(clean.map(\.value), [2000, 2000, 2200])
        XCTAssertEqual(history.points(for: "test", range: .all, raw: true).map(\.value), [1000, 2000, 2200])
        XCTAssertEqual(try XCTUnwrap(history.change(for: "test", range: .all)).percent, 10, accuracy: 1e-8)
    }

    func testRevertingATemporaryTypoNeverEntersHistory() throws {
        var now = date("2026-10-09T14:00:00Z")
        let history = PortfolioHistoryService(defaults: try defaults(), clock: { now })
        func record(_ qty: Double) {
            history.record(portfolioID: "test", value: qty * 100,
                           valuation: .init(holdings: ["AAA": qty], cash: 0, prices: ["AAA": 100]))
            history.flushPendingWrites()
        }
        record(10)
        now = now.addingTimeInterval(600); record(1000)
        now = now.addingTimeInterval(60); record(10)
        XCTAssertEqual(history.points(for: "test", range: .all, raw: true).map(\.value), [1000, 1000])
    }

    func testCashDepositAndFundedTradeDoNotMasqueradeAsReturns() throws {
        let start = date("2026-10-09T14:00:00Z")
        let points = [
            PortfolioHistoryService.Point(time: start, value: 1000),
            PortfolioHistoryService.Point(time: start.addingTimeInterval(600), value: 1500, flow: 500),
            PortfolioHistoryService.Point(time: start.addingTimeInterval(1200), value: 1510, flow: 0)
        ]
        let adjusted = PortfolioHistoryService.adjustingFlows(points)
        XCTAssertEqual(adjusted[0].value, 1500, accuracy: 1e-8)
        XCTAssertEqual(adjusted[1].value, 1500, accuracy: 1e-8)
        XCTAssertEqual(adjusted[2].value, 1510, accuracy: 1e-8)
    }

    func testCryptoWeekendAndVerifiedOvernightSamplesSurvive() throws {
        let saved = [
            PortfolioHistoryService.Point(time: date("2026-10-10T16:00:00Z"), value: 1000, trading: .continuous),
            PortfolioHistoryService.Point(time: date("2026-10-12T00:05:00Z"), value: 1010, trading: .overnight)
        ]
        let history = PortfolioHistoryService(defaults: try defaults(saved))
        XCTAssertEqual(history.points(for: "test", range: .all), saved)
    }

    func testRemovingAQuotedSymbolDoesNotFreezeAllFutureHistory() throws {
        var now = date("2026-10-09T14:00:00Z")
        let history = PortfolioHistoryService(defaults: try defaults(), clock: { now })
        history.record(portfolioID: "test", value: 1000, valuation: .init(holdings: ["AAA": 10], cash: 0, prices: ["AAA": 100]))
        history.flushPendingWrites()
        now = now.addingTimeInterval(600)
        history.record(portfolioID: "test", value: 1000, valuation: .init(holdings: ["BBB": 10], cash: 0, prices: ["BBB": 100]))
        history.flushPendingWrites()
        now = now.addingTimeInterval(120)
        history.record(portfolioID: "test", value: 1000, valuation: .init(holdings: ["BBB": 10], cash: 0, prices: ["BBB": 100]))
        history.flushPendingWrites()
        XCTAssertEqual(history.points(for: "test", range: .all).map(\.value), [1000, 1000])
    }

    func testIndependentAppAndResearchWritersDoNotOverwriteEachOthersHistory() throws {
        let prefs = try defaults()
        let now = date("2026-10-09T14:00:00Z")
        let app = PortfolioHistoryService(defaults: prefs, clock: { now })
        let research = PortfolioHistoryService(defaults: prefs, clock: { now })
        app.record(portfolioID: "first", value: 1000)
        app.flushPendingWrites()
        research.record(portfolioID: "second", value: 2000)
        research.flushPendingWrites()
        XCTAssertEqual(research.points(for: "first", range: .all).map(\.value), [1000])
        XCTAssertEqual(app.points(for: "second", range: .all).map(\.value), [2000])
        let restored = PortfolioHistoryService(defaults: prefs, clock: { now })
        XCTAssertEqual(restored.points(for: "first", range: .all).map(\.value), [1000])
        XCTAssertEqual(restored.points(for: "second", range: .all).map(\.value), [2000])
    }

    func testConcurrentHistoryWritersPreserveEveryPortfolio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-lock-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefs = try defaults()
        let now = date("2026-10-09T14:00:00Z")
        let writers = (0..<4).map { _ in PortfolioHistoryService(defaults: prefs, clock: { now }, lockURL: directory.appendingPathComponent("history.lock")) }
        for (number, writer) in writers.enumerated() {
            for i in 0..<16 { writer.record(portfolioID: "writer-\(number)-\(i)", value: Double(1000 + number * 16 + i)) }
        }
        for writer in writers { writer.flushPendingWrites() }
        let saved = try JSONDecoder().decode([String: [PortfolioHistoryService.Point]].self,
                                             from: XCTUnwrap(prefs.data(forKey: "barista.portfolioHistory")))
        XCTAssertEqual(saved.count, 64)
        XCTAssertEqual(saved.values.compactMap { $0.last?.value }.sorted(), (1000..<1064).map(Double.init))
    }

    func testAnEditWithinOneSamplingBucketKeepsItsReturnBoundary() throws {
        var now = date("2026-10-09T14:00:00Z")
        let history = PortfolioHistoryService(defaults: try defaults(), clock: { now })
        func record(_ qty: Double, _ price: Double) {
            history.record(portfolioID: "test", value: qty * price, valuation: .init(holdings: ["AAA": qty], cash: 0, prices: ["AAA": price]))
            history.flushPendingWrites()
        }
        record(10, 100)
        now = now.addingTimeInterval(120); record(20, 100)
        now = now.addingTimeInterval(120); record(20, 100)
        now = now.addingTimeInterval(60); record(20, 110)
        XCTAssertEqual(history.points(for: "test", range: .all, raw: true).map(\.value), [1000, 2000, 2200])
        XCTAssertEqual(history.points(for: "test", range: .all).map(\.value), [2000, 2000, 2200])
        XCTAssertEqual(try XCTUnwrap(history.change(for: "test", range: .all)).percent, 10, accuracy: 1e-8)
    }

}

final class PortfolioTradingCalendarTests: XCTestCase {
    func testExchangeHolidaysEarlyClosesDSTAndSundayOvernight() {
        let cases: [(String, Bool)] = [
            ("2026-04-03T15:00:00Z", false), // Good Friday
            ("2026-07-03T15:00:00Z", false), // observed Independence Day
            ("2026-06-19T15:00:00Z", false),
            ("2026-11-26T15:00:00Z", false),
            ("2026-11-27T21:59:00Z", true), // 4:59 ET, early late-session close
            ("2026-11-27T22:01:00Z", false),
            ("2026-03-09T08:00:00Z", true), // 4am after spring DST
            ("2026-11-02T08:59:00Z", false), // 3:59am after fall DST
            ("2027-12-31T15:00:00Z", true) // New Year's exception
        ]
        for (stamp, expected) in cases {
            XCTAssertEqual(PortfolioTradingCalendar.isExtendedSession(ISO8601DateFormatter().date(from: stamp)!), expected, stamp)
        }
        XCTAssertTrue(PortfolioTradingCalendar.isOvernightSession(ISO8601DateFormatter().date(from: "2026-10-12T00:01:00Z")!))
        XCTAssertFalse(PortfolioTradingCalendar.isOvernightSession(ISO8601DateFormatter().date(from: "2026-10-10T00:01:00Z")!))
    }
}

@MainActor
final class PortfolioHistoryRecordingTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-09T15:00:00Z")!
    private func history() -> PortfolioHistoryService {
        PortfolioHistoryService(defaults: InMemoryTestPreferences(suiteName: "history-recording-\(UUID().uuidString)")!, clock: { self.now })
    }
    private func quote(_ symbol: String, price: Double = 100, age: TimeInterval = 0) -> MarketQuote {
        var q = MarketQuote(symbol: symbol, price: price, change: 0, kind: .stock, sparkline: [])
        q.receivedAt = now.addingTimeInterval(-age).timeIntervalSince1970
        return q
    }
    func testIncompletePortfolioDoesNotBecomeAHistoricalLoss() {
        let history = history()
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA", "BBB"], coins: [], holdings: ["AAA": 10, "BBB": 10]),
                                       notificationsEnabled: false, initialQuotes: [quote("AAA")], historyService: history)
        widget.recordPortfolioHistory(now: now)
        history.flushPendingWrites()
        XCTAssertEqual(history.sampleCount(for: widget.config.activePortfolioID), 0)
    }
    func testInvalidStaleAndMixedCurrencyPricesDoNotBecomeHistory() {
        for q in [quote("AAA", price: 0), quote("AAA", price: .nan), quote("AAA", age: 3600), {
            var q = quote("AAA"); q.currency = "EUR"; return q
        }()] {
            let history = history()
            let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 10]),
                                           notificationsEnabled: false, initialQuotes: [q], historyService: history)
            widget.recordPortfolioHistory(now: now)
            history.flushPendingWrites()
            XCTAssertEqual(history.sampleCount(for: widget.config.activePortfolioID), 0)
        }
    }
    func testFreshExtendedPriceIsRecordedInsteadOfFlatRegularClose() throws {
        let history = history()
        var q = quote("AAA"); q.marketState = "POST"; q.postMarketPrice = 105; q.postMarketChange = 5
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 10]),
                                       notificationsEnabled: false, initialQuotes: [q], historyService: history)
        widget.recordPortfolioHistory(now: now)
        history.flushPendingWrites()
        XCTAssertEqual(try XCTUnwrap(history.points(for: widget.config.activePortfolioID, range: .all).last).value, 1050)
    }
}

@MainActor
final class PortfolioCashHistoryTests: XCTestCase {
    func testCashOnlyPortfolioRemainsRecordableAfterSellingPositions() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-09T14:00:00Z")!
        let history = PortfolioHistoryService(defaults: InMemoryTestPreferences(suiteName: "cash-history-\(UUID().uuidString)")!, clock: { now })
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: [], coins: [], cash: 1000),
                                       notificationsEnabled: false, historyService: history)
        widget.recordPortfolioHistory(now: now)
        history.flushPendingWrites()
        XCTAssertEqual(history.points(for: widget.config.activePortfolioID, range: .all).map(\.value), [1000])
    }
}

@MainActor
final class PortfolioOvernightRecordingTests: XCTestCase {
    func testFreshSundayOvernightBarRecordsItsActualPrice() {
        let now = ISO8601DateFormatter().date(from: "2026-10-12T00:05:00Z")!
        let history = PortfolioHistoryService(defaults: InMemoryTestPreferences(suiteName: "overnight-history-\(UUID().uuidString)")!, clock: { now })
        var quote = MarketQuote(symbol: "AAA", price: 100, change: 0, kind: .stock, sparkline: [])
        quote.receivedAt = now.timeIntervalSince1970
        quote.marketState = "CLOSED"
        quote.minuteTimes = [now.addingTimeInterval(-60).timeIntervalSince1970, now.timeIntervalSince1970]
        quote.minuteCloses = [104, 105]
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 10]),
                                       notificationsEnabled: false, initialQuotes: [quote], historyService: history)
        widget.recordPortfolioHistory(now: now)
        history.flushPendingWrites()
        XCTAssertEqual(history.points(for: widget.config.activePortfolioID, range: .all).map(\.value), [1050])
    }

    func testReceivingFridaysQuoteAgainDoesNotCreateASundayObservation() {
        let now = ISO8601DateFormatter().date(from: "2026-10-12T00:05:00Z")!
        let history = PortfolioHistoryService(defaults: InMemoryTestPreferences(suiteName: "closed-history-\(UUID().uuidString)")!, clock: { now })
        var quote = MarketQuote(symbol: "AAA", price: 100, change: 0, kind: .stock, sparkline: [])
        quote.receivedAt = now.timeIntervalSince1970
        quote.marketState = "CLOSED"
        quote.minuteTimes = [now.addingTimeInterval(-48 * 3600).timeIntervalSince1970]
        quote.minuteCloses = [100]
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 10]),
                                       notificationsEnabled: false, initialQuotes: [quote], historyService: history)
        widget.recordPortfolioHistory(now: now)
        history.flushPendingWrites()
        XCTAssertEqual(history.sampleCount(for: widget.config.activePortfolioID), 0)
    }
}
