import XCTest
@testable import Barista

final class MarketbarWatchlistModelTests: XCTestCase {
    private func row(_ symbol: String, _ change: Double, _ value: Double?) -> MarketbarWatchlistModel.Row {
        MarketbarWatchlistModel.Row(symbol: symbol, kind: .stock, price: 100,
                                    changePercent: change, positionValue: value,
                                    positionCurrency: "USD",
                                    totalReturnPercent: nil)
    }

    func testSearchFiltersBySymbolAndAssetTypeAndSortsStableRows() {
        let rows = [row("MSFT", -0.5, 600), row("AAPL", 2.0, 800),
                    .init(symbol: "BTC", kind: .crypto, price: 50_000,
                          changePercent: 4.0, positionValue: nil,
                          positionCurrency: "USD", totalReturnPercent: nil)]
        var model = MarketbarWatchlistModel()
        XCTAssertEqual(model.visibleRows(from: rows).map(\.symbol), ["AAPL", "BTC", "MSFT"])

        model.query = "crypto"
        XCTAssertEqual(model.visibleRows(from: rows).map(\.symbol), ["BTC"])
        model.query = " aaP "
        XCTAssertEqual(model.visibleRows(from: rows).map(\.symbol), ["AAPL"])
        model.query = "missing"
        XCTAssertTrue(model.visibleRows(from: rows).isEmpty)
    }

    func testSortModesOrderLargestMovesAndPositionValuesFirst() {
        let rows = [row("MSFT", -0.5, 600), row("AAPL", 2.0, 800), row("NVDA", 2.0, 1_200),
                    row("TSLA", 0.1, nil)]
        var model = MarketbarWatchlistModel()
        model.sort = .change
        XCTAssertEqual(model.visibleRows(from: rows).map(\.symbol), ["AAPL", "NVDA", "MSFT", "TSLA"])
        model.sort = .positionValue
        XCTAssertEqual(model.visibleRows(from: rows).map(\.symbol), ["NVDA", "AAPL", "MSFT", "TSLA"])
    }

    func testLargestMoveUsesMagnitudeAndPlacesUnavailableQuotesLast() {
        let rows = [row("GAIN", 1.5, nil), row("LOSS", -4.0, nil),
                    .init(symbol: "WAIT", kind: .stock, price: nil,
                          changePercent: nil, positionValue: nil,
                          positionCurrency: "USD", totalReturnPercent: nil)]
        var model = MarketbarWatchlistModel()
        model.sort = .change
        XCTAssertEqual(model.visibleRows(from: rows).map(\.symbol), ["LOSS", "GAIN", "WAIT"])
    }
}
