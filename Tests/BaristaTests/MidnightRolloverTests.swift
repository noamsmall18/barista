import XCTest
@testable import Barista

/// The day's gain is measured from the close before the last regular session
/// only until midnight ET. After that a new day starts from the last session's
/// own close, so overnight and early pre-market show just what has moved since
/// then. Yahoo's `previousClose` keeps pointing a session further back until
/// the next day's chart appears, which is what carried Friday's whole move into
/// Sunday night's number.
final class MidnightRolloverTests: XCTestCase {

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// APP after Friday 23 October 2026: closed at 260.18 against Thursday's
    /// 264.28, traded 260.87 after hours and 260.65 on Sunday night.
    private func app() -> MarketQuote {
        var quote = MarketQuote(symbol: "APP", price: 260.18, change: -1.55, kind: .stock,
                                previousClose: 264.28, sparkline: [])
        quote.regularStart = date("2026-10-23T13:30:00Z").timeIntervalSince1970
        quote.regularEnd = date("2026-10-23T20:00:00Z").timeIntervalSince1970
        quote.postMarketPrice = 260.87
        quote.postMarketChange = (260.87 - 260.18) / 260.18 * 100
        quote.overnightPrice = 260.65
        quote.overnightTradeTime = date("2026-10-26T03:05:00Z").timeIntervalSince1970
        return quote
    }

    func testBeforeMidnightTheSessionsOwnDayStillCounts() {
        let fridayNight = date("2026-10-24T01:00:00Z") // Friday 9 PM ET
        XCTAssertEqual(app().baselinePrice(at: fridayNight), 264.28)
    }

    func testAfterMidnightTheLastCloseStartsTheNewDay() {
        let quote = app()
        XCTAssertEqual(quote.baselinePrice(at: date("2026-10-24T04:30:00Z")), 260.18, "Saturday 12:30 AM")
        let sundayNight = date("2026-10-26T03:10:00Z") // Sunday 11:10 PM ET, overnight session
        XCTAssertEqual(quote.baselinePrice(at: sundayNight), 260.18)
        XCTAssertEqual(quote.currentChange(at: sundayNight), (260.65 - 260.18) / 260.18 * 100, accuracy: 0.0001,
                       "only the overnight move, not Friday's drop as well")
        XCTAssertEqual(quote.currentValueChange(for: 10, at: sundayNight), 4.7, accuracy: 0.0001)
        XCTAssertEqual(quote.dailyValueChange(for: 10, at: sundayNight), 0,
                       "nothing has happened yet in the new day's regular session")
    }

    func testEarlyPreMarketBeforeYahooRollsOverUsesTheLastClose() {
        var quote = app()
        quote.marketState = "PRE"
        quote.preMarketPrice = 262
        quote.preMarketChange = (262 - 264.28) / 264.28 * 100
        let mondayMorning = date("2026-10-26T10:00:00Z") // Monday 6 AM ET
        XCTAssertEqual(quote.baselinePrice(at: mondayMorning), 260.18)
        XCTAssertEqual(quote.currentChange(at: mondayMorning), (262 - 260.18) / 260.18 * 100, accuracy: 0.0001)
    }

    func testOnceTheNewSessionIsLoadedItsPreviousCloseIsUsed() {
        // Monday's chart: Yahoo's previous close is now Friday's.
        var quote = MarketQuote(symbol: "APP", price: 263, change: 1.08, kind: .stock,
                                previousClose: 260.18, sparkline: [])
        quote.regularStart = date("2026-10-26T13:30:00Z").timeIntervalSince1970
        quote.regularEnd = date("2026-10-26T20:00:00Z").timeIntervalSince1970
        XCTAssertEqual(quote.baselinePrice(at: date("2026-10-26T10:00:00Z")), 260.18, "Monday pre-market")
        XCTAssertEqual(quote.baselinePrice(at: date("2026-10-26T15:00:00Z")), 260.18, "Monday regular hours")
        XCTAssertEqual(quote.baselinePrice(at: date("2026-10-27T01:00:00Z")), 260.18, "Monday 9 PM")
        XCTAssertEqual(quote.baselinePrice(at: date("2026-10-27T04:30:00Z")), 263, "Tuesday 12:30 AM")
    }

    func testQuotesWithoutSessionTimesKeepThePreviousClose() {
        let quote = MarketQuote(symbol: "APP", price: 260.18, change: -1.55, kind: .stock,
                                previousClose: 264.28, sparkline: [])
        XCTAssertEqual(quote.baselinePrice(at: date("2026-10-26T03:10:00Z")), 264.28)
    }

    func testCryptoKeepsItsTwentyFourHourBaseline() {
        var coin = MarketQuote(symbol: "BTC", price: 100, change: 5, kind: .crypto,
                               previousClose: 95, sparkline: [])
        coin.regularEnd = date("2026-10-23T20:00:00Z").timeIntervalSince1970
        XCTAssertEqual(coin.baselinePrice(at: date("2026-10-26T03:10:00Z")), 95)
    }
}
