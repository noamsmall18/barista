import XCTest
@testable import Barista

final class TickerChartSummaryTests: XCTestCase {
    private let quote = MarketQuote(symbol: "TEST", price: 105, change: 5, kind: .stock, sparkline: [100, 105])
    private func history(range: StockChartRange, previousClose: Double? = 100) -> StockPriceHistory {
        StockPriceHistory(symbol: "TEST", range: range, currency: "USD", instrumentType: "EQUITY", companyName: nil,
                          exchangeTimezone: "America/New_York", previousClose: previousClose, fetchedAt: Date(),
                          points: [90, 120, 110].enumerated().map {
                              StockPricePoint(date: Date(timeIntervalSince1970: Double($0.offset)), open: nil, high: nil, low: nil, close: Double($0.element), volume: nil)
                          })
    }

    func testDetailKeepsFastQuotesAcrossSessionsAndRestoresNormalCadenceOnLastClose() {
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: [], coins: []), notificationsEnabled: false)
        XCTAssertEqual(widget.stockInterval(during: .closed), 300)
        widget.beginDetailUpdates()
        for status in [MarketStatus.open, .preMarket, .afterHours, .closed] {
            XCTAssertEqual(widget.stockInterval(during: status), 5)
        }
        widget.beginDetailUpdates()
        widget.endDetailUpdates()
        XCTAssertEqual(widget.stockInterval(during: .closed), 5, "another open detail still needs fast quotes")
        widget.endDetailUpdates()
        XCTAssertEqual(widget.stockInterval(during: .open), 5)
        XCTAssertEqual(widget.stockInterval(during: .preMarket), 15)
        XCTAssertEqual(widget.stockInterval(during: .closed), 300)
    }

    func testOneDayChangeUsesPreviousCloseAndStatsDescribeActualChart() {
        let summary = TickerChartSummary(quote: quote, history: history(range: .oneDay))
        XCTAssertEqual(summary.baseline, 100)
        XCTAssertEqual(summary.latest, 110)
        XCTAssertEqual(summary.low, 90)
        XCTAssertEqual(summary.high, 120)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.percentChange, 10, accuracy: 0.001)
    }

    func testLongerRangeUsesItsOpeningSampleInsteadOfPreviousClose() {
        let summary = TickerChartSummary(quote: quote, history: history(range: .oneYear))
        XCTAssertEqual(summary.baseline, 90)
        XCTAssertEqual(summary.percentChange, 100 * 20.0 / 90, accuracy: 0.001)
    }

    func testMissingPreviousCloseFallsBackToFirstSample() {
        let summary = TickerChartSummary(quote: quote, history: history(range: .oneDay, previousClose: nil))
        XCTAssertEqual(summary.baseline, 90)
        XCTAssertEqual(summary.latest, 110)
    }
}
