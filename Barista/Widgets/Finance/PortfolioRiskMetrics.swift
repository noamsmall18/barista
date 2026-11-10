import Foundation

// MARK: - Risk-adjusted return

/// Sharpe ratio for one portfolio, derived from its recorded value history.
///
/// The input is the flow-adjusted history (holding and cash edits already
/// neutralized), collapsed to one closing value per trading day. Daily returns
/// in excess of the risk-free rate are averaged, divided by their sample
/// standard deviation, and annualized by the square root of the number of
/// trading periods in a year.
///
/// It is an estimate from this app's observations, not a broker's audited
/// figure, and it is only as long as the history on record.
struct PortfolioRiskMetrics: Equatable {
    /// Fewer daily returns than this cannot produce a meaningful deviation.
    static let minimumReturns = 5
    /// Below this the figure is shown but flagged as early.
    static let settledReturns = 20
    static let defaultRiskFreePercent = 4.0

    /// Number of day-over-day returns the figures rest on.
    let dailyReturns: Int
    let firstDay: Date?
    let lastDay: Date?
    /// Annualized. Nil until `minimumReturns` exist or when returns never vary.
    let sharpe: Double?
    /// Total move across the covered days, in percent.
    let periodReturnPercent: Double?
    /// Annualized standard deviation of daily returns, in percent.
    let annualVolatilityPercent: Double?

    var isPreliminary: Bool { sharpe != nil && dailyReturns < Self.settledReturns }

    static let empty = PortfolioRiskMetrics(dailyReturns: 0, firstDay: nil, lastDay: nil, sharpe: nil,
                                            periodReturnPercent: nil, annualVolatilityPercent: nil)

    /// Equities annualize over trading days; a portfolio holding crypto is
    /// observed every calendar day.
    static func periodsPerYear(continuous: Bool) -> Double { continuous ? 365 : 252 }

    /// The trading day an observation belongs to. Equity observations after the
    /// 8pm extended-hours close, and any that fall on a closed day, belong to
    /// the next session rather than forming a separate "day" of their own.
    static func tradingDay(for time: Date, continuous: Bool) -> Date {
        let cal = PortfolioTradingCalendar.calendar
        var day = cal.startOfDay(for: time)
        guard !continuous else { return day }
        if cal.component(.hour, from: time) >= 20, let next = cal.date(byAdding: .day, value: 1, to: day) {
            day = next
        }
        var guardrail = 0
        while !PortfolioTradingCalendar.isTradingDay(day), guardrail < 10,
              let next = cal.date(byAdding: .day, value: 1, to: day) {
            day = next
            guardrail += 1
        }
        return day
    }

    /// Last observed value of each trading day, oldest first.
    static func dailyCloses(_ points: [(time: Date, value: Double)],
                            continuous: Bool) -> [(day: Date, value: Double)] {
        var closing: [Date: (time: Date, value: Double)] = [:]
        for point in points where point.value.isFinite && point.value > 0 {
            let day = tradingDay(for: point.time, continuous: continuous)
            if let existing = closing[day], existing.time >= point.time { continue }
            closing[day] = point
        }
        return closing.keys.sorted().map { (day: $0, value: closing[$0]!.value) }
    }

    static func compute(points: [(time: Date, value: Double)], continuous: Bool,
                        riskFreePercent: Double = defaultRiskFreePercent) -> PortfolioRiskMetrics {
        let closes = dailyCloses(points, continuous: continuous)
        guard closes.count >= 2 else {
            return PortfolioRiskMetrics(dailyReturns: 0, firstDay: closes.first?.day, lastDay: closes.last?.day,
                                        sharpe: nil, periodReturnPercent: nil, annualVolatilityPercent: nil)
        }
        let returns = zip(closes, closes.dropFirst()).map { $1.value / $0.value - 1 }
        let count = Double(returns.count)
        let period = (closes.last!.value / closes.first!.value - 1) * 100
        guard returns.count >= minimumReturns else {
            return PortfolioRiskMetrics(dailyReturns: returns.count, firstDay: closes.first?.day,
                                        lastDay: closes.last?.day, sharpe: nil,
                                        periodReturnPercent: period, annualVolatilityPercent: nil)
        }
        let periods = periodsPerYear(continuous: continuous)
        let riskFree = (riskFreePercent.isFinite ? riskFreePercent : 0) / 100 / periods
        let mean = returns.reduce(0, +) / count
        let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (count - 1)
        let deviation = variance.squareRoot()
        // A flat series has no risk to adjust for; a ratio would be infinite noise.
        let sharpe: Double? = deviation > 1e-12 && deviation.isFinite
            ? (mean - riskFree) / deviation * periods.squareRoot() : nil
        return PortfolioRiskMetrics(dailyReturns: returns.count, firstDay: closes.first?.day,
                                    lastDay: closes.last?.day,
                                    sharpe: sharpe.flatMap { $0.isFinite ? $0 : nil },
                                    periodReturnPercent: period,
                                    annualVolatilityPercent: deviation.isFinite ? deviation * periods.squareRoot() * 100 : nil)
    }

    // MARK: - Presentation

    var sharpeText: String { sharpe.map { String(format: "%.2f", $0) } ?? "—" }

    /// One line explaining what the figure rests on, or what is still missing.
    var coverageText: String {
        if sharpe != nil {
            return "\(dailyReturns) trading day\(dailyReturns == 1 ? "" : "s")" + (isPreliminary ? " · early" : "")
        }
        if dailyReturns >= Self.minimumReturns { return "No variation in recorded returns yet" }
        let needed = Self.minimumReturns - dailyReturns
        return "Needs \(needed) more trading day\(needed == 1 ? "" : "s") of history"
    }
}

/// One portfolio's line in the risk table.
struct PortfolioRiskRow: Equatable {
    let id: String
    let name: String
    let isActive: Bool
    let metrics: PortfolioRiskMetrics
}
