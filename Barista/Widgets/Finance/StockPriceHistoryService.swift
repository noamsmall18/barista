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
