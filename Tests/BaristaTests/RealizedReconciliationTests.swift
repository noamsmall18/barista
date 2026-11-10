import Testing
import Cocoa
@testable import Barista

struct RealizedReconciliationTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var checkpointDate: Date { date("2026-06-01T15:00:00Z") }
    private func portfolio() -> Portfolio {
        var p = Portfolio(name: "Disposable reconciliation", holdings: ["AAA": 30], costBasis: ["AAA": 10], cash: 80)
        p.record(Transaction(date: date("2025-12-31T20:00:00Z"), symbol: "AAA", kind: .sell, quantity: 2, price: 20))
        p.record(Transaction(date: date("2026-01-01T05:00:00Z"), symbol: "AAA", kind: .sell, quantity: 3, price: 15))
        return p
    }

    @Test func yearBoundariesUseEasternTimeAndExcludeFutureSales() {
        var p = portfolio()
        p.record(Transaction(date: date("2026-12-01T15:00:00Z"), symbol: "AAA", kind: .sell, quantity: 1, price: 30))
        #expect(p.realizedYearToDate(asOf: checkpointDate) == 15)
        #expect(p.realizedYearToDate(asOf: date("2026-01-01T04:59:59Z")) == 20)
        #expect(p.realizedYearToDate(asOf: date("2026-12-02T15:00:00Z")) == 35)
    }

    @Test func reconciliationPreservesCashPositionsAndTradesAndAddsSubsequentSales() {
        var p = portfolio()
        let before = p
        let accepted = p.reconcileRealizedYearToDate(-197, asOf: checkpointDate)
        #expect(accepted)
        #expect(p.realizedYearToDate(asOf: checkpointDate) == -197)
        #expect(p.holdings == before.holdings)
        #expect(p.costBasis == before.costBasis)
        #expect(p.cash == before.cash)
        #expect(p.transactions == before.transactions)
        #expect(p.realizedTotal == before.realizedTotal)
        p.record(Transaction(date: checkpointDate.addingTimeInterval(1), symbol: "AAA", kind: .sell, quantity: 2, price: 13))
        #expect(p.realizedYearToDate(asOf: checkpointDate.addingTimeInterval(2)) == -191)
        #expect(p.realizedYearToDate(asOf: checkpointDate.addingTimeInterval(-1)) == 15)
    }

    @Test func nextYearStartsFreshAndRepeatedReconciliationReplacesTheCheckpoint() {
        var p = portfolio()
        p.reconcileRealizedYearToDate(-197, asOf: checkpointDate)
        p.reconcileRealizedYearToDate(-200, asOf: checkpointDate.addingTimeInterval(1))
        #expect(p.realizedYearToDate(asOf: checkpointDate.addingTimeInterval(2)) == -200)
        p.record(Transaction(date: date("2027-01-02T15:00:00Z"), symbol: "AAA", kind: .sell, quantity: 1, price: 18))
        #expect(p.realizedYearToDate(asOf: date("2027-01-03T15:00:00Z")) == 8)
    }

    @Test func checkpointSurvivesSavingAndRejectsInvalidAmounts() throws {
        var p = portfolio()
        p.reconcileRealizedYearToDate(-197, asOf: checkpointDate)
        let saved = p
        let acceptedNaN = p.reconcileRealizedYearToDate(.nan)
        let acceptedInfinity = p.reconcileRealizedYearToDate(.infinity)
        #expect(!acceptedNaN)
        #expect(!acceptedInfinity)
        #expect(p == saved)
        let restored = try JSONDecoder().decode(Portfolio.self, from: JSONEncoder().encode(p))
        #expect(restored.realizedCheckpoint == saved.realizedCheckpoint)
        #expect(restored.realizedYearToDate(asOf: checkpointDate) == -197)
        #expect(restored.transactions == p.transactions)
    }

    @Test func combinedTotalsRespectEachAccountsCheckpoint() {
        var config = StockTickerConfig(symbols: ["AAA"], coins: [])
        var first = portfolio()
        first.reconcileRealizedYearToDate(-197, asOf: checkpointDate)
        config.portfolios = [first, portfolio()]
        config.combinedPortfolioEnabled = true
        config.activePortfolioID = Portfolio.combinedID
        #expect(config.realizedYearToDate(asOf: checkpointDate) == -182)
        #expect(config.portfolios[1].realizedCheckpoint == nil)
    }

    @MainActor @Test func savingRefreshesTheActualDropdownAndWebSnapshotWithoutChangingOtherAccounts() async throws {
        _ = NSApplication.shared
        var config = StockTickerConfig(symbols: ["AAA"], coins: [])
        config.portfolios = [portfolio(), Portfolio(name: "Untouched", cash: 100)]
        config.activePortfolioID = config.portfolios[0].id
        let widget = StockTickerWidget(config: config, notificationsEnabled: false,
            initialQuotes: [MarketQuote(symbol: "AAA", price: 20, change: 0, kind: .stock, sparkline: [])])
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.buildView()
        defer { window.contentView = nil; window.close(); widget.stop() }
        let otherAccount = widget.config.portfolios[1]
        var updates = 0
        widget.onDisplayUpdate = { updates += 1 }
        #expect(widget.reconcileRealizedYearToDate(-197))
        #expect(updates == 1)
        // The production data notification is coalesced onto the next main turn.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(widget.config.portfolios[1] == otherAccount)
        func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        let content = try #require(window.contentView)
        let value = try #require(allViews(content).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "portfolio.realizedYTD"
        })
        #expect(value.stringValue == widget.formatSignedCurrency(-197))
        let payload = PortfolioWebSnapshot.make(config: widget.config, quotes: widget.quotes, indices: [])
        let summary = try #require(payload["summary"] as? [String: Any])
        #expect(summary["realizedPL"] as? Double == -197)
        widget.config.combinedPortfolioEnabled = true
        widget.config.activePortfolioID = Portfolio.combinedID
        let before = widget.config
        #expect(!widget.reconcileRealizedYearToDate(10))
        #expect(widget.config == before)
    }
}
