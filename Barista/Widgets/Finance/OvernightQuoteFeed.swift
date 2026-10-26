import Foundation

/// Overnight (24/5) trades for US stocks, 8 PM to 4 AM ET.
///
/// Yahoo publishes nothing between the after-hours close and the next
/// pre-market, so this session alone comes from Robinhood's public quote
/// endpoint, which carries Blue Ocean and Bruce ATS prints when asked for the
/// `24_5` bounds. It needs no key but is undocumented: any failure just leaves
/// Yahoo's last price on screen. Pre-market, regular hours and after hours
/// never use it.
enum OvernightQuoteFeed {
    struct Trade: Equatable {
        let symbol: String
        let price: Double
        /// Unix seconds of the trade at the venue, not of the poll.
        let time: Double
    }

    /// 8 PM ET is still the after-hours close, so the session starts after it.
    static func isActive(at date: Date) -> Bool {
        !PortfolioTradingCalendar.isExtendedSession(date) && PortfolioTradingCalendar.isOvernightSession(date)
    }

    /// The 8 PM ET that opened the session `date` falls in.
    static func sessionStart(containing date: Date) -> Date? {
        guard isActive(at: date) else { return nil }
        let cal = PortfolioTradingCalendar.calendar
        let day = cal.component(.hour, from: date) >= 20 ? date : cal.date(byAdding: .day, value: -1, to: date)!
        return cal.date(bySettingHour: 20, minute: 0, second: 0, of: day)
    }

    static func url(for symbols: [String]) -> URL? {
        guard !symbols.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.robinhood.com/marketdata/quotes/")!
        components.queryItems = [URLQueryItem(name: "bounds", value: "24_5"),
                                 URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
        return components.url
    }

    /// Unknown symbols come back as `null` entries and are skipped.
    static func parse(_ data: Data) -> [Trade] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [Any] else { return [] }
        return results.compactMap { entry in
            guard let row = entry as? [String: Any],
                  let symbol = row["symbol"] as? String,
                  let price = (row["last_non_reg_trade_price"] as? String).flatMap(Double.init),
                  price.isFinite, price > 0,
                  let stamp = row["venue_last_non_reg_trade_time"] as? String,
                  let time = unixTime(stamp) else { return nil }
            return Trade(symbol: symbol.uppercased(), price: price, time: time)
        }
    }

    /// Venue times carry up to nine fractional digits, which
    /// `ISO8601DateFormatter` won't read, so the fraction is added separately.
    private static func unixTime(_ stamp: String) -> Double? {
        guard stamp.hasSuffix("Z") else { return nil }
        let body = stamp.dropLast()
        let parts = body.split(separator: ".", maxSplits: 1)
        guard let whole = ISO8601DateFormatter().date(from: parts[0] + "Z") else { return nil }
        guard parts.count == 2 else { return whole.timeIntervalSince1970 }
        guard let fraction = Double("0." + parts[1]) else { return nil }
        return whole.timeIntervalSince1970 + fraction
    }

    /// Stamps each matching stock with its latest trade. A trade older than the
    /// one already held is ignored, and crypto sharing a ticker is untouched.
    static func merge(_ trades: [Trade], into quotes: [MarketQuote], receivedAt: Double) -> [MarketQuote] {
        let latest = Dictionary(trades.map { ($0.symbol, $0) }, uniquingKeysWith: { $0.time >= $1.time ? $0 : $1 })
        return quotes.map { quote in
            guard quote.kind == .stock, let trade = latest[quote.symbol.uppercased()],
                  trade.time >= (quote.overnightTradeTime ?? 0) else { return quote }
            var updated = quote
            updated.overnightPrice = trade.price
            updated.overnightTradeTime = trade.time
            updated.receivedAt = receivedAt
            return updated
        }
    }
}
