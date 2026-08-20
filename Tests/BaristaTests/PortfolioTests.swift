import XCTest
@testable import Barista

/// Portfolio keeps holdings and cost basis as a cache of the ledger. These check
/// that the cache is always what replaying the ledger produces, including across
/// encode/decode and the migration of portfolios saved before it existed.
final class PortfolioTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ o: TimeInterval) -> Date { day.addingTimeInterval(o) }

    private func realPortfolio() -> Portfolio {
        Portfolio(name: "Main",
                  holdings: ["DUOL": 6.3, "NOW": 3.25, "RBRK": 5, "HIMS": 15, "PGY": 10],
                  costBasis: ["DUOL": 105.57, "RBRK": 51.78, "NOW": 111.11,
                              "HIMS": 23.61, "PGY": 12.85],
                  cash: 13.2)
    }

    // MARK: Migration

    func testMigrationPreservesEveryNumber() {
        let p = realPortfolio()
        XCTAssertEqual(p.holdings, ["DUOL": 6.3, "NOW": 3.25, "RBRK": 5, "HIMS": 15, "PGY": 10])
        XCTAssertEqual(p.costBasis["HIMS"], 23.61)
        XCTAssertEqual(p.cash, 13.2)
        XCTAssertEqual(p.realizedTotal, 0)
    }

    func testMigrationSeedsOneOpeningEntryPerHolding() {
        let p = realPortfolio()
        XCTAssertEqual(p.transactions.count, 5)
        XCTAssertTrue(p.transactions.allSatisfy(\.isOpeningPosition))
        XCTAssertTrue(p.tradeHistory.isEmpty, "opening entries are history, not decisions")
    }

    func testLegacyPortfolioMigratesOnDecodeAndIsFlaggedForOneSave() throws {
        let legacy = #"{"id":"x","name":"Old","holdings":{"ZZZ":4},"costBasis":{"ZZZ":10},"cash":5}"#
        let p = try JSONDecoder().decode(Portfolio.self, from: Data(legacy.utf8))
        XCTAssertEqual(p.transactions.count, 1)
        XCTAssertEqual(p.holdings["ZZZ"], 4)
        XCTAssertEqual(p.costBasis["ZZZ"], 10)
        XCTAssertTrue(p.didSeedLedger, "the migrated form must be written back once")
    }

    func testEmptyPortfolioSeedsNothing() throws {
        let empty = #"{"id":"y","name":"E","holdings":{},"costBasis":{},"cash":0}"#
        let p = try JSONDecoder().decode(Portfolio.self, from: Data(empty.utf8))
        XCTAssertTrue(p.transactions.isEmpty)
        XCTAssertFalse(p.didSeedLedger)
    }

    // MARK: Trading

    func testBuyThenSellUpdatesEverythingConsistently() {
        var p = realPortfolio()
        p.record(Transaction(date: at(0), symbol: "HIMS", kind: .buy, quantity: 5, price: 30))
        let blended = (23.61 * 15 + 30 * 5) / 20
        XCTAssertEqual(p.holdings["HIMS"], 20)
        XCTAssertEqual(p.costBasis["HIMS"]!, blended, accuracy: 1e-9)

        p.record(Transaction(date: at(1), symbol: "HIMS", kind: .sell, quantity: 10, price: 40))
        XCTAssertEqual(p.holdings["HIMS"], 10)
        XCTAssertEqual(p.costBasis["HIMS"]!, blended, accuracy: 1e-9)
        XCTAssertEqual(p.realizedTotal, (40 - blended) * 10, accuracy: 1e-9)
        XCTAssertEqual(p.tradeHistory.count, 2)
        XCTAssertEqual(p.tradeHistory.first?.kind, .sell, "history reads newest first")
    }

    func testDeletingATradeUnwindsIt() {
        var p = Portfolio(name: "T", holdings: ["AAA": 10], costBasis: ["AAA": 10], cash: 0)
        let sale = Transaction(date: at(0), symbol: "AAA", kind: .sell, quantity: 4, price: 20)
        p.record(sale)
        XCTAssertEqual(p.holdings["AAA"], 6)
        XCTAssertEqual(p.realizedTotal, 40, accuracy: 1e-9)

        p.removeTransaction(id: sale.id)
        XCTAssertEqual(p.holdings["AAA"], 10)
        XCTAssertEqual(p.realizedTotal, 0)
    }

    // MARK: Manual correction

    func testManualCorrectionIsRecordedAndAlwaysLandsLast() {
        var p = realPortfolio()
        // A trade dated in the future must not replay on top of a correction made
        // now, or the correction would silently appear to do nothing.
        p.record(Transaction(date: Date().addingTimeInterval(3600), symbol: "HIMS",
                             kind: .sell, quantity: 1, price: 40))
        p.setQuantity(3, for: "HIMS", averageCost: 25, note: "Manual adjustment")
        XCTAssertEqual(p.holdings["HIMS"], 3)
        XCTAssertEqual(p.costBasis["HIMS"], 25)
        XCTAssertTrue(p.transactions.contains { $0.kind == .adjustment && $0.note == "Manual adjustment" },
                      "a correction must be auditable in the ledger")
    }

    func testRemovingAPositionLeavesOthersAlone() {
        var p = realPortfolio()
        p.setQuantity(0, for: "PGY", note: "Removed from portfolio")
        XCTAssertNil(p.holdings["PGY"])
        XCTAssertNil(p.costBasis["PGY"])
        XCTAssertEqual(p.holdings["DUOL"], 6.3)
    }

    // MARK: Persistence

    func testSurvivesEncodeAndDecode() throws {
        var p = realPortfolio()
        p.record(Transaction(date: at(0), symbol: "HIMS", kind: .sell, quantity: 5, price: 40))
        let decoded = try JSONDecoder().decode(Portfolio.self,
                                               from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.holdings, p.holdings)
        XCTAssertEqual(decoded.transactions.count, p.transactions.count)
        XCTAssertEqual(decoded.realizedTotal, p.realizedTotal, accuracy: 1e-9)
        XCTAssertFalse(decoded.didSeedLedger, "an existing ledger must not be re-seeded")
    }
}
