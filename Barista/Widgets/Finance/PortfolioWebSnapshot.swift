import Foundation

/// Browser projection of the same models that drive the menu bar. No second
/// portfolio store, and missing prices/costs never become a made-up zero return.
enum PortfolioWebSnapshot {
    static func number(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }

    static func make(config: StockTickerConfig, quotes: [MarketQuote], indices: [MarketQuote]) -> [String: Any] {
        let positions = config.holdings.sorted { $0.key < $1.key }.compactMap { symbol, quantity -> PortfolioPosition? in
            guard quantity > 0, let quote = quotes.first(where: { $0.symbol == symbol }) else { return nil }
            return PortfolioPosition(quote: quote, quantity: quantity, averageCost: config.costBasis[symbol])
        }
        let missing = config.holdings.keys.filter { symbol in
            (config.holdings[symbol] ?? 0) > 0 && !positions.contains { $0.quote.symbol == symbol }
        }.sorted()
        let currencyComparable = positions.allSatisfy { ($0.quote.currency ?? "USD") == "USD" }
        let cash = config.cash
        let total = cash + positions.reduce(0) { $0 + $1.value }
        let baseline = cash + positions.reduce(0) { $0 + $1.baselineValue }
        let snapshot = PortfolioSnapshot(positions: positions, missingSymbols: missing, cash: cash,
                                         total: total, baselineTotal: baseline,
                                         dailyPL: positions.reduce(0) { $0 + $1.dailyPL })
        let rows: [[String: Any]] = quotes.map { quote in
            let position = positions.first { $0.quote.symbol == quote.symbol }
            var row = quoteJSON(quote)
            row["quantity"] = number(config.holdings[quote.symbol] ?? 0)
            row["averageCost"] = number(position?.averageCost)
            row["value"] = number(position?.liveValue)
            row["regularValue"] = number(position?.value)
            row["dayPL"] = number(position?.dailyPL)
            row["extendedPL"] = number(position?.extendedPL)
            row["unrealizedPL"] = number(position?.totalPL)
            row["unrealizedPercent"] = number(position?.totalPercent)
            row["weight"] = number(currencyComparable ? position.flatMap {
                snapshot.liveTotal.isFinite && snapshot.liveTotal != 0
                    ? $0.liveValue / snapshot.liveTotal * 100 : nil
            } : nil)
            if let event = EarningsCalendarService.shared.event(for: quote.symbol) {
                row["earnings"] = ["date": event.date.timeIntervalSince1970,
                                   "session": event.session ?? "Unspecified",
                                   "epsForecast": event.epsForecast ?? "Unavailable"] as [String: Any]
            }
            return row
        }
        let active = config.activePortfolio
        return [
            "app": AppFlavor.current.displayName,
            "portfolioID": config.activePortfolioID,
            "portfolioName": active?.name ?? "Portfolio",
            "portfolios": config.portfolios.map { ["id": $0.id, "name": $0.name] },
            "combinedPortfolio": config.isCombinedPortfolioActive,
            "quotes": rows, "indices": indices.map(quoteJSON), "missingSymbols": missing,
            "summary": ["currencyComparable": currencyComparable,
                        "liveTotal": number(currencyComparable ? snapshot.liveTotal : nil), "regularTotal": number(currencyComparable ? total : nil),
                        "dayPL": number(currencyComparable ? snapshot.dailyPL : nil), "dayPercent": number(currencyComparable ? snapshot.dailyPercent : nil),
                        "livePL": number(currencyComparable ? snapshot.livePL : nil), "livePercent": number(currencyComparable ? snapshot.livePercent : nil),
                        "extendedPL": number(currencyComparable ? snapshot.extendedPL : nil), "extendedLabel": snapshot.extendedLabel ?? "Extended hours",
                        "cash": number(currencyComparable ? cash : nil), "cost": number(currencyComparable ? snapshot.totalCost : nil),
                        "unrealizedPL": number(currencyComparable ? snapshot.totalPL : nil), "unrealizedPercent": number(currencyComparable ? snapshot.totalPercent : nil),
                        "partialCost": snapshot.hasPartialCostBasis,
                        "missingCostCount": snapshot.positionsMissingCost.count,
                        "realizedPL": number(active?.realizedTotal ?? 0),
                        "winners": snapshot.winners, "losers": snapshot.losers, "positions": positions.count] as [String: Any],
            "trades": (active?.tradeHistory ?? []).prefix(100).map { trade in
                ["date": trade.date.timeIntervalSince1970, "symbol": trade.symbol,
                 "side": trade.kind.label, "quantity": number(trade.quantity), "price": number(trade.price),
                 "note": trade.note ?? ""] as [String: Any]
            }
        ]
    }

    static func quoteJSON(_ q: MarketQuote) -> [String: Any] {
        ["symbol": q.symbol, "kind": q.kind.rawValue, "price": number(q.currentPrice),
         "currency": q.currency ?? "USD", "receivedAt": number(q.receivedAt),
         "source": q.source ?? (q.kind == .stock ? "Yahoo Finance" : "CoinGecko"),
         "regularPrice": number(q.price), "change": number(q.currentChange), "regularChange": number(q.change),
         "previousClose": number(q.previousClose), "dayHigh": number(q.dayHigh), "dayLow": number(q.dayLow),
         "volume": number(q.volume), "marketCap": number(q.marketCap), "pe": number(q.peRatio),
         "yearHigh": number(q.fiftyTwoWeekHigh), "yearLow": number(q.fiftyTwoWeekLow),
         "open": number(q.openPrice), "session": q.marketState ?? "Unknown",
         "extendedLabel": q.extendedHours?.label ?? "", "sparkline": q.chartSeries.filter(\.isFinite)]
    }
}
