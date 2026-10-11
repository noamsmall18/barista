import XCTest
@testable import Barista

final class OvernightPricingTests: XCTestCase {
    private func et(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: string)!
    }

    /// Metadata as Yahoo returned it for NVDA at 00:09 ET on Thursday 8 October
    /// 2026, mid overnight session, trimmed to the fields the app reads.
    private var overnightMeta: [String: Any] {
        ["symbol": "NVDA", "instrumentType": "EQUITY", "fullExchangeName": "NasdaqGS",
         "exchangeTimezoneName": "America/New_York", "regularMarketPrice": 237.47,
         "fulldayPrice": 237.0, "previousClose": 239.24]
    }

    func testOvernightRunsSundayEveningToFridayMorning() {
        // 2026-10-04 is a Sunday.
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-04 19:59")), .closed)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-04 20:00")), .overnight)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-05 03:59")), .overnight)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-05 04:00")), .preMarket)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-07 17:00")), .afterHours)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-07 20:00")), .overnight)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-08 00:09")), .overnight)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-09 03:59")), .overnight)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-09 20:00")), .closed, "no session on Friday night")
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-10 01:00")), .closed)
        XCTAssertEqual(MarketStatus.current(at: et("2026-10-10 22:00")), .closed)
    }

    func testYahooBetweenSessionStatesFollowTheOvernightClock() {
        let weeknight = et("2026-10-08 00:09"), saturday = et("2026-10-10 01:00")
        XCTAssertEqual(MarketStatus.fromYahooMarketState("PREPRE", at: weeknight), .overnight)
        XCTAssertEqual(MarketStatus.fromYahooMarketState("POSTPOST", at: weeknight), .overnight)
        XCTAssertEqual(MarketStatus.fromYahooMarketState("PREPRE", at: saturday), .closed)
        XCTAssertEqual(MarketStatus.fromYahooMarketState("CLOSED", at: weeknight), .closed,
                       "a holiday the clock does not know about stays closed")
        XCTAssertEqual(MarketStatus.fromYahooMarketState("POST", at: weeknight), .afterHours)
    }

    func testOvernightPrintIsReadOnlyDuringTheOvernightSession() {
        XCTAssertEqual(OvernightPrice.select(meta: overnightMeta, status: .overnight), 237.0)
        for status in [MarketStatus.preMarket, .open, .afterHours, .closed] {
            XCTAssertNil(OvernightPrice.select(meta: overnightMeta, status: status))
        }
    }

    func testInstrumentsWithoutAnOvernightVenueGetNoOvernightPrint() {
        var index = overnightMeta; index["instrumentType"] = "INDEX"
        var future = overnightMeta; future["instrumentType"] = "FUTURE"
        var london = overnightMeta; london["exchangeTimezoneName"] = "Europe/London"
        var otc = overnightMeta; otc["fullExchangeName"] = "OTC Markets OTCQX"
        var missing = overnightMeta; missing["fulldayPrice"] = nil
        var zero = overnightMeta; zero["fulldayPrice"] = 0
        for meta in [index, future, london, otc, missing, zero] {
            XCTAssertNil(OvernightPrice.select(meta: meta, status: .overnight))
        }
    }

    func testOvernightMoveIsMeasuredFromTheRegularCloseAndKeptOutOfTheDay() throws {
        var quote = MarketQuote(symbol: "NVDA", price: 237.47, change: -0.74, kind: .stock,
                                previousClose: 239.24, sparkline: [239.24, 237.47])
        quote.postMarketPrice = 237.75
        quote.postMarketChange = 0.118
        quote.overnightPrice = 237.0
        quote.overnightChange = (237.0 - 237.47) / 237.47 * 100

        let overnight = try XCTUnwrap(quote.extendedHours(during: .overnight))
        XCTAssertEqual(overnight.price, 237.0)
        XCTAssertEqual(overnight.label, "Ovn")
        XCTAssertEqual(overnight.change, -0.198, accuracy: 0.001)
        XCTAssertEqual(quote.extendedHours(during: .afterHours)?.price, 237.75)
        XCTAssertNil(quote.extendedHours(during: .closed))
        XCTAssertNil(quote.extendedHours(during: .open))

        quote.overnightPrice = nil
        XCTAssertNil(quote.extendedHours(during: .overnight), "no print, no invented overnight move")
    }

    func testOvernightPollsAtTheExtendedHoursCadence() {
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: [], coins: []), notificationsEnabled: false)
        XCTAssertEqual(widget.stockInterval(during: .overnight), widget.stockInterval(during: .afterHours))
        XCTAssertLessThan(widget.stockInterval(during: .overnight), widget.stockInterval(during: .closed))
    }

    func testOvernightPriceSurvivesTheQuoteCache() throws {
        var quote = MarketQuote(symbol: "NVDA", price: 237.47, change: -0.74, kind: .stock, sparkline: [])
        quote.overnightPrice = 237.0
        quote.overnightChange = -0.198
        let decoded = try JSONDecoder().decode(MarketQuote.self, from: JSONEncoder().encode(quote))
        XCTAssertEqual(decoded.overnightPrice, 237.0)
        XCTAssertEqual(decoded.overnightChange, -0.198)
    }
}

final class ExtendedSessionChartTests: XCTestCase {
    // Wednesday 7 October 2026, ET, as Unix seconds.
    private let preOpen = 1_791_360_000.0      // 04:00
    private let regularStart = 1_791_379_800.0 // 09:30
    private let regularEnd = 1_791_403_200.0   // 16:00
    private let postEnd = 1_791_417_600.0      // 20:00
    private let nextRegularStart = 1_791_466_200.0
    private let nextRegularEnd = 1_791_489_600.0

    /// One bar every five minutes from 04:00 to 20:00, each with a distinct price.
    private func fullDay() -> MarketQuote {
        var quote = MarketQuote(symbol: "NVDA", price: 237.47, change: -0.74, kind: .stock,
                                previousClose: 239.24, sparkline: [239.24, 237.47])
        var t = preOpen
        while t < postEnd {
            quote.minuteTimes.append(t)
            quote.minuteCloses.append(230 + Double(quote.minuteCloses.count) * 0.01)
            t += 300
        }
        quote.regularStart = regularStart
        quote.regularEnd = regularEnd
        return quote
    }

    func testBarsAreSplitByTheDayTheyWereRecordedNotTheComingOne() throws {
        // What Yahoo sent at 00:09 ET on 8 October: the current period is
        // already Thursday's, the bars and `tradingPeriods` are Wednesday's.
        let meta: [String: Any] = [
            "currentTradingPeriod": ["regular": ["start": nextRegularStart, "end": nextRegularEnd]],
            "tradingPeriods": ["pre": [[["start": preOpen, "end": regularStart]]],
                               "regular": [[["start": regularStart, "end": regularEnd]]],
                               "post": [[["start": regularEnd, "end": postEnd]]]],
        ]
        let boundaries = try XCTUnwrap(SessionSplitter.barBoundaries(meta: meta))
        XCTAssertEqual(boundaries.regularStart, regularStart)
        XCTAssertEqual(boundaries.regularEnd, regularEnd)
        XCTAssertNil(SessionSplitter.barBoundaries(meta: ["currentTradingPeriod": [:]]))
        XCTAssertNil(SessionSplitter.barBoundaries(meta: ["tradingPeriods": ["regular": [[["start": 5, "end": 5]]]]]))
    }

    func testOvernightChartIsTheSessionPlusItsTailNotATwoPointLine() throws {
        var quote = fullDay()
        quote.overnightPrice = 236.5
        quote.overnightChange = -0.4
        let chart = quote.chartSegments(during: .overnight)
        let breakIndex = try XCTUnwrap(chart.breakIndex)
        XCTAssertEqual(breakIndex, 78, "every regular-session bar is on the chart")
        XCTAssertEqual(chart.points.count, 78 + 48 + 1, "then after-hours, then the overnight print")
        XCTAssertEqual(chart.points.last, 236.5)
        XCTAssertGreaterThan(Set(chart.points).count, 100, "a real curve, not a flat line")
    }

    func testTheOldNextDayBoundariesAreWhatFlattenedTheChart() {
        var quote = fullDay()
        quote.regularStart = nextRegularStart
        quote.regularEnd = nextRegularEnd
        XCTAssertEqual(quote.chartSegments(during: .overnight).points.count, 2)
    }

    func testAfterHoursChartKeepsTheSessionAndDrawsTheTailFromTheClose() throws {
        var quote = fullDay()
        quote.postMarketPrice = 238.1
        quote.postMarketChange = 0.27
        let chart = quote.chartSegments(during: .afterHours)
        XCTAssertEqual(chart.breakIndex, 78)
        XCTAssertEqual(chart.points.count, 78 + 48)
        XCTAssertEqual(chart.points.last, 238.1, "the line ends at the live after-hours price")
    }

    func testPreMarketChartIsThatMorningsBars() {
        var quote = fullDay()
        quote.preMarketPrice = 231
        quote.preMarketChange = -3.4
        let duringPre = Date(timeIntervalSince1970: regularStart - 60)
        let chart = quote.chartSegments(during: .preMarket, now: duringPre)
        XCTAssertEqual(chart.points.count, 66, "04:00 to 09:30 at five minutes")
        XCTAssertEqual(chart.breakIndex, 0, "all of it is extended hours")
        XCTAssertEqual(chart.points.last, 231)
    }

    func testEarlyPreMarketWithOnlyYesterdaysBarsShowsThatSessionNotAStaleMorning() throws {
        let quote = fullDay()
        let nextMorning = Date(timeIntervalSince1970: nextRegularStart - 5 * 3600)
        let chart = quote.chartSegments(during: .preMarket, now: nextMorning)
        XCTAssertEqual(chart.breakIndex, 78)
        XCTAssertEqual(chart.points.count, 78 + 48, "yesterday's session and its after-hours tail")
    }
}
