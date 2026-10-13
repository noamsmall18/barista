import Foundation
import Darwin

// MARK: - Portfolio History

/// Records what each portfolio was worth over time, so the card can show a trend
/// rather than only today's move.
///
/// Points are timestamped and keyed by portfolio id. New values are sampled
/// once per clock minute, and the store is thinned in tiers as it ages: full
/// detail for recent days, hourly for the last few months, then one closing
/// value per day. That keeps 1W and 1M readable as curves without growing
/// without bound.
///
/// Normally history only exists from the first run, since it depends on the
/// holdings as they were at the time rather than on past prices alone. It can be
/// reconstructed for a period the owner confirms their holdings did not change.
final class PortfolioHistoryService {
    static let shared = PortfolioHistoryService(lockURL: AppPreferences.isRunningTests ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppFlavor.current.displayName + "/portfolio-history.lock"))

    struct Point: Codable, Equatable {
        /// When the value was observed. Legacy daily points may sit at local
        /// midnight; new compaction preserves the actual observation time.
        /// The stored key stays "day" so existing history keeps decoding.
        let time: Date
        var value: Double
        // Optional additions retain compatibility with the original day/value store.
        var trading: Trading? = nil
        var holdings: [String: Double]? = nil
        var cash: Double? = nil
        /// Last observed prices for held symbols, used if an edit removes a
        /// symbol from the watchlist before the next history observation.
        var prices: [String: Double]? = nil
        /// Net change caused by positions/cash rather than price movement.
        var flow: Double? = nil

        enum CodingKeys: String, CodingKey {
            case time = "day"
            case value, trading, holdings, cash, prices, flow
        }
    }

    enum Range: String, Codable, CaseIterable {
        /// Latest session's recorded observations, with a current-holdings
        /// estimate from intraday quotes until enough observations exist.
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
    enum Trading: String, Codable { case equities, overnight, continuous }

    struct Valuation: Equatable {
        let holdings: [String: Double]
        let cash: Double
        let prices: [String: Double]
    }

    private var pendingEdits: [String: (holdings: [String: Double], cash: Double, since: Date)] = [:]

    /// Keep each observed minute while recent. Faster quote refreshes update
    /// the current minute rather than replacing the preceding minutes.
    private static let minimumSpacing: TimeInterval = 60

    /// Days kept at full one-minute resolution.
    private static let fineDays = 10

    /// Days kept at hourly resolution beyond that, so 1M and 3M still have shape
    /// rather than collapsing to one point per day.
    private static let hourlyDays = 95

    private var series: [String: [Point]] = [:]
    private var loadedData: Data?
    private let queue = DispatchQueue(label: "barista.portfolioHistory", attributes: .concurrent)

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let lockURL: URL?

    init(defaults: UserDefaults = ResearchWorkspaceDefaults.shared, clock: @escaping () -> Date = Date.init,
         lockURL: URL? = nil) {
        self.defaults = defaults
        self.clock = clock
        self.lockURL = lockURL
        load()
    }

    // MARK: - Recording

    /// Records the current value for a portfolio. Cheap enough to call on every
    /// refresh: points within the same clock minute overwrite the last one
    /// rather than accumulating, except where a flow boundary must be preserved.
    func record(portfolioID: String, value: Double, trading: Trading = .equities,
                valuation: Valuation? = nil) {
        guard value.isFinite, value > 0 else { return }
        let now = clock()
        guard Self.isSession(now, trading: trading) else { return }

        queue.async(flags: .barrier) {
            self.withStoreLock {
                self.load()
                var points = self.series[portfolioID] ?? []
                guard points.last.map({ now >= $0.time }) ?? true else { return }
                let last = points.last
                var flow = 0.0
                var compositionChanged = false
                if let valuation, let oldHoldings = last?.holdings, let oldCash = last?.cash {
                    let changed = oldHoldings != valuation.holdings || oldCash != valuation.cash
                    if changed {
                        compositionChanged = true
                        // A corrected typo must not immediately become a historical
                        // observation. Only accept a composition after it has settled.
                        let pending = self.pendingEdits[portfolioID]
                        if pending?.holdings != valuation.holdings || pending?.cash != valuation.cash {
                            self.pendingEdits[portfolioID] = (valuation.holdings, valuation.cash, now)
                            return
                        }
                        guard let pending, now.timeIntervalSince(pending.since) >= 120 else { return }
                        // Value the previous holdings using today's same prices. This
                        // separates external flows from the market move during the gap.
                        let prices = (last?.prices ?? [:]).merging(valuation.prices) { _, current in current }
                        guard oldHoldings.keys.allSatisfy({ prices[$0].map { $0.isFinite && $0 > 0 } ?? false }) else { return }
                        let beforeFlow = oldHoldings.reduce(oldCash) { $0 + $1.value * prices[$1.key]! }
                        guard beforeFlow.isFinite, beforeFlow > 0 else { return }
                        flow = value - beforeFlow
                    }
                    self.pendingEdits.removeValue(forKey: portfolioID)
                }
                let point = Point(time: now, value: value, trading: trading,
                                  holdings: valuation?.holdings, cash: valuation?.cash,
                                  prices: valuation.map { v in v.prices.filter { v.holdings[$0.key] != nil } }, flow: flow)
                // Fixed clock buckets: replacing a point may update its timestamp,
                // but cannot move the bucket boundary forever on frequent refreshes.
                if let last, !compositionChanged, (last.flow ?? 0) == 0,
                   floor(now.timeIntervalSince1970 / Self.minimumSpacing)
                    == floor(last.time.timeIntervalSince1970 / Self.minimumSpacing) {
                    points[points.count - 1] = point
                } else {
                    points.append(point)
                }
                self.series[portfolioID] = self.compact(points, now: now)
                self.save()
            }
        }
    }

    private static func isSession(_ date: Date, trading: Trading) -> Bool {
        switch trading {
        case .continuous: return true
        case .equities: return PortfolioTradingCalendar.isExtendedSession(date)
        case .overnight: return PortfolioTradingCalendar.isOvernightSession(date)
        }
    }

    /// Native app shutdown waits for records queued by widget.stop() before exit.
    func flushPendingWrites() {
        queue.sync(flags: .barrier) { }
    }

    /// Thins history in three tiers rather than flattening everything old to a
    /// single daily point: recent days keep full detail, the last few months keep
    /// hourly shape so 1M and 3M still read as curves, and anything older keeps
    /// one closing value per day.
    private func compact(_ points: [Point], now: Date) -> [Point] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let fineCutoff = cal.date(byAdding: .day, value: -Self.fineDays, to: today),
              let hourlyCutoff = cal.date(byAdding: .day, value: -Self.hourlyDays, to: today)
        else { return points }

        var fine: [Point] = []
        var hourly: [Date: Point] = [:]   // keyed to the hour
        var daily: [Date: Point] = [:]    // keyed to the day

        let beforeFlows = Set(zip(points, points.dropFirst()).filter { ($0.1.flow ?? 0) != 0 }.map { $0.0.time })
        for p in points {
            if p.time >= fineCutoff || (p.flow ?? 0) != 0 || beforeFlows.contains(p.time) {
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
            self.withStoreLock {
                self.load()
                self.series.removeValue(forKey: portfolioID)
                self.pendingEdits.removeValue(forKey: portfolioID)
                self.save()
            }
        }
    }

    // MARK: - Reading

    /// Presentation is derived without rewriting any saved observations. Raw
    /// exposes original values; both views compress scheduled equity closures.
    func points(for portfolioID: String, range: Range, raw: Bool = false,
                continuous: Bool = false) -> [Point] {
        let all: [Point] = queue.sync(flags: .barrier) {
            withStoreLock {
                load()
                return series[portfolioID] ?? []
            } ?? []
        }
        var clean = Self.sessionPoints(all, continuous: continuous)
        if !raw {
            clean = Self.removingIsolatedGlitches(clean)
            clean = Self.adjustingFlows(clean)
        }
        guard let days = range.days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days,
                                                 to: Calendar.current.startOfDay(for: clock())) else { return clean }
        return clean.filter { $0.time >= cutoff }
    }

    static func sessionPoints(_ points: [Point], continuous: Bool = false) -> [Point] {
        var unique: [Date: Point] = [:]
        for p in points where p.value.isFinite && p.value > 0 {
            // Old daily records sat at the user's local midnight. Preserve them
            // as session closes; they are not off-hours refresh observations.
            let legacyDay = p.trading == nil && Calendar.current.startOfDay(for: p.time) == p.time
            let valid = continuous && p.trading == nil ? true : legacyDay
                ? PortfolioTradingCalendar.isTradingDay(p.time.addingTimeInterval(12 * 3600))
                : isSession(p.time, trading: p.trading ?? (continuous ? .continuous : .equities))
            if valid { unique[p.time] = p }
        }
        return unique.values.sorted { $0.time < $1.time }
    }

    static func removingIsolatedGlitches(_ points: [Point]) -> [Point] {
        guard points.count >= 5 else { return points }
        var excluded = Set<Int>()
        for start in 2..<(points.count - 2) {
            // Compare observations, not elapsed hours: the same bad print must
            // behave consistently in minute, hourly and compacted daily history.
            // A repeated bad quote can occupy two adjacent observations.
            for length in [2, 1] {
                let end = start + length
                guard end + 1 < points.count else { continue }
                let window = points[(start - 2)...(end + 1)]
                let reference = points[start - 1]
                // Never infer an anomaly across a known flow or composition
                // boundary. Legacy points have no metadata and remain eligible.
                guard window.allSatisfy({ ($0.flow ?? 0) == 0
                    && $0.holdings == reference.holdings && $0.cash == reference.cash }) else { continue }
                let neighbors = [points[start - 2].value, reference.value,
                                 points[end].value, points[end + 1].value]
                let lo = neighbors.min()!, hi = neighbors.max()!
                let center = (lo + hi) / 2
                let excursion = points[start..<end].map(\.value)
                let below = excursion.allSatisfy { $0 < lo }
                let above = excursion.allSatisfy { $0 > hi }
                guard below || above else { continue }
                let deviation = excursion.map { abs($0 - center) }.min()!
                let spread = max(hi - lo, excursion.max()! - excursion.min()!)
                // Two agreeing observations on EACH side must confirm the
                // recovery. Endpoints, unconfirmed recoveries and sustained
                // moves remain visible. Do not repeatedly filter our own output.
                if deviation > max(1, abs(center) * 0.0025), spread < deviation * 0.15 {
                    excluded.formUnion(start..<end)
                    break
                }
            }
        }
        return points.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
    }

    /// A return chain neutralizes quantity/cash edits while retaining genuine
    /// price moves. Rebase to the latest recorded total for a dollar readout.
    static func adjustingFlows(_ points: [Point]) -> [Point] {
        guard points.count >= 2, points.dropFirst().contains(where: { ($0.flow ?? 0) != 0 }) else { return points }
        var levels = [1.0]
        for (a, b) in zip(points, points.dropFirst()) {
            let preFlow = b.value - (b.flow ?? 0)
            let factor = preFlow > 0 && a.value > 0 ? preFlow / a.value : 1
            let level = levels.last! * factor
            guard level.isFinite, level > 0 else { return points }
            levels.append(level)
        }
        return zip(points, levels).map { point, level in
            var adjusted = point
            adjusted.value = (level / levels.last!) * points.last!.value
            return adjusted
        }
    }

    /// Best and worst single-day moves inside the range, as percentages.
    func extremeMoves(for portfolioID: String, range: Range) -> (best: (day: Date, pct: Double),
                                                                 worst: (day: Date, pct: Double))? {
        Self.extremeMoves(in: points(for: portfolioID, range: range))
    }

    static func extremeMoves(in pts: [Point]) -> (best: (day: Date, pct: Double), worst: (day: Date, pct: Double))? {
        guard pts.count >= 2 else { return nil }

        // Collapse to one closing value per day first: with intraday sampling,
        // consecutive points can be minutes apart, and "best day" would quietly
        // become "best minute".
        let cal = PortfolioTradingCalendar.calendar
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

    /// Number of stored observations, including those exposed only in Raw.
    func sampleCount(for portfolioID: String) -> Int {
        queue.sync(flags: .barrier) {
            withStoreLock {
                load()
                return series[portfolioID]?.count ?? 0
            } ?? 0
        }
    }

    /// Change across the range. Nil until there are two points to compare.
    func change(for portfolioID: String, range: Range) -> (absolute: Double, percent: Double)? {
        let pts = points(for: portfolioID, range: range)
        guard pts.count >= 2, let first = pts.first, let last = pts.last, first.value > 0 else { return nil }
        let absolute = last.value - first.value
        return (absolute, absolute / first.value * 100)
    }

    // MARK: - Persistence

    /// App and headless research share this store. Serialize the entire
    /// reload/mutate/synchronize operation across processes, never just the write.
    @discardableResult
    private func withStoreLock<T>(_ body: () -> T) -> T? {
        guard let lockURL else { return body() }
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(series) else { return }
        defaults.set(data, forKey: Self.storeKey)
        defaults.synchronize()
        loadedData = data
    }

    private func load() {
        defaults.synchronize()
        guard let data = defaults.data(forKey: Self.storeKey) else {
            // A full restore may legitimately predate chart history. Do not
            // resurrect the previous in-memory series on the next quote.
            series.removeAll()
            pendingEdits.removeAll()
            loadedData = nil
            return
        }
        guard data != loadedData,
              let decoded = try? JSONDecoder().decode([String: [Point]].self, from: data) else { return }
        series = decoded.mapValues { $0.sorted { $0.time < $1.time } }
        loadedData = data
    }
}
