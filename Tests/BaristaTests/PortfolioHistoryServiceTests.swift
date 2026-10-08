import XCTest
@testable import Barista

/// The menu-bar app and the research-workspace service each hold their own
/// PortfolioHistoryService over the same preferences. These tests stand two
/// instances over one in-memory store to play both processes.
final class PortfolioHistoryServiceTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(InMemoryTestPreferences(suiteName: "barista.tests.history.\(UUID().uuidString)"))
    }

    /// Whole seconds, two hours ago: inside the full-detail tier, so compaction
    /// keeps every sample, and exact through a JSON round trip.
    private let base = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate - 2 * 3600).rounded(.down))

    private func minutes(_ m: Double) -> Date { base.addingTimeInterval(m * 60) }

    private func values(_ service: PortfolioHistoryService, _ id: String) -> [Double] {
        service.points(for: id, range: .all).map(\.value)
    }

    func testTwoProcessesRecordingKeepEachOthersPoints() throws {
        let defaults = try isolatedDefaults()
        let app = PortfolioHistoryService(defaults: defaults)
        let research = PortfolioHistoryService(defaults: defaults)

        // Interleaved, further apart than the ten-minute spacing, and both
        // services loaded before either wrote anything.
        app.record(portfolioID: "main", value: 100, at: minutes(0))
        app.flushPendingWrites()
        research.record(portfolioID: "main", value: 200, at: minutes(15))
        research.flushPendingWrites()
        app.record(portfolioID: "main", value: 300, at: minutes(30))
        app.flushPendingWrites()
        research.record(portfolioID: "main", value: 400, at: minutes(45))
        research.flushPendingWrites()

        // Separate portfolios written only by one side each.
        app.record(portfolioID: "app-only", value: 1, at: minutes(50))
        app.flushPendingWrites()
        research.record(portfolioID: "research-only", value: 2, at: minutes(55))
        research.flushPendingWrites()

        let reopened = PortfolioHistoryService(defaults: defaults)
        XCTAssertEqual(values(reopened, "main"), [100, 200, 300, 400])
        XCTAssertEqual(reopened.points(for: "main", range: .all).map(\.time),
                       [minutes(0), minutes(15), minutes(30), minutes(45)])
        XCTAssertEqual(values(reopened, "app-only"), [1])
        XCTAssertEqual(values(reopened, "research-only"), [2])

        // Each writer's own view picks up the other's points when it writes.
        XCTAssertEqual(values(research, "main"), [100, 200, 300, 400])
        XCTAssertEqual(values(research, "app-only"), [1])
    }

    func testSampleInsideSpacingKeepsTheNewerOfTheTwoProcesses() throws {
        let defaults = try isolatedDefaults()
        let app = PortfolioHistoryService(defaults: defaults)
        let research = PortfolioHistoryService(defaults: defaults)

        app.record(portfolioID: "main", value: 100, at: minutes(0))
        app.flushPendingWrites()
        research.record(portfolioID: "main", value: 110, at: minutes(4))
        research.flushPendingWrites()
        // Taken before the research sample but written after it.
        app.record(portfolioID: "main", value: 105, at: minutes(2))
        app.flushPendingWrites()

        XCTAssertEqual(values(PortfolioHistoryService(defaults: defaults), "main"), [110])
    }

    func testForgetSticksWhenTheOtherProcessStillRecordsThePortfolio() throws {
        let defaults = try isolatedDefaults()
        let app = PortfolioHistoryService(defaults: defaults)
        let research = PortfolioHistoryService(defaults: defaults)

        app.record(portfolioID: "deleted", value: 100, at: minutes(0))
        app.flushPendingWrites()
        research.record(portfolioID: "deleted", value: 200, at: minutes(15))
        research.record(portfolioID: "kept", value: 50, at: minutes(15))
        research.flushPendingWrites()

        app.forget(portfolioID: "deleted")
        app.flushPendingWrites()
        XCTAssertEqual(app.sampleCount(for: "deleted"), 0)

        // The research service hasn't seen the deletion in its config yet.
        research.record(portfolioID: "deleted", value: 300, at: minutes(30))
        research.record(portfolioID: "kept", value: 60, at: minutes(30))
        research.flushPendingWrites()

        XCTAssertEqual(research.sampleCount(for: "deleted"), 0)
        let reopened = PortfolioHistoryService(defaults: defaults)
        XCTAssertEqual(reopened.sampleCount(for: "deleted"), 0)
        XCTAssertEqual(values(reopened, "kept"), [50, 60])
    }

    func testExistingHistoryStillDecodesAndKeepsItsDayKey() throws {
        let defaults = try isolatedDefaults()
        let old = minutes(-30).timeIntervalSinceReferenceDate
        defaults.set(Data(#"{"main":[{"day":\#(old),"value":42}]}"#.utf8), forKey: "barista.portfolioHistory")

        let service = PortfolioHistoryService(defaults: defaults)
        XCTAssertEqual(values(service, "main"), [42])
        service.record(portfolioID: "main", value: 43, at: minutes(0))
        service.flushPendingWrites()

        let stored = try XCTUnwrap(defaults.data(forKey: "barista.portfolioHistory"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: [[String: Any]]])
        XCTAssertEqual(raw["main"]?.compactMap { $0["value"] as? Double }, [42, 43])
        XCTAssertEqual(raw["main"]?.first?["day"] as? Double, old)
    }

    func testUnreadableHistoryIsNeverOverwritten() throws {
        let defaults = try isolatedDefaults()
        let unreadable = Data("not history".utf8)
        defaults.set(unreadable, forKey: "barista.portfolioHistory")

        let service = PortfolioHistoryService(defaults: defaults)
        service.record(portfolioID: "main", value: 100, at: minutes(0))
        service.forget(portfolioID: "other")
        service.flushPendingWrites()

        XCTAssertEqual(defaults.data(forKey: "barista.portfolioHistory"), unreadable)
    }
}
