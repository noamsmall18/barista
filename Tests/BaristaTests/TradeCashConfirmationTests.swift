import XCTest
@testable import Barista

final class TradeCashConfirmationTests: XCTestCase {
    private func widget(cash: Double, quotePrice: Double = 100) -> StockTickerWidget {
        StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], cash: cash),
                          notificationsEnabled: false,
                          initialQuotes: [MarketQuote(symbol: "AAA", price: quotePrice, change: 0, kind: .stock, sparkline: [])])
    }

    func testAffordableBuyDeductsCashWithoutPrompt() {
        let widget = widget(cash: 1000)
        let result = TradeCashConfirmation.recordTrade(widget: widget, symbol: "AAA", kind: .stock,
                                                       side: .buy, quantity: 3, price: 100) { _ in
            XCTFail("An affordable buy must not prompt for an override")
            return false
        }
        XCTAssertEqual(result, .recorded)
        XCTAssertEqual(widget.config.cash, 700)
        XCTAssertEqual(widget.portfolioSnapshot()?.liveTotal, 1000)
    }

    func testCancelledOverrideLeavesEntireConfigurationUnchanged() {
        let widget = widget(cash: 50)
        let before = widget.config
        var prompts = 0
        let result = TradeCashConfirmation.recordTrade(widget: widget, symbol: "AAA", kind: .stock,
                                                       side: .buy, quantity: 1, price: 100) { message in
            prompts += 1
            XCTAssertTrue(message.contains("Current cash: $50.00"))
            XCTAssertTrue(message.contains("Cash after purchase: -$50.00"))
            return false
        }
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(widget.config, before)
    }

    func testConfirmedOverridePreservesNetValueAndPersistsCashOnce() throws {
        let widget = widget(cash: 50)
        let result = TradeCashConfirmation.recordTrade(widget: widget, symbol: "AAA", kind: .stock,
                                                       side: .buy, quantity: 1, price: 100) { _ in true }
        XCTAssertEqual(result, .recorded)
        XCTAssertEqual(widget.config.cash, -50)
        XCTAssertEqual(widget.config.holdings["AAA"], 1)
        XCTAssertEqual(widget.config.tradeHistory.count, 1)
        XCTAssertEqual(widget.config.tradeHistory.first?.cashDelta, -100)
        XCTAssertEqual(widget.portfolioSnapshot()?.liveTotal, 50)
        let restored = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(widget.config))
        XCTAssertEqual(restored.cash, -50)
        XCTAssertEqual(restored.holdings["AAA"], 1)
    }

    func testInvalidTradeCannotBeOverridden() {
        let widget = widget(cash: 50)
        let before = widget.config
        let result = TradeCashConfirmation.recordTrade(widget: widget, symbol: "AAA", kind: .stock,
                                                       side: .sell, quantity: 1, price: 100) { _ in
            XCTFail("Cash override must not bypass missing shares")
            return true
        }
        guard case .invalid = result else { return XCTFail("Sale must remain invalid") }
        XCTAssertEqual(widget.config, before)
    }

    func testOverrideOnlySpendsActivePortfolioCash() {
        let widget = widget(cash: 1000)
        widget.addPortfolio(named: "Second")
        widget.setCash(50)
        XCTAssertEqual(TradeCashConfirmation.recordTrade(widget: widget, symbol: "AAA", kind: .stock,
                                                        side: .buy, quantity: 1, price: 100) { _ in true }, .recorded)
        XCTAssertEqual(widget.config.cash, -50)
        XCTAssertEqual(widget.config.portfolios.first?.cash, 1000)
        XCTAssertEqual(widget.config.portfolios.first?.holdings, [:])
    }

    func testSnapshotIncludesDebtAtZeroAndNegativeNetValue() {
        let widget = widget(cash: 0)
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 1,
                                         price: 100, allowCashOverdraft: true))
        XCTAssertEqual(widget.portfolioSnapshot()?.liveTotal, 0)
        let lowerValue = self.widget(cash: 0, quotePrice: 80)
        XCTAssertTrue(lowerValue.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 1,
                                             price: 100, allowCashOverdraft: true))
        XCTAssertEqual(lowerValue.portfolioSnapshot()?.liveTotal, -20)
        XCTAssertEqual(lowerValue.portfolioSnapshot()?.cash, -100)
    }
}
