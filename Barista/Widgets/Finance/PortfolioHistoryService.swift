import Foundation

// MARK: - Portfolio History

/// Records what each portfolio was worth over time, so the card can show a trend
/// rather than only today's move.
///
/// Points are timestamped and keyed by portfolio id. New values are sampled at
/// most every ten minutes, and the store is thinned in tiers as it ages: full
/// detail for recent days, hourly for the last few months, then one closing
/// value per day. That keeps 1W and 1M readable as curves without growing
/// without bound.
///
/// Normally history only exists from the first run, since it depends on the
/// holdings as they were at the time rather than on past prices alone. It can be
/// reconstructed for a period the owner confirms their holdings did not change.
final class PortfolioHistoryService {
    static let shared = PortfolioHistoryService()

    struct Point: Codable, Equatable {
        /// When the value was observed. Recent points carry a real time of day;
        /// older ones are collapsed to one per day and sit at local midnight.
        /// The stored key stays "day" so existing history keeps decoding.
        let time: Date
        let value: Double

        enum CodingKeys: String, CodingKey {
            case time = "day"
            case value
        }
    }

    enum Range: String, Codable, CaseIterable {
        /// Today's session, rebuilt live from intraday quotes rather than read
        /// from the stored daily series.
        case today
        case week, month, quarter, halfYear, all

        var isIntraday: Bool { self == .today }

        /// Nil means "everything on record".
        var days: Int? {
            switch self {
            case .today:    return 1
            case .week:     return 7
            case .month:    return 30
            case .quarter:  return 90
            case .halfYear: return 180
            case .all:      return nil
            }
        }

        var label: String {
            switch self {
            case .today:    return "1D"
            case .week:     return "1W"
            case .month:    return "1M"
            case .quarter:  return "3M"
            case .halfYear: return "6M"
            case .all:      return "ALL"
            }
        }
    }

    private static let storeKey = "barista.portfolioHistory"
    private static let retentionDays = 120

    /// How close together points may be while a day is still "recent". Ten
    /// minutes over a session is roughly 40 points a day, which is enough to
    /// give 1W and 1M some shape without bloating the store.
    private static let minimumSpacing: TimeInterval = 10 * 60

    /// Days kept at full 10-minute resolution.
    private static let fineDays = 10

    /// Days kept at hourly resolution beyond that, so 1M and 3M still have shape
    /// rather than collapsing to one point per day.
    private static let hourlyDays = 95

    private var series: [String: [Point]] = [:]
    private let queue = DispatchQueue(label: "barista.portfolioHistory", attributes: .concurrent)

    private init() { load() }

    // MARK: - Recording

    /// Records the current value for a portfolio. Cheap enough to call on every
    /// refresh: points closer together than `minimumSpacing` overwrite the last
    /// one rather than accumulating.
    func record(portfolioID: String, value: Double) {
        guard value.isFinite, value > 0 else { return }
        let now = Date()

        queue.async(flags: .barrier) {
            var points = self.series[portfolioID] ?? []
            if let last = points.last, now.timeIntervalSince(last.time) < Self.minimumSpacing {
                points[points.count - 1] = Point(time: now, value: value)
            } else {
                points.append(Point(time: now, value: value))
            }
            self.series[portfolioID] = self.compact(points, now: now)
            self.save()
        }
    }

    /// Thins history in three tiers rather than flattening everything old to a
    /// single daily point: recent days keep full detail, the last few months keep
    /// hourly shape so 1M and 3M still read as curves, and anything older keeps
    /// one closing value per day.
    private func compact(_ points: [Point], now: Date) -> [Point] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let fineCutoff = cal.date(byAdding: .day, value: -Self.fineDays, to: today),
              let hourlyCutoff = cal.date(byAdding: .day, value: -Self.hourlyDays, to: today),
              let dropCutoff = cal.date(byAdding: .day, value: -Self.retentionDays, to: today)
        else { return points }

        var fine: [Point] = []
        var hourly: [Date: Point] = [:]   // keyed to the hour
        var daily: [Date: Point] = [:]    // keyed to the day

        for p in points where p.time >= dropCutoff {
            if p.time >= fineCutoff {
                fine.append(p)
            } else if p.time >= hourlyCutoff {
                let hour = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: p.time))
                    ?? cal.startOfDay(for: p.time)
                if let existing = hourly[hour], existing.time >= p.time { continue }
                hourly[hour] = p
            } else {
                let day = cal.startOfDay(for: p.time)
                if let existing = daily[day], existing.time >= p.time { continue }
                daily[day] = p
            }
        }
        return (Array(daily.values) + Array(hourly.values) + fine).sorted { $0.time < $1.time }
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
            guard let days = range.days,
                  let cutoff = Calendar.current.date(byAdding: .day,
                                                     value: -days,
                                                     to: Calendar.current.startOfDay(for: Date()))
            else { return all }
            return all.filter { $0.time >= cutoff }
        }
    }

    /// Best and worst single-day moves inside the range, as percentages.
    func extremeMoves(for portfolioID: String, range: Range) -> (best: (day: Date, pct: Double),
                                                                 worst: (day: Date, pct: Double))? {
        let pts = points(for: portfolioID, range: range)
        guard pts.count >= 2 else { return nil }

        // Collapse to one closing value per day first: with intraday sampling,
        // consecutive points can be minutes apart, and "best day" would quietly
        // become "best ten minutes".
        let cal = Calendar.current
        var closingByDay: [Date: (Date, Double)] = [:]
        for p in pts {
            let day = cal.startOfDay(for: p.time)
            if let existing = closingByDay[day], existing.0 >= p.time { continue }
            closingByDay[day] = (p.time, p.value)
        }
        let daily = closingByDay.keys.sorted().compactMap { closingByDay[$0] }
        guard daily.count >= 2 else { return nil }

        var moves: [(Date, Double)] = []
        for (a, b) in zip(daily, daily.dropFirst()) where a.1 > 0 {
            moves.append((b.0, (b.1 - a.1) / a.1 * 100))
        }
        guard let best = moves.max(by: { $0.1 < $1.1 }),
              let worst = moves.min(by: { $0.1 < $1.1 }) else { return nil }
        return ((best.0, best.1), (worst.0, worst.1))
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
