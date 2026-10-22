import Foundation

enum StockChartRange: String, CaseIterable {
    case oneDay = "1D"
    case fiveDay = "5D"
    case oneMonth = "1M"
    case sixMonth = "6M"
    case oneYear = "1Y"
    case fiveYear = "5Y"

    var yahooRange: String {
        switch self {
        case .oneDay: return "1d"
        case .fiveDay: return "5d"
        case .oneMonth: return "1mo"
        case .sixMonth: return "6mo"
        case .oneYear: return "1y"
        case .fiveYear: return "5y"
        }
    }

    var interval: String {
        switch self {
        case .oneDay: return "1m"
        case .fiveDay: return "5m"
        case .oneMonth: return "1d"
        case .sixMonth: return "1d"
        case .oneYear: return "1d"
        case .fiveYear: return "1wk"
        }
    }

    var cacheAge: TimeInterval {
        switch self {
        case .oneDay: return 5
        case .fiveDay: return 15
        case .oneMonth: return 60
        case .sixMonth: return 2 * 60
        case .oneYear: return 5 * 60
        case .fiveYear: return 10 * 60
        }
    }
}

struct StockPricePoint {
    let date: Date
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double
    let volume: Double?
}

struct StockPriceHistory {
    let symbol: String
    let range: StockChartRange
    let currency: String
    let instrumentType: String?
    let companyName: String?
    let exchangeTimezone: String
    let previousClose: Double?
    let fetchedAt: Date
    let points: [StockPricePoint]

    var latest: StockPricePoint? { points.last }
    var firstClose: Double? { points.first?.close }

    var percentChange: Double {
        guard let firstClose, let latest = latest?.close, firstClose > 0 else { return 0 }
        return (latest - firstClose) / firstClose * 100
    }

    var absoluteChange: Double {
        guard let firstClose, let latest = latest?.close else { return 0 }
        return latest - firstClose
    }
}

final class StockPriceHistoryService {
    static let shared = StockPriceHistoryService()

    private let cacheQueue = DispatchQueue(label: "barista.stockpricehistory.cache")
    private var cache: [String: StockPriceHistory] = [:]
    private var allTimeCache: [String: (high: Double, low: Double, fetchedAt: Date)] = [:]
    private static let allTimeCacheAge: TimeInterval = 30 * 60

    private init() {}

    func fetch(symbol: String, range: StockChartRange, force: Bool = false, completion: @escaping (Result<StockPriceHistory, Error>) -> Void) {
        let upper = symbol.uppercased()
        let key = "\(upper):\(range.rawValue)"
        let cached: StockPriceHistory? = cacheQueue.sync { cache[key] }
        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < range.cacheAge {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }

        let safe = upper.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? upper
        let urlString = "https://query1.finance.yahoo.com/v8/finance/chart/\(safe)?interval=\(range.interval)&range=\(range.yahooRange)&includePrePost=true&events=div%7Csplit"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(.failure(URLError(.badURL))) }
            return
        }

        DataFetcher.shared.fetch(url: url, maxAge: force ? 0 : range.cacheAge) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let history = try self.parse(data: data, symbol: upper, range: range)
                    self.cacheQueue.sync { self.cache[key] = history }
                    DispatchQueue.main.async { completion(.success(history)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Highest high and lowest low across the symbol's whole trading history.
    /// Coarse bars keep the payload small; each bar's high and low still cover
    /// every trade inside it, so the extremes are exact (split-adjusted).
    func fetchAllTimeRange(symbol: String, completion: @escaping (Result<(high: Double, low: Double), Error>) -> Void) {
        let upper = symbol.uppercased()
        let cached: (high: Double, low: Double, fetchedAt: Date)? = cacheQueue.sync { allTimeCache[upper] }
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.allTimeCacheAge {
            DispatchQueue.main.async { completion(.success((cached.high, cached.low))) }
            return
        }
        let safe = upper.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? upper
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(safe)?interval=1mo&range=max") else {
            DispatchQueue.main.async { completion(.failure(URLError(.badURL))) }
            return
        }
        DataFetcher.shared.fetch(url: url, maxAge: Self.allTimeCacheAge) { [weak self] result in
            guard let self else { return }
            let parsed = result.flatMap { data in
                Result { try Self.parseAllTimeRange(data: data) }
            }
            if case .success(let range) = parsed {
                self.cacheQueue.sync { self.allTimeCache[upper] = (range.high, range.low, Date()) }
            }
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    static func parseAllTimeRange(data: Data) throws -> (high: Double, low: Double) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let indicators = results.first?["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first else {
            throw URLError(.cannotParseResponse)
        }
        func values(_ key: String) -> [Double] {
            ((quote[key] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }.filter { $0.isFinite && $0 > 0 }
        }
        let closes = values("close")
        guard let high = (values("high") + closes).max(),
              let low = (values("low") + closes).min() else {
            throw URLError(.cannotParseResponse)
        }
        return (high, low)
    }

    private func parse(data: Data, symbol: String, range: StockChartRange) throws -> StockPriceHistory {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let first = results.first,
              let timestamps = first["timestamp"] as? [Any],
              let indicators = first["indicators"] as? [String: Any],
              let quotes = indicators["quote"] as? [[String: Any]],
              let quote = quotes.first else {
            throw URLError(.cannotParseResponse)
        }

        let meta = first["meta"] as? [String: Any]
        let currency = (meta?["currency"] as? String) ?? "USD"
        let timezone = (meta?["exchangeTimezoneName"] as? String) ?? "America/New_York"
        let previousClose = number(meta?["chartPreviousClose"]) ?? number(meta?["previousClose"])
        let opens = series(quote["open"])
        let highs = series(quote["high"])
        let lows = series(quote["low"])
        let closes = series(quote["close"])
        let volumes = series(quote["volume"])

        var points: [StockPricePoint] = []
        for (index, rawTimestamp) in timestamps.enumerated() {
            guard let ts = number(rawTimestamp),
                  index < closes.count,
                  let close = closes[index],
                  close.isFinite,
                  close > 0 else { continue }
            points.append(StockPricePoint(date: Date(timeIntervalSince1970: ts),
                                          open: index < opens.count ? opens[index] : nil,
                                          high: index < highs.count ? highs[index] : nil,
                                          low: index < lows.count ? lows[index] : nil,
                                          close: close,
                                          volume: index < volumes.count ? volumes[index] : nil))
        }

        guard points.count >= 2 else { throw URLError(.cannotParseResponse) }
        return StockPriceHistory(symbol: symbol,
                                 range: range,
                                 currency: currency,
                                 instrumentType: meta?["instrumentType"] as? String,
                                 companyName: meta?["longName"] as? String ?? meta?["shortName"] as? String,
                                 exchangeTimezone: timezone,
                                 previousClose: previousClose,
                                 fetchedAt: Date(),
                                 points: points)
    }

    private func series(_ raw: Any?) -> [Double?] {
        guard let array = raw as? [Any] else { return [] }
        return array.map(number)
    }

    private func number(_ raw: Any?) -> Double? {
        if raw is NSNull { return nil }
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }
}
