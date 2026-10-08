import XCTest
@testable import Barista

final class CashTradeTests: XCTestCase {
    private func widget(cash: Double = 1000) -> StockTickerWidget {
        StockTickerWidget(config: StockTickerConfig(symbols: ["AAA"], coins: [], cash: cash),
                          notificationsEnabled: false,
                          initialQuotes: [MarketQuote(symbol: "AAA", price: 100, change: 0, kind: .stock, sparkline: [])])
    }

    func testBuyMovesExistingCashIntoPositionWithoutInflatingPortfolioValue() {
        let widget = widget()
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 3, price: 100))
        XCTAssertEqual(widget.config.cash, 700)
        XCTAssertEqual(widget.config.holdings["AAA"], 3)
        XCTAssertEqual(widget.portfolioSnapshot()?.liveTotal, 1000)
    }

    func testInsufficientCashRejectsBuyWithoutChangingLedgerOrWatchlist() {
        let widget = widget(cash: 50)
        let before = widget.config
        XCTAssertFalse(widget.recordTrade(symbol: "NEW", kind: .stock, side: .buy, quantity: 1, price: 100))
        XCTAssertEqual(widget.config, before)
    }

    func testBuyCanUseAllCashAndSaleReturnsProceeds() {
        let widget = widget(cash: 300)
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 3, price: 100))
        XCTAssertEqual(widget.config.cash, 0)
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .sell, quantity: 2, price: 120))
        XCTAssertEqual(widget.config.cash, 240)
        XCTAssertEqual(widget.config.holdings["AAA"], 1)
        XCTAssertEqual(widget.config.realizedTotal, 40)
    }

    func testCashEffectsPersistOnceAndDeletingBuyRestoresCash() throws {
        let widget = widget()
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 0.5, price: 100))
        let saved = try JSONEncoder().encode(widget.config)
        let decoded = try JSONDecoder().decode(StockTickerConfig.self, from: saved)
        XCTAssertEqual(decoded.cash, 950)
        XCTAssertEqual(try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(decoded)).cash, 950)
        let trade = try XCTUnwrap(widget.config.tradeHistory.first)
        widget.deleteTrade(id: trade.id)
        XCTAssertEqual(widget.config.cash, 1000)
        XCTAssertNil(widget.config.holdings["AAA"])
    }

    func testZeroPriceAndOverflowCannotCreatePositionsOrCash() {
        let widget = widget()
        let before = widget.config
        XCTAssertFalse(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 1, price: 0))
        XCTAssertFalse(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: .greatestFiniteMagnitude, price: 2))
        XCTAssertEqual(widget.config, before)
    }

    func testLegacyTradesLoadWithoutRetroactivelyDebitingSavedCash() throws {
        let trade = Transaction(date: Date(), symbol: "AAA", kind: .buy, quantity: 3, price: 100)
        let portfolio = Portfolio(name: "Existing", cash: 25, transactions: [trade])
        let restored = try JSONDecoder().decode(Portfolio.self, from: JSONEncoder().encode(portfolio))
        XCTAssertEqual(restored.cash, 25)
        XCTAssertEqual(restored.holdings["AAA"], 3)
        XCTAssertNil(restored.transactions.first?.cashDelta)
    }

    func testDuplicateFundedTradeCannotSpendCashTwice() {
        var portfolio = Portfolio(name: "Cash", cash: 100)
        let trade = Transaction(date: Date(), symbol: "AAA", kind: .buy, quantity: 1, price: 20)
        XCTAssertTrue(portfolio.recordFundedTrade(trade))
        XCTAssertFalse(portfolio.recordFundedTrade(trade))
        XCTAssertEqual(portfolio.cash, 80)
        XCTAssertEqual(portfolio.holdings["AAA"], 1)
    }

    func testSaleCannotBeDeletedAfterItsProceedsAreSpent() throws {
        var portfolio = Portfolio(name: "Cash", holdings: ["AAA": 1], cash: 0)
        let sale = Transaction(date: Date(), symbol: "AAA", kind: .sell, quantity: 1, price: 100)
        XCTAssertTrue(portfolio.recordFundedTrade(sale))
        XCTAssertTrue(portfolio.recordFundedTrade(Transaction(date: Date(), symbol: "BBB", kind: .buy, quantity: 1, price: 100)))
        let before = portfolio
        XCTAssertFalse(portfolio.removeTransaction(id: sale.id))
        XCTAssertEqual(portfolio, before)
    }

    func testFractionalPurchaseCanUseExactAvailableCash() {
        let widget = widget(cash: 0.3)
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 3, price: 0.1))
        XCTAssertEqual(widget.config.cash, 0)
    }

    func testActivePortfolioOnlyPaysAndUnconvertedCurrencyTradeIsRejected() {
        let widget = widget()
        widget.addPortfolio(named: "Other")
        widget.setCash(400)
        XCTAssertTrue(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 1, price: 100))
        XCTAssertEqual(widget.config.cash, 300)
        XCTAssertEqual(widget.config.portfolios.first?.cash, 1000)
        widget.config.cryptoCurrency = "eur"
        let before = widget.config
        XCTAssertFalse(widget.recordTrade(symbol: "BTC", kind: .crypto, side: .buy, quantity: 1, price: 100))
        XCTAssertEqual(widget.config, before)
    }

    func testDeletingBuyCannotLeaveDependentSaleProceedsInCash() {
        var portfolio = Portfolio(name: "Cash", cash: 300)
        let buy = Transaction(date: Date(timeIntervalSince1970: 1000), symbol: "AAA", kind: .buy, quantity: 3, price: 100)
        XCTAssertTrue(portfolio.recordFundedTrade(buy))
        XCTAssertTrue(portfolio.recordFundedTrade(Transaction(date: Date(timeIntervalSince1970: 2000), symbol: "AAA", kind: .sell, quantity: 2, price: 120)))
        let before = portfolio
        XCTAssertFalse(portfolio.removeTransaction(id: buy.id))
        XCTAssertEqual(portfolio, before)
    }

    func testBackdatedSaleCannotCreditCashBeforeSharesWereOwned() {
        var portfolio = Portfolio(name: "Cash", cash: 300)
        XCTAssertTrue(portfolio.recordFundedTrade(Transaction(date: Date(timeIntervalSince1970: 2000), symbol: "AAA", kind: .buy, quantity: 3, price: 100)))
        let before = portfolio
        XCTAssertFalse(portfolio.recordFundedTrade(Transaction(date: Date(timeIntervalSince1970: 1000), symbol: "AAA", kind: .sell, quantity: 2, price: 120)))
        XCTAssertEqual(portfolio, before)
    }

    func testConfirmedOverdraftDebitsFullCostAndPersistsSignedCash() throws {
        var portfolio = Portfolio(name: "Cash", cash: 100)
        let purchase = Transaction(date: Date(), symbol: "AAA", kind: .buy, quantity: 2, price: 100)

        XCTAssertFalse(portfolio.recordFundedTrade(purchase), "overdraft must be an explicit choice")
        XCTAssertEqual(portfolio.cash, 100)
        XCTAssertTrue(portfolio.transactions.isEmpty)

        XCTAssertTrue(portfolio.recordFundedTrade(purchase, allowCashOverdraft: true))
        XCTAssertEqual(portfolio.cash, -100)
        XCTAssertEqual(portfolio.transactions.last?.cashDelta, -200)
        XCTAssertTrue(portfolio.recordFundedTrade(Transaction(date: Date().addingTimeInterval(1), symbol: "AAA", kind: .buy, quantity: 1, price: 50), allowCashOverdraft: true))
        XCTAssertEqual(portfolio.cash, -150, "an opted-in purchase from negative cash still deducts its full cost")

        let restored = try JSONDecoder().decode(Portfolio.self, from: JSONEncoder().encode(portfolio))
        XCTAssertEqual(restored.cash, -150)
        XCTAssertEqual(restored.holdings["AAA"], 3)
        XCTAssertEqual(restored.transactions.compactMap(\.cashDelta), [-200, -50])
    }

    func testNegativeCashRequiresOverrideForBuysButSalesCreditCash() {
        var portfolio = Portfolio(name: "Cash", holdings: ["AAA": 2], cash: -80)
        let before = portfolio
        XCTAssertFalse(portfolio.recordFundedTrade(Transaction(date: Date(), symbol: "AAA", kind: .buy, quantity: 1, price: 20)))
        XCTAssertEqual(portfolio, before)

        XCTAssertTrue(portfolio.recordFundedTrade(Transaction(date: Date(), symbol: "AAA", kind: .sell, quantity: 1, price: 50)))
        XCTAssertEqual(portfolio.cash, -30)
        XCTAssertEqual(portfolio.holdings["AAA"], 1)
    }

    func testUndoOverdraftBuyRelievesDebtAndUndoSaleCannotDeepenDebt() {
        var overdraft = Portfolio(name: "Cash", cash: 100)
        let buy = Transaction(date: Date(), symbol: "AAA", kind: .buy, quantity: 2, price: 100)
        XCTAssertTrue(overdraft.recordFundedTrade(buy, allowCashOverdraft: true))
        XCTAssertEqual(overdraft.cash, -100)
        XCTAssertTrue(overdraft.removeTransaction(id: buy.id))
        XCTAssertEqual(overdraft.cash, 100)

        var spentSale = Portfolio(name: "Cash", holdings: ["AAA": 1], cash: 0)
        let sale = Transaction(date: Date(), symbol: "AAA", kind: .sell, quantity: 1, price: 100)
        XCTAssertTrue(spentSale.recordFundedTrade(sale))
        XCTAssertTrue(spentSale.recordFundedTrade(Transaction(date: Date().addingTimeInterval(1), symbol: "BBB", kind: .buy, quantity: 2, price: 100), allowCashOverdraft: true))
        let beforeRemoval = spentSale
        XCTAssertFalse(spentSale.removeTransaction(id: sale.id), "removing proceeds cannot make an existing overdraft deeper")
        XCTAssertEqual(spentSale, beforeRemoval)
    }

    func testDuplicateTransactionIdentifiersCannotReverseAmbiguousCash() {
        let id = UUID().uuidString
        var first = Transaction(id: id, date: Date(), symbol: "AAA", kind: .buy, quantity: 1, price: 20)
        first.cashDelta = -20
        var second = Transaction(id: id, date: Date().addingTimeInterval(1), symbol: "BBB", kind: .buy, quantity: 1, price: 30)
        second.cashDelta = -30
        var portfolio = Portfolio(name: "Cash", cash: 50, transactions: [first, second])
        let before = portfolio
        XCTAssertFalse(portfolio.removeTransaction(id: id))
        XCTAssertEqual(portfolio, before)
    }
}
