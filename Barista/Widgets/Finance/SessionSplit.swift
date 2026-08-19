import Foundation

// MARK: - Trading session segmentation

/// Splits a day's intraday bars into the three sessions the exchange actually
/// runs, so the regular session and extended hours can be measured and drawn as
/// separate things rather than one continuous line.
///
/// Yahoo returns pre-market, regular and post-market bars concatenated with no
/// marker between them. Without this split a chart plots a pre-market move as a
/// continuation of the previous session, and a portfolio total silently folds an
/// after-hours move into the day's result.
enum TradingSession: String {
    case pre, regular, post
}

/// One day's bars, separated by session. Each series keeps its timestamps so
/// callers can line up several symbols by clock time.
struct SessionSeries: Equatable {
    var closes: [Double] = []
    var times: [Double] = []

    var isEmpty: Bool { closes.isEmpty }
    var last: Double? { closes.last }
    var first: Double? { closes.first }
    var count: Int { closes.count }
}

struct SessionSplit: Equatable {
    var pre = SessionSeries()
    var regular = SessionSeries()
    var post = SessionSeries()

    /// Bars belonging to the session the exchange is in, or the one it last
    /// completed, plus whatever has traded since.
    ///
    /// Pre-market is deliberately *not* joined to the previous day's regular
    /// session: a pre-market move is measured from the previous close, and
    /// showing it as a continuation of yesterday's line is exactly the bug this
    /// type exists to prevent.
    func series(for status: MarketStatus) -> (session: SessionSeries, extended: SessionSeries) {
        switch status {
        case .preMarket:
            // No regular session has happened yet today. Everything on screen is
            // the pre-market move, measured against the previous close.
            return (SessionSeries(), pre)
        case .open:
            return (regular, SessionSeries())
        case .afterHours:
            return (regular, post)
        case .closed:
            // After the post-market window, or a weekend. The last thing that
            // happened is the regular session; anything after it is history but
            // still worth showing as a tail.
            return (regular, post)
        }
    }
}

enum SessionSplitter {
    /// Boundaries as Unix seconds. A zero means the feed did not supply that
    /// edge, in which case bars are not assigned to that session rather than
    /// being guessed at.
    struct Boundaries: Equatable, Codable {
        var regularStart: Double = 0
        var regularEnd: Double = 0

        var isUsable: Bool { regularStart > 0 && regularEnd > regularStart }
    }

    /// Assigns each bar to a session by its timestamp.
    ///
    /// Bars without a matching timestamp cannot be placed, so when the two arrays
    /// disagree in length everything falls back to the regular session: an
    /// unsplit chart is wrong in a small way, but inventing a boundary would be
    /// wrong in a way that shows a fabricated move.
    static func split(closes: [Double],
                      times: [Double],
                      boundaries: Boundaries) -> SessionSplit {
        var out = SessionSplit()
        guard !closes.isEmpty else { return out }

        guard times.count == closes.count, boundaries.isUsable else {
            out.regular = SessionSeries(closes: closes, times: times.count == closes.count ? times : [])
            return out
        }

        for (i, close) in closes.enumerated() {
            guard close.isFinite, close > 0 else { continue }
            let t = times[i]
            if t < boundaries.regularStart {
                out.pre.closes.append(close); out.pre.times.append(t)
            } else if t < boundaries.regularEnd {
                out.regular.closes.append(close); out.regular.times.append(t)
            } else {
                out.post.closes.append(close); out.post.times.append(t)
            }
        }
        return out
    }
}
