import Foundation

// MARK: - Market Status

/// Which phase of the trading day the exchange is in.
///
/// Lives on its own because the session boundaries it defines are what separate
/// a regular-session move from an extended-hours one, and that logic needs to be
/// testable without pulling in the whole ticker widget.
enum MarketStatus {
    case preMarket, open, afterHours, closed

    var label: String {
        switch self {
        case .preMarket: return "Pre-Market"
        case .open: return "Market Open"
        case .afterHours: return "After Hours"
        case .closed: return "Market Closed"
        }
    }


    static func current() -> MarketStatus {
        let et = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = et
        let now = Date()
        let wd = cal.component(.weekday, from: now)
        if wd == 1 || wd == 7 { return .closed }
        let t = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        if t < 240 { return .closed }
        if t < 570 { return .preMarket }
        if t < 960 { return .open }
        if t < 1200 { return .afterHours }
        return .closed
    }

    static func fromYahooMarketState(_ raw: String?) -> MarketStatus? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "PRE":
            return .preMarket
        case "REGULAR":
            return .open
        case "POST":
            return .afterHours
        case "CLOSED", "PREPRE", "POSTPOST":
            return .closed
        default:
            return nil
        }
    }
}
