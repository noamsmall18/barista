import XCTest
@testable import Barista

/// Yahoo publishes nothing between the after-hours close at 8 PM ET and the
/// next pre-market, so overnight (24/5) trades come from Robinhood's public
/// quote endpoint. Regular hours, pre-market and after-hours stay on Yahoo.
final class OvernightQuoteFeedTests: XCTestCase {

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// Sunday 25 October 2026, 10 PM ET: the overnight session is open.
    private var sundayNight: Date { date("2026-10-26T02:00:00Z") }

    /// A live `bounds=24_5` response saved on Sunday night, with one unknown
    /// symbol that the endpoint reports as `null`.
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/robinhood-24-5-quotes",
                                                  withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func stock(_ symbol: String = "APP", price: Double = 260.25) -> MarketQuote {
        var quote = MarketQuote(symbol: symbol, price: price, change: -1.52, kind: .stock,
                                previousClose: 264.28, sparkline: [])
        quote.postMarketPrice = 260.87
        quote.postMarketChange = (260.87 - price) / price * 100
        return quote
    }

    // MARK: Request and response

    func testRequestAsksForTheTwentyFourFiveBoundsInOneBatch() throws {
        let url = try XCTUnwrap(OvernightQuoteFeed.url(for: ["APP", "HIMS"]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "api.robinhood.com")
        XCTAssertEqual(items.first { $0.name == "bounds" }?.value, "24_5",
                       "without 24_5 the endpoint stops at Friday's 8 PM print")
        XCTAssertEqual(items.first { $0.name == "symbols" }?.value, "APP,HIMS")
        XCTAssertNil(OvernightQuoteFeed.url(for: []))
    }

    func testParsesTheLatestOvernightTradeAndSkipsUnknownSymbols() throws {
        let trades = OvernightQuoteFeed.parse(try fixture())
        XCTAssertEqual(trades.map(\.symbol), ["APP", "HIMS"], "the null entry for ZZZZQ is skipped")
        let app = try XCTUnwrap(trades.first)
        XCTAssertEqual(app.price, 260.84, accuracy: 0.0001)
        // 2026-10-26T01:57:23.046624096Z, nanoseconds and all.
        XCTAssertEqual(app.time, date("2026-10-26T01:57:23Z").timeIntervalSince1970 + 0.046624096,
                       accuracy: 0.001)
    }

    func testMalformedResponsesYieldNoTrades() {
        XCTAssertTrue(OvernightQuoteFeed.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(OvernightQuoteFeed.parse(Data(#"{"detail":"Not found."}"#.utf8)).isEmpty)
        let zero = #"{"results":[{"symbol":"APP","last_non_reg_trade_price":"0","venue_last_non_reg_trade_time":"2026-10-26T01:57:23Z"}]}"#
        XCTAssertTrue(OvernightQuoteFeed.parse(Data(zero.utf8)).isEmpty)
    }

    // MARK: Which session uses the feed

    func testOnlyTheOvernightSessionUsesRobinhood() {
        XCTAssertTrue(OvernightQuoteFeed.isActive(at: date("2026-10-26T01:44:00Z")), "Sunday 9:44 PM")
        XCTAssertTrue(OvernightQuoteFeed.isActive(at: date("2026-10-26T06:00:00Z")), "Monday 2 AM")
        XCTAssertTrue(OvernightQuoteFeed.isActive(at: date("2026-10-27T00:01:00Z")), "Monday 8:01 PM")
        XCTAssertFalse(OvernightQuoteFeed.isActive(at: date("2026-10-26T11:00:00Z")), "pre-market stays on Yahoo")
        XCTAssertFalse(OvernightQuoteFeed.isActive(at: date("2026-10-26T14:00:00Z")), "regular hours stay on Yahoo")
        XCTAssertFalse(OvernightQuoteFeed.isActive(at: date("2026-10-26T21:00:00Z")), "after hours stays on Yahoo")
        XCTAssertFalse(OvernightQuoteFeed.isActive(at: date("2026-10-27T00:00:30Z")), "8:00 PM is still after hours")
        XCTAssertFalse(OvernightQuoteFeed.isActive(at: date("2026-10-24T01:00:00Z")), "no session Friday night")
        XCTAssertFalse(OvernightQuoteFeed.isActive(at: date("2026-10-24T16:00:00Z")), "or on Saturday")
    }

    func testSessionStartIsTheEightPMThatOpenedIt() {
        let start = date("2026-10-26T00:00:00Z") // Sunday 8 PM ET
        XCTAssertEqual(OvernightQuoteFeed.sessionStart(containing: date("2026-10-26T01:44:00Z")), start)
        XCTAssertEqual(OvernightQuoteFeed.sessionStart(containing: date("2026-10-26T06:00:00Z")), start)
        XCTAssertNil(OvernightQuoteFeed.sessionStart(containing: date("2026-10-26T14:00:00Z")))
    }

    // MARK: The price every surface shows

    func testTonightsTradeIsTheLivePriceOvernight() throws {
        var quote = stock()
        quote.overnightPrice = 260.84
        quote.overnightTradeTime = date("2026-10-26T01:57:23Z").timeIntervalSince1970
        let ext = try XCTUnwrap(quote.extendedHours(at: sundayNight))
        XCTAssertEqual(ext.label, "ON")
        XCTAssertEqual(ext.price, 260.84, accuracy: 0.0001)
        XCTAssertEqual(ext.change, (260.84 - 260.25) / 260.25 * 100, accuracy: 0.0001,
                       "measured from the last regular close, like after hours")
        XCTAssertEqual(quote.currentPrice(at: sundayNight), 260.84, accuracy: 0.0001)
    }

    func testBeforeTheFirstOvernightPrintTheAfterHoursCloseHolds() throws {
        var quote = stock()
        quote.overnightPrice = 255
        quote.overnightTradeTime = date("2026-10-23T23:59:00Z").timeIntervalSince1970 // Friday 7:59 PM
        let ext = try XCTUnwrap(quote.extendedHours(at: sundayNight),
                                "at 8 PM the value must not drop back to the 4 PM close")
        XCTAssertEqual(ext.label, "AH")
        XCTAssertEqual(ext.price, 260.87, accuracy: 0.0001)
    }

    func testOvernightPriceIsIgnoredOutsideTheOvernightSession() {
        var quote = stock()
        quote.overnightPrice = 300
        quote.overnightTradeTime = date("2026-10-26T07:59:00Z").timeIntervalSince1970 // Monday 3:59 AM

        quote.marketState = "POST"
        XCTAssertEqual(quote.extendedHours(at: date("2026-10-26T21:00:00Z"))?.price, 260.87,
                       "after hours uses Yahoo")
        quote.marketState = "REGULAR"
        XCTAssertNil(quote.extendedHours(at: date("2026-10-26T14:00:00Z")), "regular hours use Yahoo")
        XCTAssertEqual(quote.currentPrice(at: date("2026-10-26T14:00:00Z")), 260.25)
        quote.marketState = "PRE"
        quote.preMarketPrice = 262
        quote.preMarketChange = 0.7
        XCTAssertEqual(quote.extendedHours(at: date("2026-10-26T11:00:00Z"))?.price, 262,
                       "pre-market uses Yahoo")
    }

    func testCryptoNeverTakesAnOvernightStockPrice() {
        var coin = MarketQuote(symbol: "APP", price: 1, change: 0, kind: .crypto, sparkline: [])
        coin.overnightPrice = 260.84
        coin.overnightTradeTime = date("2026-10-26T01:57:23Z").timeIntervalSince1970
        XCTAssertNil(coin.extendedHours(at: sundayNight))
    }

    func testPortfolioLabelsTheOvernightMove() {
        var quote = stock()
        quote.overnightPrice = 260.84
        quote.overnightTradeTime = date("2026-10-26T01:57:23Z").timeIntervalSince1970
        XCTAssertEqual(PortfolioSnapshot.sessionName(for: quote.extendedHours(at: sundayNight)?.label), "Overnight")
        XCTAssertEqual(PortfolioSnapshot.sessionName(for: "AH"), "After hours")
        XCTAssertEqual(PortfolioSnapshot.sessionName(for: "Pre"), "Pre-market")
        XCTAssertNil(PortfolioSnapshot.sessionName(for: nil))
    }

    // MARK: Merging into the quotes the widget already has

    func testMergeUpdatesMatchingStocksAndMarksThemFresh() throws {
        let trades = OvernightQuoteFeed.parse(try fixture())
        let coin = MarketQuote(symbol: "HIMS", price: 1, change: 0, kind: .crypto, sparkline: [])
        let merged = OvernightQuoteFeed.merge(trades, into: [stock("app"), coin], receivedAt: 1234)
        XCTAssertEqual(merged[0].overnightPrice, 260.84)
        XCTAssertEqual(merged[0].receivedAt, 1234, "fresh overnight data must not read as stale")
        XCTAssertNil(merged[1].overnightPrice, "a coin sharing a ticker is not the stock")
        XCTAssertNil(merged[1].receivedAt)
    }

    func testMergeNeverReplacesANewerTradeWithAnOlderOne() {
        var quote = stock()
        quote.overnightPrice = 261
        quote.overnightTradeTime = 2000
        let older = OvernightQuoteFeed.Trade(symbol: "APP", price: 259, time: 1000)
        XCTAssertEqual(OvernightQuoteFeed.merge([older], into: [quote], receivedAt: 3000)[0].overnightPrice, 261)
    }

    func testAYahooRefreshKeepsTonightsTrade() {
        var old = stock()
        old.overnightPrice = 260.84
        old.overnightTradeTime = 1000
        let refreshed = stock().keepingOvernightTrade(from: old)
        XCTAssertEqual(refreshed.overnightPrice, 260.84)
        XCTAssertEqual(refreshed.overnightTradeTime, 1000)
        XCTAssertNil(stock().keepingOvernightTrade(from: nil).overnightPrice)
    }

    func testOvernightTradeSurvivesTheQuoteCache() throws {
        var quote = stock()
        quote.overnightPrice = 260.84
        quote.overnightTradeTime = 1000
        let decoded = try JSONDecoder().decode(MarketQuote.self, from: JSONEncoder().encode(quote))
        XCTAssertEqual(decoded.overnightPrice, 260.84)
        XCTAssertEqual(decoded.overnightTradeTime, 1000)
    }

    @MainActor
    func testHistoryRecordsAFreshOvernightTrade() {
        let now = sundayNight
        let history = PortfolioHistoryService(defaults: InMemoryTestPreferences(suiteName: "robinhood-overnight-\(UUID().uuidString)")!,
                                              clock: { now })
        var quote = stock("AAA", price: 100)
        quote.postMarketPrice = 101
        quote.postMarketChange = 1
        quote.receivedAt = now.timeIntervalSince1970
        quote.marketState = "CLOSED"
        quote.overnightPrice = 105
        quote.overnightTradeTime = now.timeIntervalSince1970 - 30
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], holdings: ["AAA": 10]),
                                       notificationsEnabled: false, initialQuotes: [quote], historyService: history)
        widget.recordPortfolioHistory(now: now)
        history.flushPendingWrites()
        XCTAssertEqual(history.points(for: widget.config.activePortfolioID, range: .all).map(\.value), [1050])
    }

    // MARK: Polling

    func testOvernightPollsAtTheExtendedHoursPaceButYahooStaysSlow() {
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["APP"], coins: []),
                                       notificationsEnabled: false)
        let afterHours = widget.stockInterval(during: .afterHours)
        let closed = widget.stockInterval(during: .closed)
        XCTAssertLessThan(afterHours, closed)
        XCTAssertEqual(widget.stockInterval(at: sundayNight), afterHours,
                       "the menu bar has to keep up with overnight trades")
        XCTAssertEqual(widget.yahooStockInterval(at: sundayNight), closed,
                       "Yahoo has nothing new overnight, so polling it fast only invites throttling")
        let weekend = date("2026-10-24T16:00:00Z")
        XCTAssertEqual(widget.stockInterval(at: weekend), closed)
        XCTAssertEqual(widget.yahooStockInterval(at: weekend), closed)
    }
}
