import Foundation

// MARK: - Benchmark

/// Daily closes for a comparison index, rebased so a portfolio can be judged
/// against the market rather than against zero.
///
/// Reads Nasdaq rather than Yahoo. Yahoo's history endpoints are the ones that
/// throttle hardest, and a benchmark that silently fails to load is worse than
/// none; Nasdaq answers unauthenticated and is already the source for the
/// earnings calendar.
final class BenchmarkSeries {
    static let shared = BenchmarkSeries()

    static let defaultSymbol = "SPY"

    private var dailyCloses: [String: [Date: Double]] = [:]
    private var lastFetch: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "barista.benchmark", attributes: .concurrent)
    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let lookbackDays = 200

    private init() { load() }

    /// Closing price per day, keyed to local midnight to line up with history points.
    func closes(for symbol: String = defaultSymbol) -> [Date: Double] {
        queue.sync { dailyCloses[symbol] ?? [:] }
    }

    var isLoaded: Bool { !closes().isEmpty }

    // MARK: - Fetching

    func refreshIfNeeded(symbol: String = defaultSymbol, completion: (() -> Void)? = nil) {
        let due = queue.sync { () -> Bool in
            if dailyCloses[symbol] == nil { return true }
            guard let last = lastFetch[symbol] else { return true }
            return Date().timeIntervalSince(last) > Self.refreshInterval
        }
        guard due else { completion?(); return }

        let running = queue.sync { inFlight.contains(symbol) }
        guard !running else { completion?(); return }
        queue.async(flags: .barrier) { self.inFlight.insert(symbol) }

        // ETFs and equities live under different asset classes; try both.
        fetch(symbol: symbol, assetClass: "etf") { [weak self] map in
            guard let self else { return }
            if let map, !map.isEmpty {
                self.store(symbol: symbol, map: map, completion: completion)
            } else {
                self.fetch(symbol: symbol, assetClass: "stocks") { fallback in
                    self.store(symbol: symbol, map: fallback ?? [:], completion: completion)
                }
            }
        }
    }

    private func store(symbol: String, map: [Date: Double], completion: (() -> Void)?) {
        queue.async(flags: .barrier) {
            // Keep whatever we had rather than blanking the line on a failure.
            if !map.isEmpty {
                self.dailyCloses[symbol] = map
                self.lastFetch[symbol] = Date()
                self.save()
            }
            self.inFlight.remove(symbol)
            DispatchQueue.main.async { completion?() }
        }
    }

    private func fetch(symbol: String, assetClass: String, completion: @escaping ([Date: Double]?) -> Void) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: to) ?? to
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol

        guard let url = URL(string: "https://api.nasdaq.com/api/quote/\(encoded)/historical"
                            + "?assetclass=\(assetClass)&fromdate=\(fmt.string(from: from))"
                            + "&todate=\(fmt.string(from: to))&limit=400") else {
            completion(nil); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["data"] as? [String: Any],
                  let table = payload["tradesTable"] as? [String: Any],
                  let rows = table["rows"] as? [[String: Any]] else {
                completion(nil); return
            }
            let inFmt = DateFormatter()
            inFmt.dateFormat = "MM/dd/yyyy"
            inFmt.timeZone = TimeZone(identifier: "America/New_York")

            var map: [Date: Double] = [:]
            let cal = Calendar.current
            for row in rows {
                guard let dateStr = row["date"] as? String,
                      let closeStr = row["close"] as? String,
                      let date = inFmt.date(from: dateStr) else { continue }
                // Equities come back as "$28.77", ETFs as "777.88".
                let cleaned = closeStr.replacingOccurrences(of: "$", with: "")
                                      .replacingOccurrences(of: ",", with: "")
                                      .trimmingCharacters(in: .whitespaces)
                guard let close = Double(cleaned), close > 0 else { continue }
                map[cal.startOfDay(for: date)] = close
            }
            completion(map)
        }.resume()
    }

    // MARK: - Rebasing

    /// Rebases the benchmark onto the portfolio's own days and opening value, so
    /// both lines start together and the gap between them is relative performance.
    ///
    /// Returns nil unless most of the portfolio's days have a matching close - a
    /// benchmark drawn through gaps would misrepresent the comparison.
    func rebased(to portfolioDays: [Date],
                 startingAt startValue: Double,
                 symbol: String = defaultSymbol) -> [(date: Date, value: Double)]? {
        guard portfolioDays.count >= 2, startValue > 0 else { return nil }
        let map = closes(for: symbol)
        guard !map.isEmpty else { return nil }

        let cal = Calendar.current
        var matched: [(Date, Double)] = []
        for day in portfolioDays {
            if let close = map[cal.startOfDay(for: day)] {
                matched.append((day, close))
            }
        }
        guard matched.count >= max(2, Int(Double(portfolioDays.count) * 0.6)),
              let base = matched.first?.1, base > 0 else { return nil }

        return matched.map { (date: $0.0, value: startValue * ($0.1 / base)) }
    }

    // MARK: - Persistence

    private static let storeKey = "barista.benchmarkCloses"

    private func save() {
        let encodable = dailyCloses.mapValues { inner in
            inner.reduce(into: [String: Double]()) { acc, kv in
                acc[String(kv.key.timeIntervalSinceReferenceDate)] = kv.value
            }
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        else { return }
        dailyCloses = decoded.mapValues { inner in
            inner.reduce(into: [Date: Double]()) { acc, kv in
                if let t = Double(kv.key) {
                    acc[Date(timeIntervalSinceReferenceDate: t)] = kv.value
                }
            }
        }
    }
}
