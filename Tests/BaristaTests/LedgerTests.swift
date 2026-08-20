import XCTest
@testable import Barista

/// The ledger is what share counts, average cost and realised profit are all
/// derived from, so these cover the replay rules rather than any one screen.
final class LedgerTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { day.addingTimeInterval(offset) }

    // MARK: Migration from pre-ledger holdings

    func testOpeningEntriesReproduceExistingHoldings() {
        let holdings = ["DUOL": 6.3, "NOW": 3.25, "RBRK": 5, "HIMS": 15, "PGY": 10]
        let costs = ["DUOL": 105.57, "RBRK": 51.78, "NOW": 111.11, "HIMS": 23.61, "PGY": 12.85]
        let state = Ledger.derive(from: Ledger.openingEntries(holdings: holdings, costBasis: costs))
        XCTAssertEqual(state.holdings, holdings)
        XCTAssertEqual(state.costBasis, costs)
        XCTAssertEqual(state.realizedTotal, 0, "migration must not invent realised profit")
    }

    func testOpeningEntriesDoNotInventACostBasis() {
        let state = Ledger.derive(from: Ledger.openingEntries(
            holdings: ["DUOL": 1.3, "SOFI": 10], costBasis: [:]))
        XCTAssertEqual(state.holdings, ["DUOL": 1.3, "SOFI": 10])
        XCTAssertTrue(state.costBasis.isEmpty,
                      "a zero average would render as a fabricated 100% gain")
    }

    // MARK: Buying

    func testTwoBuysBlendToAWeightedAverage() {
        let state = Ledger.derive(from: [
            Transaction(date: at(0), symbol: "AAA", kind: .buy, quantity: 10, price: 100),
            Transaction(date: at(1), symbol: "AAA", kind: .buy, quantity: 10, price: 200),
        ])
        XCTAssertEqual(state.holdings["AAA"], 20)
        XCTAssertEqual(state.costBasis["AAA"], 150)
    }

    // MARK: Selling

    func testSellBanksProfitAndLeavesTheAverageAlone() {
        let state = Ledger.derive(from: [
            Transaction(date: at(0), symbol: "AAA", kind: .buy, quantity: 20, price: 150),
            Transaction(date: at(1), symbol: "AAA", kind: .sell, quantity: 5, price: 250),
        ])
        XCTAssertEqual(state.holdings["AAA"], 15)
        XCTAssertEqual(state.costBasis["AAA"], 150, "weighted average survives a sale")
        XCTAssertEqual(state.realized["AAA"], 500)
    }

    func testSellingOutClearsTheHoldingAndItsCostBasis() {
        let state = Ledger.derive(from: [
            Transaction(date: at(0), symbol: "AAA", kind: .buy, quantity: 15, price: 150),
            Transaction(date: at(1), symbol: "AAA", kind: .sell, quantity: 15, price: 100),
        ])
        XCTAssertNil(state.holdings["AAA"])
        XCTAssertNil(state.costBasis["AAA"], "a sold-out position must not keep a stale average")
        XCTAssertEqual(state.realized["AAA"]!, -750, accuracy: 1e-9)
    }

    func testCannotSellMoreThanIsHeld() {
        let state = Ledger.derive(from: [
            Transaction(date: at(0), symbol: "BBB", kind: .buy, quantity: 5, price: 10),
            Transaction(date: at(1), symbol: "BBB", kind: .sell, quantity: 999, price: 20),
        ])
        XCTAssertNil(state.holdings["BBB"], "shares must never go negative")
        XCTAssertEqual(state.realized["BBB"], 50, "only the 5 actually held are banked")
    }

    // MARK: Adjustments

    func testAdjustmentSetsAnAbsoluteQuantityAndLaterTradesApplyOnTop() {
        let state = Ledger.derive(from: [
            Transaction(date: Transaction.openingDate, symbol: "CCC", kind: .adjustment,
                        quantity: 15, price: 23.61),
            Transaction(date: at(0), symbol: "CCC", kind: .buy, quantity: 5, price: 30),
        ])
        XCTAssertEqual(state.holdings["CCC"], 20)
        XCTAssertEqual(state.costBasis["CCC"]!, (23.61 * 15 + 30 * 5) / 20, accuracy: 1e-9)
    }

    func testAdjustmentWithoutAPriceKeepsTheExistingAverage() {
        let state = Ledger.derive(from: [
            Transaction(date: at(0), symbol: "DDD", kind: .buy, quantity: 10, price: 50),
            Transaction(date: at(1), symbol: "DDD", kind: .adjustment, quantity: 4, price: 0),
        ])
        XCTAssertEqual(state.holdings["DDD"], 4)
        XCTAssertEqual(state.costBasis["DDD"], 50)
    }

    // MARK: Ordering and degenerate input

    func testEntriesReplayByDateNotByInsertionOrder() {
        let state = Ledger.derive(from: [
            Transaction(date: at(100), symbol: "EEE", kind: .sell, quantity: 5, price: 20),
            Transaction(date: at(0), symbol: "EEE", kind: .buy, quantity: 10, price: 10),
        ])
        XCTAssertEqual(state.holdings["EEE"], 5)
        XCTAssertEqual(state.realized["EEE"], 50)
    }

    func testEmptyLedgerYieldsNothing() {
        let state = Ledger.derive(from: [])
        XCTAssertTrue(state.holdings.isEmpty)
        XCTAssertTrue(state.costBasis.isEmpty)
        XCTAssertEqual(state.realizedTotal, 0)
    }

    func testSymbolsAreCaseInsensitive() {
        let state = Ledger.derive(from: [
            Transaction(date: at(0), symbol: "hims", kind: .buy, quantity: 5, price: 10),
            Transaction(date: at(1), symbol: "HIMS", kind: .buy, quantity: 5, price: 20),
        ])
        XCTAssertEqual(state.holdings["HIMS"], 10)
        XCTAssertEqual(state.costBasis["HIMS"], 15)
    }
}
