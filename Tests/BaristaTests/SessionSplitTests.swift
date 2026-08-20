import XCTest
@testable import Barista

/// Exercised against a real Yahoo chart response saved from a live trading day,
/// because the bug this code fixes only shows up on data that actually contains
/// all three sessions concatenated together.
final class SessionSplitTests: XCTestCase {

    private struct Fixture {
        let closes: [Double]
        let times: [Double]
        let boundaries: SessionSplitter.Boundaries
    }

    /// HIMS, 19 August 2026: 226 pre-market, 390 regular, 13 post-market bars.
    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/hims-1d-prepost",
                                                  withExtension: "json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url))
                                 as? [String: Any])
        let chart = try XCTUnwrap(json["chart"] as? [String: Any])
        let result = try XCTUnwrap((chart["result"] as? [[String: Any]])?.first)
        let meta = try XCTUnwrap(result["meta"] as? [String: Any])
        let ctp = try XCTUnwrap(meta["currentTradingPeriod"] as? [String: Any])
        let regular = try XCTUnwrap(ctp["regular"] as? [String: Any])
        let stamps = try XCTUnwrap(result["timestamp"] as? [Any]).map {
            ($0 as? NSNumber)?.doubleValue ?? 0
        }
        let quote = try XCTUnwrap((try XCTUnwrap(result["indicators"] as? [String: Any])["quote"]
                                   as? [[String: Any]])?.first)
        let raw = try XCTUnwrap(quote["close"] as? [Any]).map {
            ($0 as? NSNumber)?.doubleValue ?? .nan
        }

        var closes: [Double] = [], times: [Double] = []
        for (i, c) in raw.enumerated() where c.isFinite && c > 0 {
            closes.append(c); times.append(stamps[i])
        }
        return Fixture(closes: closes, times: times, boundaries: .init(
            regularStart: try XCTUnwrap(regular["start"] as? NSNumber).doubleValue,
            regularEnd: try XCTUnwrap(regular["end"] as? NSNumber).doubleValue))
    }

    func testSplitsARealTradingDayIntoItsThreeSessions() throws {
        let f = try loadFixture()
        let split = SessionSplitter.split(closes: f.closes, times: f.times,
                                          boundaries: f.boundaries)
        XCTAssertEqual(split.pre.count, 226)
        XCTAssertEqual(split.regular.count, 390)
        XCTAssertEqual(split.post.count, 13)
        XCTAssertEqual(split.pre.count + split.regular.count + split.post.count,
                       f.closes.count, "no bar may be dropped by the split")
    }

    func testEveryBarLandsInTheRightWindow() throws {
        let f = try loadFixture()
        let split = SessionSplitter.split(closes: f.closes, times: f.times,
                                          boundaries: f.boundaries)
        XCTAssertTrue(split.pre.times.allSatisfy { $0 < f.boundaries.regularStart })
        XCTAssertTrue(split.regular.times.allSatisfy {
            $0 >= f.boundaries.regularStart && $0 < f.boundaries.regularEnd })
        XCTAssertTrue(split.post.times.allSatisfy { $0 >= f.boundaries.regularEnd })
        XCTAssertEqual(split.regular.times.count, split.regular.closes.count,
                       "times must stay aligned with closes")
    }

    /// The original bug: a pre-market chart drew the previous session with that
    /// morning's bars appended, so the pre-market move was invisible.
    func testPreMarketShowsOnlyThatMorningsBars() throws {
        let f = try loadFixture()
        let split = SessionSplitter.split(closes: f.closes, times: f.times,
                                          boundaries: f.boundaries)
        let shown = split.series(for: .preMarket)
        XCTAssertTrue(shown.session.isEmpty,
                      "no regular session may be drawn before the open")
        XCTAssertEqual(shown.extended.count, 226)
    }

    func testAfterHoursKeepsTheSessionAndTheTailApart() throws {
        let f = try loadFixture()
        let split = SessionSplitter.split(closes: f.closes, times: f.times,
                                          boundaries: f.boundaries)
        let shown = split.series(for: .afterHours)
        XCTAssertEqual(shown.session.count, 390)
        XCTAssertEqual(shown.extended.count, 13)
    }

    func testWhileOpenOnlyTheRegularSessionIsShown() throws {
        let f = try loadFixture()
        let split = SessionSplitter.split(closes: f.closes, times: f.times,
                                          boundaries: f.boundaries)
        let shown = split.series(for: .open)
        XCTAssertEqual(shown.session.count, 390)
        XCTAssertTrue(shown.extended.isEmpty)
    }

    // MARK: Degenerate input must never fabricate a boundary

    func testMismatchedTimestampsFallBackToOneSession() {
        let split = SessionSplitter.split(closes: [1, 2, 3], times: [],
                                          boundaries: .init(regularStart: 10, regularEnd: 20))
        XCTAssertEqual(split.regular.count, 3)
        XCTAssertTrue(split.pre.isEmpty && split.post.isEmpty)
    }

    func testMissingBoundariesFallBackToOneSession() {
        let split = SessionSplitter.split(closes: [1, 2, 3], times: [10, 20, 30],
                                          boundaries: .init())
        XCTAssertEqual(split.regular.count, 3)
    }

    func testEmptyInputYieldsAnEmptySplit() {
        let split = SessionSplitter.split(closes: [], times: [], boundaries: .init())
        XCTAssertTrue(split.pre.isEmpty && split.regular.isEmpty && split.post.isEmpty)
    }

    func testNonFiniteAndNonPositiveBarsAreDropped() {
        let split = SessionSplitter.split(closes: [1, .nan, 0, -5, 2],
                                          times: [1, 2, 3, 4, 5],
                                          boundaries: .init(regularStart: 0.5, regularEnd: 99))
        XCTAssertEqual(split.regular.count, 2)
    }
}
