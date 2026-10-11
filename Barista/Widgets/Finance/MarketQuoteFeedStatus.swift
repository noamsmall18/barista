import Foundation

extension MarketQuote {
    /// Quote-specific receipt age avoids letting a busy crypto stream make an
    /// older stock quote look fresh. Receipt time does not assert exchange latency.
    func feedStatusDescription(now: Date = Date()) -> String {
        let provider = source ?? (kind == .stock ? "Yahoo Finance" : "CoinGecko")
        guard let receivedAt, receivedAt.isFinite, receivedAt > 0 else {
            return "\(provider) · receipt time unavailable"
        }
        let age = max(0, now.timeIntervalSince1970 - receivedAt)
        let elapsed: String
        if age < 60 { elapsed = "\(Int(age))s" }
        else if age < 3600 { elapsed = "\(Int(age / 60))m" }
        else { elapsed = "\(Int(age / 3600))h" }
        let received = "\(provider) · received \(elapsed) ago"
        // An overnight print can be much older than the fetch that carried it.
        let status = MarketStatus.fromYahooMarketState(marketState, at: now) ?? MarketStatus.current(at: now)
        guard kind == .stock, status == .overnight, overnightPrice != nil else { return received }
        guard let overnightTradeTime, overnightTradeTime > 0 else {
            return received + " · overnight trade time unavailable"
        }
        let tradeAge = max(0, now.timeIntervalSince1970 - overnightTradeTime)
        let traded: String
        if tradeAge < 60 { traded = "\(Int(tradeAge))s" }
        else if tradeAge < 3600 { traded = "\(Int(tradeAge / 60))m" }
        else { traded = "\(Int(tradeAge / 3600))h" }
        return received + " · last overnight trade \(traded) ago"
    }
}
