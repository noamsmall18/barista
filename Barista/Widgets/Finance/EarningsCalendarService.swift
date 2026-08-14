import Foundation

// MARK: - Earnings Calendar

/// Upcoming earnings dates for watchlist symbols.
///
/// Yahoo's endpoints that carry earnings dates (v7/quote, v10/quoteSummary) now sit
/// behind a crumb/cookie and answer 429 without one; the v8/chart endpoint the rest
/// of the widget uses carries no event data at all. Nasdaq's calendar is open, but is
/// keyed by date rather than symbol - which suits a "what's coming up" badge: one
/// pass over the next handful of trading days covers every symbol at once, instead of
/// a request per ticker.
final class EarningsCalendarService {
    static let shared = EarningsCalendarService()

    struct Event: Codable, Equatable {
        let symbol: String
        let date: Date
        /// "pre", "post", or nil when Nasdaq doesn't say.
        let session: String?
        /// Consensus EPS estimate as Nasdaq formats it, e.g. "$1.43". Often absent.
        let epsForecast: String?

        var daysAway: Int {
            let cal = Calendar.current
            let from = cal.startOfDay(for: Date())
            let to = cal.startOfDay(for: date)
            return cal.dateComponents([.day], from: from, to: to).day ?? 0
        }

        /// "today", "tue", "3d" - kept short enough for a badge.
        var shortLabel: String {
            let days = daysAway
            if days <= 0 { return "today" }
            if days == 1 { return "tmrw" }
            if days <= 6 {
                let f = DateFormatter()
                f.dateFormat = "EEE"
                return f.string(from: date).lowercased()
            }
            return "\(days)d"
        }

        var sessionLabel: String? {
            switch session {
            case "pre":  return "pre"
            case "post": return "post"
            default:     return nil
            }
        }
    }

    /// How far ahead to look. Badges only matter for the near term, and each day
    /// costs one request.
    private static let horizonDays = 10
    private static let cacheKey = "barista.earningsCalendar"
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    private var events: [String: Event] = [:]
    private var lastFetch: Date?
    private var inFlight = false
    private let queue = DispatchQueue(label: "barista.earnings", attributes: .concurrent)

    private init() { loadCache() }

    /// Nil when the symbol has nothing scheduled inside the horizon.
    func event(for symbol: String) -> Event? {
        queue.sync { events[symbol.uppercased()] }
    }

    func refreshIfNeeded(completion: (() -> Void)? = nil) {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < Self.refreshInterval {
            completion?()
            return
        }
        guard !inFlight else { completion?(); return }
        inFlight = true
        fetchHorizon(completion: completion)
    }

    // MARK: - Fetching

    private func fetchHorizon(completion: (() -> Void)?) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [Date] = (0..<Self.horizonDays).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
            .filter { d in
                // Markets are shut at the weekend, so don't spend a request on those.
                let weekday = cal.component(.weekday, from: d)
                return weekday != 1 && weekday != 7
            }

        let group = DispatchGroup()
        var collected: [String: Event] = [:]
        let lock = NSLock()

        for day in days {
            group.enter()
            fetchDay(day) { found in
                lock.lock()
                for e in found where collected[e.symbol] == nil {
                    collected[e.symbol] = e
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.queue.async(flags: .barrier) {
                // An empty result usually means the endpoint refused us; keep the
                // previous map rather than blanking every badge.
                if !collected.isEmpty {
                    self.events = collected
                    self.lastFetch = Date()
                    self.saveCache()
                }
                self.inFlight = false
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    private func fetchDay(_ day: Date, completion: @escaping ([Event]) -> Void) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        let dayString = fmt.string(from: day)

        guard let url = URL(string: "https://api.nasdaq.com/api/calendar/earnings?date=\(dayString)") else {
            completion([]); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Nasdaq returns an empty body to the default URLSession agent.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["data"] as? [String: Any],
                  let rows = payload["rows"] as? [[String: Any]] else {
                completion([]); return
            }
            let events: [Event] = rows.compactMap { row in
                guard let raw = row["symbol"] as? String else { return nil }
                let symbol = raw.trimmingCharacters(in: .whitespaces).uppercased()
                guard !symbol.isEmpty else { return nil }
                let time = row["time"] as? String
                let session: String?
                if let time {
                    if time.contains("pre") { session = "pre" }
                    else if time.contains("after") { session = "post" }
                    else { session = nil }
                } else { session = nil }
                let forecast = (row["epsForecast"] as? String)?
                    .trimmingCharacters(in: .whitespaces)
                return Event(symbol: symbol, date: day, session: session,
                             epsForecast: (forecast?.isEmpty == false) ? forecast : nil)
            }
            completion(events)
        }.resume()
    }

    // MARK: - Cache

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(Array(events.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        UserDefaults.standard.set(lastFetch, forKey: Self.cacheKey + ".date")
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode([Event].self, from: data) else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Drop anything that has already happened.
        var map: [String: Event] = [:]
        for e in cached where cal.startOfDay(for: e.date) >= today {
            map[e.symbol] = e
        }
        events = map
        lastFetch = UserDefaults.standard.object(forKey: Self.cacheKey + ".date") as? Date
    }
}
