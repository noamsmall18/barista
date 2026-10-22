import XCTest
@testable import Barista

final class AllTimeRangeTests: XCTestCase {
    func testPercentOffHighAndLowUseHistoricalExtremes() throws {
        let quote = MarketQuote(symbol: "TEST", price: 80, change: 0, kind: .stock, sparkline: [])
        let summary = try XCTUnwrap(AllTimeRangeSummary(quote: quote, historicalHigh: 100, historicalLow: 20))
        XCTAssertEqual(summary.percentFromHigh, -20, accuracy: 0.0001)
        XCTAssertEqual(summary.percentFromLow, 300, accuracy: 0.0001)
    }

    func testLiveQuoteWidensStaleExtremesInsteadOfShowingImpossibleDistances() throws {
        var quote = MarketQuote(symbol: "TEST", price: 120, change: 0, kind: .stock, dayHigh: 125, dayLow: 110, sparkline: [])
        quote.fiftyTwoWeekLow = 15
        let summary = try XCTUnwrap(AllTimeRangeSummary(quote: quote, historicalHigh: 100, historicalLow: 20))
        XCTAssertEqual(summary.high, 125, "today's intraday high beats a stale provider high")
        XCTAssertEqual(summary.low, 15)
        XCTAssertEqual(summary.percentFromHigh, -4, accuracy: 0.0001)

        let atHigh = MarketQuote(symbol: "TEST", price: 130, change: 0, kind: .stock, sparkline: [])
        XCTAssertEqual(try XCTUnwrap(AllTimeRangeSummary(quote: atHigh, historicalHigh: 100, historicalLow: 20)).percentFromHigh, 0)
    }

    func testMissingOrInvalidExtremesProduceNoSummary() {
        let quote = MarketQuote(symbol: "TEST", price: 80, change: 0, kind: .stock, sparkline: [])
        XCTAssertNil(AllTimeRangeSummary(quote: quote, historicalHigh: nil, historicalLow: 20))
        XCTAssertNil(AllTimeRangeSummary(quote: quote, historicalHigh: 100, historicalLow: 0))
        let noPrice = MarketQuote(symbol: "TEST", price: 0, change: 0, kind: .stock, sparkline: [])
        XCTAssertNil(AllTimeRangeSummary(quote: noPrice, historicalHigh: 100, historicalLow: 20))
    }

    func testPercentFormattingStaysReadableForLargeMoves() {
        XCTAssertEqual(AllTimeRangeSummary.formatPercent(-12.345), "-12.3%")
        XCTAssertEqual(AllTimeRangeSummary.formatPercent(0), "0.0%")
        XCTAssertEqual(AllTimeRangeSummary.formatPercent(537_912.4), "+537,912%")
    }

    func testYahooFullHistoryParsesExtremesAndSkipsGaps() throws {
        let json = """
        {"chart":{"result":[{"meta":{"currency":"USD"},"timestamp":[1,2,3,4],
          "indicators":{"quote":[{"high":[10.5,null,48.2,40.0],"low":[0.06,null,30.1,35.0],
                                  "close":[8.0,null,45.0,38.0]}]}}],"error":null}}
        """
        let range = try StockPriceHistoryService.parseAllTimeRange(data: Data(json.utf8))
        XCTAssertEqual(range.high, 48.2)
        XCTAssertEqual(range.low, 0.06)
        XCTAssertThrowsError(try StockPriceHistoryService.parseAllTimeRange(data: Data(#"{"chart":{"result":[]}}"#.utf8)))
    }

    func testCryptoExtremesSurviveTheQuoteCache() throws {
        var quote = MarketQuote(symbol: "BTC", price: 60_000, change: 1, kind: .crypto, sparkline: [])
        quote.allTimeHigh = 73_000
        quote.allTimeLow = 67.81
        let decoded = try JSONDecoder().decode(MarketQuote.self, from: JSONEncoder().encode(quote))
        XCTAssertEqual(decoded.allTimeHigh, 73_000)
        XCTAssertEqual(decoded.allTimeLow, 67.81)
    }
}
