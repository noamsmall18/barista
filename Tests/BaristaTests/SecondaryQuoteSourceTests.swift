import XCTest
@testable import Barista

final class SecondaryQuoteSourceTests: XCTestCase {
    /// Trimmed from a live response at 00:10 ET on 8 October 2026, including
    /// the null the feed returns for a symbol it does not list.
    private let quotesJSON = Data("""
    {"results":[{"ask_price":"237.040000","bid_price":"237.010000","last_trade_price":"237.360000",
    "last_extended_hours_trade_price":"237.030000","last_non_reg_trade_price":"237.030000",
    "venue_last_non_reg_trade_time":"2026-10-08T04:10:29.151Z","previous_close":"237.470000",
    "adjusted_previous_close":"237.470000","symbol":"NVDA","trading_halted":false,
    "last_non_reg_trade_price_source":"boats"},null,
    {"ask_price":"506.040000","bid_price":"505.840000","last_trade_price":"506.250000",
    "last_non_reg_trade_price":"505.980000","venue_last_non_reg_trade_time":"2026-10-08T04:08:21.42522296Z",
    "adjusted_previous_close":"506.250000","symbol":"BRK.B","trading_halted":false}]}
    """.utf8)

    private let barsJSON = Data("""
    {"results":[{"symbol":"NVDA","historicals":[
    {"begins_at":"2026-10-07T23:55:00Z","close_price":"237.749200","session":"post","interpolated":false},
    {"begins_at":"2026-10-08T04:00:00Z","close_price":"236.990000","session":"overnight","interpolated":false},
    {"begins_at":"2026-10-08T04:05:00Z","close_price":"237.000000","session":"overnight","interpolated":true},
    {"begins_at":"2026-10-08T04:10:00Z","close_price":"237.030000","session":"overnight","interpolated":false}]},null]}
    """.utf8)

    private var held: MarketQuote {
        MarketQuote(symbol: "NVDA", price: 237.47, change: -0.74, kind: .stock, previousClose: 239.24, sparkline: [239.24, 237.47])
    }
    private let now = Date(timeIntervalSince1970: 1_791_432_660)   // 2026-10-08 04:11:00Z

    func testOnlyUSStocksAndETFsAreSentToTheBackupFeed() {
        XCTAssertEqual(SecondaryQuoteSource.feedSymbol(for: "nvda"), "NVDA")
        XCTAssertEqual(SecondaryQuoteSource.feedSymbol(for: "BRK-B"), "BRK.B")
        for unsupported in ["^GSPC", "ES=F", "VOD.L", "EURUSD=X", "BTC-USD1", "", "-A"] {
            XCTAssertNil(SecondaryQuoteSource.feedSymbol(for: unsupported), unsupported)
        }
        XCTAssertNil(SecondaryQuoteSource.quotesURL(symbols: ["^GSPC"], overnight: true))
        let url = SecondaryQuoteSource.quotesURL(symbols: ["NVDA", "^GSPC", "BRK-B"], overnight: true)
        XCTAssertEqual(url?.absoluteString, "https://api.robinhood.com/marketdata/quotes/?symbols=NVDA,BRK.B&bounds=24_5")
        XCTAssertFalse(SecondaryQuoteSource.quotesURL(symbols: ["NVDA"], overnight: false)!.absoluteString.contains("bounds"))
    }

    func testQuotesParseBackToTheAppsSymbolsAndSkipUnknownOnes() throws {
        let parsed = SecondaryQuoteSource.parseQuotes(quotesJSON, symbols: ["NVDA", "ZZZZQ", "BRK-B"])
        XCTAssertEqual(Set(parsed.keys), ["NVDA", "BRK-B"])
        let nvda = try XCTUnwrap(parsed["NVDA"])
        XCTAssertEqual(nvda.extendedTrade, 237.03)
        XCTAssertEqual(nvda.lastTrade, 237.36)
        XCTAssertEqual(nvda.bid, 237.01)
        XCTAssertEqual(nvda.extendedTradeTime ?? 0, 1_791_432_629, accuracy: 1)
        XCTAssertEqual(parsed["BRK-B"]?.extendedTradeTime ?? 0, 1_791_432_501, accuracy: 1,
                       "nanosecond venue stamps still parse")
        XCTAssertTrue(SecondaryQuoteSource.parseQuotes(Data("{\"missing_instruments\":[\"ZZZZQ\"]}".utf8), symbols: ["ZZZZQ"]).isEmpty)
        XCTAssertTrue(SecondaryQuoteSource.parseQuotes(Data("not json".utf8), symbols: ["NVDA"]).isEmpty)
    }

    func testOvernightBarsKeepOnlyRealOvernightPrints() throws {
        let bars = try XCTUnwrap(SecondaryQuoteSource.parseOvernightBars(barsJSON, symbols: ["NVDA"])["NVDA"])
        XCTAssertEqual(bars.closes, [236.99, 237.03])
        XCTAssertEqual(bars.times.count, 2)
        XCTAssertLessThan(bars.times[0], bars.times[1])
    }

    func testOvernightBackupSetsOnlyTheOvernightPrintAndItsTime() throws {
        let backup = try XCTUnwrap(SecondaryQuoteSource.parseQuotes(quotesJSON, symbols: ["NVDA"])["NVDA"])
        let patched = try XCTUnwrap(SecondaryQuoteSource.apply(backup, to: held, status: .overnight, now: now))
        XCTAssertEqual(patched.price, 237.47, "the regular close is not rewritten")
        XCTAssertEqual(patched.previousClose, 239.24)
        XCTAssertEqual(patched.overnightPrice, 237.03)
        XCTAssertEqual(patched.overnightChange ?? 0, (237.03 - 237.47) / 237.47 * 100, accuracy: 0.0001)
        XCTAssertEqual(patched.overnightTradeTime ?? 0, 1_791_432_629, accuracy: 1)
        XCTAssertEqual(patched.source, "Robinhood")
        XCTAssertNil(SecondaryQuoteSource.apply(backup, to: nil, status: .overnight, now: now),
                     "no regular close to measure from, so no overnight quote is invented")
    }

    func testBackupPatchesTheSessionInProgressAndNothingElse() throws {
        let backup = SecondaryQuote(symbol: "NVDA", lastTrade: 240, extendedTrade: 238,
                                    extendedTradeTime: now.timeIntervalSince1970 - 60, previousClose: 239.24)

        let open = try XCTUnwrap(SecondaryQuoteSource.apply(backup, to: held, status: .open, now: now))
        XCTAssertEqual(open.price, 240)
        XCTAssertEqual(open.change, (240 - 239.24) / 239.24 * 100, accuracy: 0.0001)
        XCTAssertNil(open.postMarketPrice)

        let fresh = try XCTUnwrap(SecondaryQuoteSource.apply(backup, to: nil, status: .open, now: now))
        XCTAssertEqual(fresh.price, 240)
        XCTAssertEqual(fresh.previousClose, 239.24)

        let pre = try XCTUnwrap(SecondaryQuoteSource.apply(backup, to: held, status: .preMarket, now: now))
        XCTAssertEqual(pre.preMarketPrice, 238)
        XCTAssertEqual(pre.price, 237.47)
        XCTAssertEqual(pre.preMarketChange ?? 0, (238 - 239.24) / 239.24 * 100, accuracy: 0.0001)

        let after = try XCTUnwrap(SecondaryQuoteSource.apply(backup, to: held, status: .afterHours, now: now))
        XCTAssertEqual(after.postMarketPrice, 238)
        XCTAssertEqual(after.postMarketChange ?? 0, (238 - 237.47) / 237.47 * 100, accuracy: 0.0001)

        XCTAssertNil(SecondaryQuoteSource.apply(backup, to: held, status: .closed, now: now))
    }

    func testStaleOrMissingPrintsAreNotPassedOffAsThisSessionsMove() {
        var lastNight = SecondaryQuote(symbol: "NVDA", lastTrade: nil, extendedTrade: 238,
                                       extendedTradeTime: now.timeIntervalSince1970 - 9 * 3600, previousClose: 239.24)
        XCTAssertNil(SecondaryQuoteSource.apply(lastNight, to: held, status: .preMarket, now: now))
        XCTAssertNil(SecondaryQuoteSource.apply(lastNight, to: held, status: .afterHours, now: now))
        XCTAssertNil(SecondaryQuoteSource.apply(lastNight, to: held, status: .open, now: now), "no regular trade to use")
        lastNight.extendedTrade = nil
        XCTAssertNil(SecondaryQuoteSource.apply(lastNight, to: held, status: .overnight, now: now))
    }

    func testFeedStatusSaysHowOldTheOvernightPrintIs() {
        var quote = held
        quote.marketState = "PREPRE"
        quote.receivedAt = now.timeIntervalSince1970 - 5
        quote.source = "Yahoo Finance"
        quote.overnightPrice = 237.03
        XCTAssertEqual(quote.feedStatusDescription(now: now),
                       "Yahoo Finance · received 5s ago · overnight trade time unavailable")
        quote.overnightTradeTime = now.timeIntervalSince1970 - 67 * 60
        XCTAssertEqual(quote.feedStatusDescription(now: now),
                       "Yahoo Finance · received 5s ago · last overnight trade 1h ago")
        quote.marketState = "REGULAR"
        XCTAssertEqual(quote.feedStatusDescription(now: now), "Yahoo Finance · received 5s ago")
    }

    func testWidgetFallsBackToTheBackupFeedForItsHeldQuotes() throws {
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["NVDA"], coins: []),
                                       notificationsEnabled: false, initialQuotes: [held])
        var redraws = 0
        widget.onDisplayUpdate = { redraws += 1 }
        let backup = SecondaryQuote(symbol: "NVDA", lastTrade: 240, extendedTrade: 238,
                                    extendedTradeTime: Date().timeIntervalSince1970 - 30, previousClose: 239.24)

        widget.applySecondary(["NVDA": backup], status: .open, asFallback: true)
        let fallback = try XCTUnwrap(widget.quotes.first)
        XCTAssertEqual(fallback.price, 240)
        XCTAssertEqual(fallback.source, "Robinhood")
        XCTAssertEqual(redraws, 1, "the menu bar is told to redraw")

        widget.applySecondary(["NVDA": backup], status: .overnight, asFallback: false)
        let overnight = try XCTUnwrap(widget.quotes.first)
        XCTAssertEqual(overnight.overnightPrice, 238)
        XCTAssertNotNil(overnight.overnightTradeTime)
        XCTAssertEqual(overnight.price, 240, "adding overnight detail does not move the session price")

        widget.applySecondary([:], status: .open, asFallback: true)
        XCTAssertEqual(redraws, 2, "an empty backup response changes nothing")
    }

    func testOvernightPrintsNeverTriggerPriceAlerts() {
        XCTAssertFalse(MarketStatus.overnight.firesPriceAlerts)
        for status in [MarketStatus.preMarket, .open, .afterHours, .closed] {
            XCTAssertTrue(status.firesPriceAlerts)
        }
    }
}

final class MarketCalendarTests: XCTestCase {
    private func et(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: string)!
    }

    func testExchangeHolidaysFor2026And2027() {
        let holidays = ["2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19",
                        "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
                        "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31", "2027-06-18",
                        "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24"]
        for day in holidays {
            XCTAssertTrue(MarketCalendar.isHoliday(et("\(day) 12:00")), day)
            XCTAssertFalse(MarketCalendar.isTradingDay(et("\(day) 12:00")), day)
        }
        for day in ["2026-10-12", "2026-11-11", "2026-07-02", "2026-12-24", "2027-07-02", "2021-12-31"] {
            XCTAssertTrue(MarketCalendar.isTradingDay(et("\(day) 12:00")), day)
        }
        XCTAssertFalse(MarketCalendar.isTradingDay(et("2026-10-10 12:00")), "Saturday")
    }

    func testEarlyCloses() {
        XCTAssertTrue(MarketCalendar.closesEarly(et("2026-11-27 12:00")))
        XCTAssertTrue(MarketCalendar.closesEarly(et("2026-12-24 12:00")))
        XCTAssertFalse(MarketCalendar.closesEarly(et("2026-07-03 12:00")), "the observed holiday itself")
        XCTAssertFalse(MarketCalendar.closesEarly(et("2026-10-08 12:00")))
    }

    func testSessionClockRespectsHolidaysAndEarlyCloses() {
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-26 10:00")), .closed, "Thanksgiving")
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-25 21:00")), .closed, "no session into a holiday")
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-26 03:00")), .closed)
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-26 21:00")), .overnight, "leads into Friday's session")
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-27 12:00")), .open)
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-27 13:30")), .afterHours, "1 PM close")
        XCTAssertEqual(MarketStatus.current(at: et("2026-11-27 17:30")), .closed)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-08 10:00")), .open)
    }
}
