import Foundation

// MARK: - Secondary quote source

/// One quote from the backup feed, reduced to the fields the app can use.
struct SecondaryQuote: Equatable {
    var symbol: String
    /// Last regular-session trade.
    var lastTrade: Double?
    /// Last trade outside the regular session, and when the venue printed it.
    var extendedTrade: Double?
    var extendedTradeTime: Double?
    var bid: Double?
    var ask: Double?
    var previousClose: Double?
}

/// A second free, keyless feed for US stocks and ETFs: Robinhood's public
/// quote endpoint. It does two jobs the Yahoo chart feed cannot.
///
/// It keeps prices moving when Yahoo throttles or fails, and during the
/// overnight session it supplies what Yahoo's `fulldayPrice` lacks: the time of
/// the last trade, and five-minute bars for the chart.
///
/// The endpoint is public but undocumented, so every caller treats a failure
/// here as "no second opinion" and carries on with what it already has.
enum SecondaryQuoteSource {
    static let name = "Robinhood"
    static let host = "api.robinhood.com"

    /// The feed's spelling of a symbol, or nil when it does not list it:
    /// indexes, futures, currency pairs and non-US listings.
    static func feedSymbol(for symbol: String) -> String? {
        let upper = symbol.uppercased()
        guard !upper.isEmpty, upper.count <= 6,
              upper.allSatisfy({ $0.isLetter || $0 == "-" }),
              upper.first?.isLetter == true, upper.last?.isLetter == true else { return nil }
        // Share classes: Yahoo writes BRK-B, the feed writes BRK.B.
        return upper.replacingOccurrences(of: "-", with: ".")
    }

    private static func query(_ symbols: [String]) -> String? {
        let mapped = symbols.compactMap(feedSymbol(for:))
        return mapped.isEmpty ? nil : mapped.joined(separator: ",")
    }

    /// `overnight` asks for the 24-hour view, where the last extended trade and
    /// the previous close both refer to the session that just ended.
    static func quotesURL(symbols: [String], overnight: Bool) -> URL? {
        guard let list = query(symbols) else { return nil }
        return URL(string: "https://\(host)/marketdata/quotes/?symbols=\(list)" + (overnight ? "&bounds=24_5" : ""))
    }

    static func overnightBarsURL(symbols: [String]) -> URL? {
        guard let list = query(symbols) else { return nil }
        return URL(string: "https://\(host)/marketdata/historicals/?symbols=\(list)&bounds=24_5&interval=5minute&span=day")
    }

    // MARK: Parsing

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let n as NSNumber: parsed = n.doubleValue
        case let s as String: parsed = Double(s)
        default: parsed = nil
        }
        guard let parsed, parsed.isFinite, parsed > 0 else { return nil }
        return parsed
    }

    private static func time(_ value: Any?) -> Double? {
        guard let raw = value as? String else { return nil }
        // Venue stamps carry up to nanoseconds, which ISO8601DateFormatter rejects.
        var trimmed = raw
        if let dot = raw.firstIndex(of: "."), let zone = raw.lastIndex(where: { $0 == "Z" || $0 == "+" }), dot < zone {
            trimmed = String(raw[..<dot]) + String(raw[zone...])
        }
        return ISO8601DateFormatter().date(from: trimmed)?.timeIntervalSince1970
    }

    private static func results(_ data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["results"] as? [Any] else { return [] }
        // Unknown symbols come back as nulls in an otherwise good response.
        return rows.compactMap { $0 as? [String: Any] }
    }

    /// Keyed by the app's spelling of each requested symbol.
    static func parseQuotes(_ data: Data, symbols: [String]) -> [String: SecondaryQuote] {
        let appSymbol = Dictionary(symbols.compactMap { s in feedSymbol(for: s).map { ($0, s) } },
                                   uniquingKeysWith: { first, _ in first })
        var out: [String: SecondaryQuote] = [:]
        for row in results(data) {
            guard let feed = row["symbol"] as? String, let symbol = appSymbol[feed],
                  row["trading_halted"] as? Bool != true else { continue }
            out[symbol] = SecondaryQuote(
                symbol: symbol,
                lastTrade: number(row["last_trade_price"]),
                extendedTrade: number(row["last_non_reg_trade_price"]) ?? number(row["last_extended_hours_trade_price"]),
                extendedTradeTime: time(row["venue_last_non_reg_trade_time"]),
                bid: number(row["bid_price"]), ask: number(row["ask_price"]),
                previousClose: number(row["adjusted_previous_close"]) ?? number(row["previous_close"]))
        }
        return out
    }

    /// Overnight five-minute closes per symbol, oldest first.
    static func parseOvernightBars(_ data: Data, symbols: [String]) -> [String: SessionSeries] {
        let appSymbol = Dictionary(symbols.compactMap { s in feedSymbol(for: s).map { ($0, s) } },
                                   uniquingKeysWith: { first, _ in first })
        var out: [String: SessionSeries] = [:]
        for row in results(data) {
            guard let feed = row["symbol"] as? String, let symbol = appSymbol[feed],
                  let bars = row["historicals"] as? [[String: Any]] else { continue }
            var series = SessionSeries()
            for bar in bars where bar["session"] as? String == "overnight" && bar["interpolated"] as? Bool != true {
                guard let close = number(bar["close_price"]), let at = time(bar["begins_at"]) else { continue }
                series.closes.append(close); series.times.append(at)
            }
            if !series.isEmpty { out[symbol] = series }
        }
        return out
    }

    // MARK: Applying

    /// Folds a backup quote into the one the app already holds.
    ///
    /// Only the field for the session in progress is touched, so the regular
    /// close, the chart and the day's baseline all survive. Returns nil when
    /// the backup has nothing usable for this session, rather than guessing.
    static func apply(_ backup: SecondaryQuote, to existing: MarketQuote?,
                      status: MarketStatus, now: Date = Date()) -> MarketQuote? {
        func percent(from base: Double, to value: Double) -> Double {
            base > 0 ? (value - base) / base * 100 : 0
        }
        func stamped(_ quote: MarketQuote) -> MarketQuote {
            var quote = quote
            quote.receivedAt = now.timeIntervalSince1970
            quote.source = name
            return quote
        }

        switch status {
        case .open:
            guard let last = backup.lastTrade else { return nil }
            guard var quote = existing else {
                guard let prev = backup.previousClose else { return nil }
                return stamped(MarketQuote(symbol: backup.symbol, price: last, change: percent(from: prev, to: last),
                                           kind: .stock, previousClose: prev, sparkline: [prev, last]))
            }
            quote.price = last
            if let prev = quote.previousClose ?? backup.previousClose {
                quote.change = percent(from: prev, to: last)
            }
            return stamped(quote)

        case .preMarket:
            guard var quote = existing, let print = backup.extendedTrade,
                  let prev = quote.previousClose, prev > 0 else { return nil }
            // Before the first pre-market trade the feed still reports last
            // night's print, which is not this morning's move.
            if let at = backup.extendedTradeTime, now.timeIntervalSince1970 - at > 6 * 3600 { return nil }
            quote.preMarketPrice = print
            quote.preMarketChange = percent(from: prev, to: print)
            return stamped(quote)

        case .afterHours:
            guard var quote = existing, let print = backup.extendedTrade, quote.price > 0 else { return nil }
            if let at = backup.extendedTradeTime, now.timeIntervalSince1970 - at > 4 * 3600 { return nil }
            quote.postMarketPrice = print
            quote.postMarketChange = percent(from: quote.price, to: print)
            return stamped(quote)

        case .overnight:
            guard var quote = existing, let print = backup.extendedTrade, quote.price > 0 else { return nil }
            quote.overnightPrice = print
            quote.overnightChange = percent(from: quote.price, to: print)
            quote.overnightTradeTime = backup.extendedTradeTime
            return stamped(quote)

        case .closed:
            return nil
        }
    }
}
