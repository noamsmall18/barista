import Foundation

enum StockTickerRefreshPolicy {
    static let fastestEquityPoll: TimeInterval = 2
    static let ultraFastCryptoFallbackPoll: TimeInterval = 60

    /// Kraken's public spot stream currently supports USD pairs for this curated
    /// mapping. Unsupported coins and non-USD quote currencies stay on the app's
    /// existing REST source.
    private static let streamableUSDCoins: [String: String] = [
        "bitcoin": "BTC/USD", "ethereum": "ETH/USD", "solana": "SOL/USD",
        "cardano": "ADA/USD", "dogecoin": "DOGE/USD", "ripple": "XRP/USD",
        "polkadot": "DOT/USD", "avalanche-2": "AVAX/USD", "chainlink": "LINK/USD",
        "litecoin": "LTC/USD", "uniswap": "UNI/USD", "cosmos": "ATOM/USD",
        "stellar": "XLM/USD", "sui": "SUI/USD"
    ]

    static func streamPairs(coins: [String], currency: String) -> [String] {
        guard currency.caseInsensitiveCompare("usd") == .orderedSame else { return [] }
        return coins.compactMap { streamableUSDCoins[$0.lowercased()] }
    }

    static func coinID(forPair pair: String) -> String? {
        streamableUSDCoins.first(where: { $0.value == pair })?.key
    }

    static func recentlyStreamedCoinIDs(_ coinIDs: Set<String>, receivedAt: [String: Date],
                                        now: Date, freshnessWindow: TimeInterval = ultraFastCryptoFallbackPoll) -> Set<String> {
        Set(coinIDs.filter { id in
            guard let date = receivedAt[id] else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < freshnessWindow
        })
    }

    static func shouldApplyRESTUpdate(requestStartedAt: Date, lastStreamReceivedAt: Date?) -> Bool {
        guard let lastStreamReceivedAt else { return true }
        return lastStreamReceivedAt <= requestStartedAt
    }

    static func summary(for mode: StockTickerRefreshMode, currency: String,
                        configuredInterval: TimeInterval = 5) -> String {
        switch mode {
        case .standard:
            let interval = configuredInterval.isFinite ? max(2, configuredInterval) : 5
            return "Stocks poll every \(Int(interval))s during market hours; crypto polls every \(Int(max(interval, 15)))s"
        case .ultraFast:
            let hasStream = currency.caseInsensitiveCompare("usd") == .orderedSame
            return hasStream
                ? "Stocks poll every 2s during market hours; supported USD crypto streams live with 60s REST fallback"
                : "Stocks poll every 2s during market hours; crypto polls every 15s"
        }
    }
}
