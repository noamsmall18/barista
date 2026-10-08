import XCTest
@testable import Barista

final class QuoteFeedStatusTests: XCTestCase {
    func testReceiptAgeUsesThisQuoteAndNamesItsProvider() {
        let quote = MarketQuote(symbol: "BTC", price: 60000, change: 1, kind: .crypto,
                                receivedAt: 1000, source: "Kraken", sparkline: [])
        XCTAssertEqual(quote.feedStatusDescription(now: Date(timeIntervalSince1970: 1090)), "Kraken · received 1m ago")
        XCTAssertEqual(quote.feedStatusDescription(now: Date(timeIntervalSince1970: 999)), "Kraken · received 0s ago")
    }

    func testLegacyQuoteWithoutReceiptTimeDoesNotClaimFreshness() {
        let quote = MarketQuote(symbol: "AAPL", price: 200, change: 0, kind: .stock, sparkline: [])
        XCTAssertEqual(quote.feedStatusDescription(), "Yahoo Finance · receipt time unavailable")
    }
}
