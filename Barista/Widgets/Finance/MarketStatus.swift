import Foundation

// MARK: - Market Status

/// Which phase of the trading day the exchange is in.
///
/// Lives on its own because the session boundaries it defines are what separate
/// a regular-session move from an extended-hours one, and that logic needs to be
/// testable without pulling in the whole ticker widget.
enum MarketStatus {
    case preMarket, open, afterHours, overnight, closed

    var label: String {
        switch self {
        case .preMarket: return "Pre-Market"
        case .open: return "Market Open"
        case .afterHours: return "After Hours"
        case .overnight: return "Overnight"
        case .closed: return "Market Closed"
        }
    }


    /// The overnight session runs 8 PM to 4 AM ET and belongs to the trading
    /// day it leads into: Sunday night trades, Friday night and the night
    /// before a holiday do not.
    static func current(at now: Date = Date()) -> MarketStatus {
        let cal = MarketCalendar.eastern
        let t = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        if t >= 1200 {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return MarketCalendar.isTradingDay(tomorrow) ? .overnight : .closed
        }
        guard MarketCalendar.isTradingDay(now) else { return .closed }
        if t < 240 { return .overnight }
        if t < 570 { return .preMarket }
        let early = MarketCalendar.closesEarly(now)
        if t < (early ? 780 : 960) { return .open }
        if t < (early ? 1020 : 1200) { return .afterHours }
        return .closed
    }

    /// Whether a price seen in this phase may trigger a price alert.
    var firesPriceAlerts: Bool { self != .overnight }

    static func fromYahooMarketState(_ raw: String?, at now: Date = Date()) -> MarketStatus? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "PRE":
            return .preMarket
        case "REGULAR":
            return .open
        case "POST":
            return .afterHours
        case "PREPRE", "POSTPOST":
            return current(at: now) == .overnight ? .overnight : .closed
        case "CLOSED":
            return .closed
        default:
            return nil
        }
    }
}

// MARK: - Exchange calendar

/// NYSE and Nasdaq full-day holidays and 1 PM early closes, computed from the
/// exchanges' standing rules so no list needs updating each year. One-off
/// closures (a national day of mourning, a weather shutdown) are not known
/// here; the quote feed's own market state still covers those per quote.
enum MarketCalendar {
    static let eastern: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    static func isTradingDay(_ date: Date) -> Bool {
        let weekday = eastern.component(.weekday, from: date)
        return weekday != 1 && weekday != 7 && !isHoliday(date)
    }

    static func isHoliday(_ date: Date) -> Bool {
        let c = eastern.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return false }
        return holidays(in: year).contains { $0.month == month && $0.day == day }
    }

    /// The day after Thanksgiving, Christmas Eve and 3 July close at 1 PM when
    /// they are trading days at all.
    static func closesEarly(_ date: Date) -> Bool {
        guard isTradingDay(date) else { return false }
        let c = eastern.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return false }
        if (month == 12 && day == 24) || (month == 7 && day == 3) { return true }
        return month == 11 && day == nthWeekday(4, weekday: 5, month: 11, year: year) + 1
    }

    private static func holidays(in year: Int) -> [(month: Int, day: Int)] {
        var days: [(Int, Int)] = [
            (1, nthWeekday(3, weekday: 2, month: 1, year: year)),    // Martin Luther King Jr. Day
            (2, nthWeekday(3, weekday: 2, month: 2, year: year)),    // Washington's Birthday
            (5, lastWeekday(2, month: 5, year: year)),               // Memorial Day
            (9, nthWeekday(1, weekday: 2, month: 9, year: year)),    // Labor Day
            (11, nthWeekday(4, weekday: 5, month: 11, year: year)),  // Thanksgiving
        ]
        days.append(goodFriday(year))
        // Fixed dates move to Friday from a Saturday and to Monday from a
        // Sunday, except New Year's Day, which is not observed on 31 December.
        for (month, day) in [(1, 1), (6, 19), (7, 4), (12, 25)] {
            guard let date = eastern.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
            let weekday = eastern.component(.weekday, from: date)
            if weekday == 7, month == 1 { continue }
            let shift = weekday == 7 ? -1 : (weekday == 1 ? 1 : 0)
            guard let observed = eastern.date(byAdding: .day, value: shift, to: date) else { continue }
            let c = eastern.dateComponents([.month, .day], from: observed)
            days.append((c.month ?? month, c.day ?? day))
        }
        return days.map { (month: $0.0, day: $0.1) }
    }

    private static func nthWeekday(_ n: Int, weekday: Int, month: Int, year: Int) -> Int {
        let first = eastern.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let offset = (weekday - eastern.component(.weekday, from: first) + 7) % 7
        return 1 + offset + (n - 1) * 7
    }

    private static func lastWeekday(_ weekday: Int, month: Int, year: Int) -> Int {
        let first = eastern.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let length = eastern.range(of: .day, in: .month, for: first)?.count ?? 28
        let last = eastern.date(from: DateComponents(year: year, month: month, day: length)) ?? first
        return length - (eastern.component(.weekday, from: last) - weekday + 7) % 7
    }

    /// Two days before Easter Sunday, by the anonymous Gregorian algorithm.
    private static func goodFriday(_ year: Int) -> (Int, Int) {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        let easter = eastern.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
        let friday = eastern.date(byAdding: .day, value: -2, to: easter) ?? easter
        let parts = eastern.dateComponents([.month, .day], from: friday)
        return (parts.month ?? month, parts.day ?? day)
    }
}

// MARK: - Overnight price

/// Picks the overnight print out of a Yahoo chart response.
///
/// Yahoo's intraday bars stop at 8 PM ET, but the response's metadata carries
/// `fulldayPrice`: the last trade including the overnight venues (Blue Ocean
/// ATS and others). It has no timestamp, so it is only trusted while the
/// overnight session is running and only for instruments those venues list.
enum OvernightPrice {
    static func select(meta: [String: Any], status: MarketStatus) -> Double? {
        guard status == .overnight else { return nil }
        guard let type = (meta["instrumentType"] as? String)?.uppercased(),
              type == "EQUITY" || type == "ETF" else { return nil }
        guard (meta["exchangeTimezoneName"] as? String) == "America/New_York" else { return nil }
        if let exchange = meta["fullExchangeName"] as? String, exchange.uppercased().contains("OTC") { return nil }
        let price: Double?
        switch meta["fulldayPrice"] {
        case let n as NSNumber: price = n.doubleValue
        case let s as String: price = Double(s)
        default: price = nil
        }
        guard let price, price.isFinite, price > 0 else { return nil }
        return price
    }
}
