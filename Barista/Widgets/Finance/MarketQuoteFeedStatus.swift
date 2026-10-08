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
        return "\(provider) · received \(elapsed) ago"
    }
}
