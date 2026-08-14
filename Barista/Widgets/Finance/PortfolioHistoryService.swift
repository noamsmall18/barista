import Foundation

// MARK: - Portfolio History

/// Records what each portfolio was worth over time, so the card can show a trend
/// rather than only today's move.
///
/// One point per calendar day, keyed by portfolio id. The current day's point is
/// overwritten as prices move, so the newest value is always live and older days
/// settle on whatever was last seen that day. History only exists from the first
/// day this runs - there is no way to backfill it, since it depends on holdings
/// as they were at the time, not just past prices.
final class PortfolioHistoryService {
    static let shared = PortfolioHistoryService()

    struct Point: Codable, Equatable {
        let day: Date        // start of day, local
        let value: Double
    }

    enum Range: String, Codable, CaseIterable {
        case week, month, quarter

        var days: Int {
            switch self {
            case .week:    return 7
            case .month:   return 30
            case .quarter: return 90
            }
        }

        var label: String {
            switch self {
            case .week:    return "1W"
            case .month:   return "1M"
            case .quarter: return "3M"
            }
        }
    }

    private static let storeKey = "barista.portfolioHistory"
    private static let retentionDays = 120

    private var series: [String: [Point]] = [:]
    private let queue = DispatchQueue(label: "barista.portfolioHistory", attributes: .concurrent)

    private init() { load() }

    // MARK: - Recording

    /// Records the current value for a portfolio, replacing today's point.
    /// Cheap enough to call on every refresh.
    func record(portfolioID: String, value: Double) {
        guard value.isFinite, value > 0 else { return }
        let today = Calendar.current.startOfDay(for: Date())

        queue.async(flags: .barrier) {
            var points = self.series[portfolioID] ?? []
            if let last = points.last, Calendar.current.isDate(last.day, inSameDayAs: today) {
                points[points.count - 1] = Point(day: today, value: value)
            } else {
                points.append(Point(day: today, value: value))
            }

            if let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: today) {
                points.removeAll { $0.day < cutoff }
            }
            self.series[portfolioID] = points
            self.save()
        }
    }

    /// Drops history for a portfolio that no longer exists.
    func forget(portfolioID: String) {
        queue.async(flags: .barrier) {
            self.series.removeValue(forKey: portfolioID)
            self.save()
        }
    }

    // MARK: - Reading

    func points(for portfolioID: String, range: Range) -> [Point] {
        queue.sync {
            let all = series[portfolioID] ?? []
            guard let cutoff = Calendar.current.date(byAdding: .day,
                                                     value: -range.days,
                                                     to: Calendar.current.startOfDay(for: Date()))
            else { return all }
            return all.filter { $0.day >= cutoff }
        }
    }

    /// Number of days recorded overall, used to tell "nothing yet" from "one day in".
    func sampleCount(for portfolioID: String) -> Int {
        queue.sync { series[portfolioID]?.count ?? 0 }
    }

    /// Change across the range. Nil until there are two points to compare.
    func change(for portfolioID: String, range: Range) -> (absolute: Double, percent: Double)? {
        let pts = points(for: portfolioID, range: range)
        guard pts.count >= 2, let first = pts.first, let last = pts.last, first.value > 0 else { return nil }
        let absolute = last.value - first.value
        return (absolute, absolute / first.value * 100)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(series) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([String: [Point]].self, from: data) else { return }
        series = decoded
    }
}
