import XCTest
import Cocoa
@testable import Barista

@MainActor
final class CombinedPortfolioTests: XCTestCase {
    private func config() -> StockTickerConfig {
        var config = StockTickerConfig(symbols: ["AAA", "BBB"], coins: [])
        config.portfolios = [
            Portfolio(id: "first", name: "Main", holdings: ["AAA": 2], costBasis: ["AAA": 10], cash: 100),
            Portfolio(id: "second", name: "Savings", holdings: ["AAA": 3, "BBB": 4],
                      costBasis: ["AAA": 20, "BBB": 5], cash: -25)
        ]
        config.activePortfolioID = "second"
        return config
    }

    private func widget(_ config: StockTickerConfig? = nil) -> StockTickerWidget {
        StockTickerWidget(config: config ?? self.config(), notificationsEnabled: false, initialQuotes: [
            MarketQuote(symbol: "AAA", price: 30, change: 2, kind: .stock, sparkline: [28, 29, 30]),
            MarketQuote(symbol: "BBB", price: 10, change: -1, kind: .stock, sparkline: [11, 10, 10])
        ])
    }

    private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }

    func testAggregateMergesPositionsWeightedCostsCashAndIndependentLedgers() throws {
        var config = config()
        // Corrections are absolute within each account, never across accounts.
        config.portfolios[0].setQuantity(7, for: "AAA", averageCost: 10)
        config.portfolios[1].record(Transaction(date: Date(), symbol: "AAA", kind: .sell, quantity: 1, price: 40))
        let originals = config.portfolios
        let combined = Portfolio.combined(originals)
        XCTAssertEqual(combined.holdings, ["AAA": 9, "BBB": 4])
        XCTAssertEqual(try XCTUnwrap(combined.costBasis["AAA"]), 110.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(combined.cash, 75)
        XCTAssertEqual(combined.realizedTotal, 20)
        XCTAssertEqual(combined.tradeHistory.count, 2)
        XCTAssertTrue(combined.tradeHistory.contains { $0.note?.contains("Savings") == true })
        XCTAssertEqual(config.portfolios, originals)
    }

    func testUnknownCostStaysUnknownForMergedSymbol() {
        var config = config()
        config.portfolios[1].costBasis.removeValue(forKey: "AAA")
        let combined = Portfolio.combined(config.portfolios)
        XCTAssertEqual(combined.holdings["AAA"], 5)
        XCTAssertNil(combined.costBasis["AAA"])
        XCTAssertEqual(combined.costBasis["BBB"], 5)
    }

    func testToggleIsPersistedAndReturnsToPreviousPortfolio() throws {
        let widget = widget()
        XCTAssertFalse(widget.config.combinedPortfolioEnabled)
        let originals = widget.config.portfolios
        widget.setCombinedPortfolioEnabled(true)
        XCTAssertTrue(widget.config.isCombinedPortfolioActive)
        XCTAssertEqual(widget.activePortfolioName, "All Portfolios")
        XCTAssertEqual(widget.config.portfolioChoices.count, 3)
        XCTAssertEqual(widget.config.portfolios, originals, "The combined portfolio is never stored as another account")
        let restored = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(widget.config))
        XCTAssertTrue(restored.isCombinedPortfolioActive)
        XCTAssertEqual(restored.combinedPortfolioHistoryID, widget.config.combinedPortfolioHistoryID)
        XCTAssertEqual(restored.cash, 75)
        widget.setCombinedPortfolioEnabled(false)
        XCTAssertEqual(widget.config.activePortfolioID, "second")
        XCTAssertEqual(widget.config.portfolioChoices.count, 2)
        widget.selectPortfolio(id: Portfolio.combinedID)
        XCTAssertEqual(widget.config.activePortfolioID, "second", "A hidden combined portfolio cannot be selected")
    }

    func testOldConfigDefaultsToHiddenAndDisabledSelectionFallsBack() throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config())) as? [String: Any])
        saved.removeValue(forKey: "combinedPortfolioEnabled")
        saved.removeValue(forKey: "lastIndividualPortfolioID")
        saved["activePortfolioID"] = Portfolio.combinedID
        let restored = try JSONDecoder().decode(StockTickerConfig.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertFalse(restored.combinedPortfolioEnabled)
        XCTAssertEqual(restored.activePortfolioID, "first")
        XCTAssertEqual(restored.cash, 100)
    }

    /// A config saved without the combined history ID used to get a fresh
    /// random one on every decode, so each launch recorded the combined chart
    /// under a new series and the old ones were orphaned.
    private func savedWithoutHistoryID() throws -> Data {
        var config = config()
        config.combinedPortfolioEnabled = true
        config.activePortfolioID = Portfolio.combinedID
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNotNil(saved.removeValue(forKey: "combinedPortfolioHistoryID"))
        return try JSONSerialization.data(withJSONObject: saved)
    }

    func testMissingHistoryIDIsTheSameOnEveryLaunch() throws {
        let saved = try savedWithoutHistoryID()
        let firstLaunch = try JSONDecoder().decode(StockTickerConfig.self, from: saved)
        let secondLaunch = try JSONDecoder().decode(StockTickerConfig.self, from: saved)
        XCTAssertTrue(firstLaunch.isCombinedPortfolioActive)
        XCTAssertEqual(firstLaunch.combinedPortfolioHistoryID, secondLaunch.combinedPortfolioHistoryID)
        XCTAssertEqual(firstLaunch.activePortfolioHistoryID, firstLaunch.combinedPortfolioHistoryID)
        XCTAssertFalse(firstLaunch.portfolios.contains { $0.id == firstLaunch.combinedPortfolioHistoryID },
                       "Combined history must not share a series with an individual portfolio")
        XCTAssertNotEqual(firstLaunch.combinedPortfolioHistoryID, Portfolio.combinedID)
        XCTAssertTrue(firstLaunch.needsCombinedHistoryIDWriteBack)

        let current = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(config()))
        XCTAssertFalse(current.needsCombinedHistoryIDWriteBack, "A saved ID needs no write-back")
    }

    func testDerivedHistoryIDIsWrittenBackOnceAndSurvivesLaterEdits() throws {
        let decoded = try JSONDecoder().decode(StockTickerConfig.self, from: savedWithoutHistoryID())
        let launched = widget(decoded)
        let historyID = launched.config.combinedPortfolioHistoryID
        let saved = expectation(forNotification: .baristaWidgetConfigChanged, object: launched)
        launched.persistDecodeMigrationsIfNeeded()
        wait(for: [saved], timeout: 1)
        XCTAssertFalse(launched.config.needsCombinedHistoryIDWriteBack)

        // Next launch reads what was written back, and keeps the same series even
        // after the portfolio the ID was derived from is deleted.
        var relaunched = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(launched.config))
        XCTAssertEqual(relaunched.combinedPortfolioHistoryID, historyID)
        XCTAssertFalse(relaunched.needsCombinedHistoryIDWriteBack)
        relaunched.portfolios.removeFirst()
        let afterDelete = try JSONDecoder().decode(StockTickerConfig.self, from: JSONEncoder().encode(relaunched))
        XCTAssertEqual(afterDelete.combinedPortfolioHistoryID, historyID)

        let unchanged = widget(relaunched)
        let noSave = expectation(forNotification: .baristaWidgetConfigChanged, object: unchanged)
        noSave.isInverted = true
        unchanged.persistDecodeMigrationsIfNeeded()
        wait(for: [noSave], timeout: 0.3)
    }

    func testCombinedCannotBeEditedAndSourceEditsUpdateSnapshotAutomatically() throws {
        let widget = widget()
        widget.setCombinedPortfolioEnabled(true)
        let originals = widget.config.portfolios
        widget.setHolding(symbol: "AAA", kind: .stock, quantity: 999)
        widget.setCash(999)
        widget.renameActivePortfolio(to: "Changed")
        XCTAssertFalse(widget.recordTrade(symbol: "AAA", kind: .stock, side: .buy, quantity: 1, price: 10))
        XCTAssertFalse(widget.deletePortfolio(id: Portfolio.combinedID))
        XCTAssertFalse(widget.deleteTrade(id: "anything"))
        widget.config.setQuantity(999, for: "AAA")
        widget.config.cash = 999
        widget.config.holdings = ["AAA": 999]
        XCTAssertEqual(widget.config.portfolios, originals)
        XCTAssertEqual(try XCTUnwrap(widget.portfolioSnapshot()).total, 265)
        widget.selectPortfolio(id: "first")
        widget.setCash(200)
        widget.selectPortfolio(id: Portfolio.combinedID)
        XCTAssertEqual(try XCTUnwrap(widget.portfolioSnapshot()).total, 365)
        XCTAssertTrue(widget.deletePortfolio(id: "second"))
        XCTAssertEqual(widget.config.holdings, ["AAA": 2])
        XCTAssertEqual(widget.config.cash, 200)
        widget.setCombinedPortfolioEnabled(false)
        XCTAssertEqual(widget.config.activePortfolioID, "first")
    }

    func testCombinedDoesNotUseAnIndividualPortfolioSlot() {
        var config = config()
        config.portfolios = (0..<Portfolio.maxCount).map { Portfolio(name: "Account \($0)") }
        config.activePortfolioID = config.portfolios[0].id
        let widget = widget(config)
        widget.setCombinedPortfolioEnabled(true)
        XCTAssertEqual(widget.config.portfolioChoices.count, Portfolio.maxCount + 1)
        XCTAssertFalse(widget.canAddPortfolio)
        XCTAssertFalse(widget.addPortfolio(named: "Extra"))
    }

    func testWebSnapshotUsesCombinedValuesAndOriginalAccountCount() throws {
        let widget = widget()
        widget.setCombinedPortfolioEnabled(true)
        let payload = PortfolioWebSnapshot.make(config: widget.config, quotes: widget.quotes, indices: [])
        let summary = try XCTUnwrap(payload["summary"] as? [String: Any])
        XCTAssertEqual(payload["portfolioName"] as? String, Portfolio.combinedName)
        XCTAssertEqual(payload["combinedPortfolio"] as? Bool, true)
        XCTAssertEqual((payload["portfolios"] as? [[String: String]])?.count, 2)
        XCTAssertEqual(summary["liveTotal"] as? Double, 265)
        XCTAssertEqual(summary["cash"] as? Double, 75)
        XCTAssertEqual(summary["positions"] as? Int, 2)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testDropdownToggleRebuildsTabsAndEditingControlsInPlace() throws {
        _ = NSApplication.shared
        let widget = widget()
        var displayUpdates = 0
        widget.onDisplayUpdate = { displayUpdates += 1 }
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        func toggle() throws -> NSButton {
            try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "portfolio.combined.toggle"
            })
        }
        try toggle().performClick(nil)
        XCTAssertTrue(widget.config.isCombinedPortfolioActive)
        XCTAssertEqual(displayUpdates, 1)
        let buttons = allViews(content).compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.contains { $0.identifier?.rawValue == Portfolio.combinedID })
        XCTAssertTrue(buttons.filter { $0.action == NSSelectorFromString("holdingsClicked:") }.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(buttons.filter { $0.action == NSSelectorFromString("cashClicked:") }.allSatisfy { !$0.isEnabled })
        let first = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "first" })
        first.performClick(nil)
        XCTAssertEqual(widget.config.activePortfolioID, "first")
        XCTAssertTrue(allViews(content).compactMap { $0 as? NSButton }
            .contains { $0.action == NSSelectorFromString("holdingsClicked:") && $0.isEnabled })
        try toggle().performClick(nil)
        XCTAssertFalse(widget.config.combinedPortfolioEnabled)
        XCTAssertFalse(allViews(content).contains { $0.identifier?.rawValue == Portfolio.combinedID })
    }

    func testMarketbarWindowToggleUpdatesPickerValuesAndEditingControls() throws {
        _ = NSApplication.shared
        let widget = widget()
        let controller = MarketbarWindowController(widget: widget)
        let window = try XCTUnwrap(controller.window)
        defer { _ = controller.windowShouldClose(window) }
        let content = try XCTUnwrap(window.contentView)
        let toggle = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "portfolio.combined.toggle"
        })
        let picker = try XCTUnwrap(allViews(content).compactMap { $0 as? NSPopUpButton }.first {
            $0.itemArray.contains { ($0.representedObject as? String) == "first" }
        })
        let total = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "marketbar.portfolio.total"
        })
        toggle.performClick(nil)
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, Portfolio.combinedID)
        XCTAssertEqual(total.stringValue, widget.formatCurrency(265))
        XCTAssertTrue(allViews(content).compactMap { $0 as? NSButton }
            .filter { ["Edit cash", "Position", "Manage"].contains($0.title) }.allSatisfy { !$0.isEnabled })
        toggle.performClick(nil)
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, "second")
        XCTAssertFalse(picker.itemTitles.contains(Portfolio.combinedName))
        XCTAssertTrue(allViews(content).compactMap { $0 as? NSButton }
            .filter { ["Edit cash", "Position", "Manage"].contains($0.title) }.allSatisfy(\.isEnabled))
    }

    func testCombinedDropdownToggleUpdatesLiveMenuBarAfterDismissal() throws {
        _ = NSApplication.shared
        let widget = widget()
        widget.config.displayMode = .portfolio
        let instance = WidgetInstance(id: UUID(), widgetID: "stock-ticker", widget: AnyBaristaWidget(widget), order: 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        instance.statusItem = item
        widget.onDisplayUpdate = { [weak instance] in instance?.updateStatusItem() }
        instance.updateStatusItem()
        let before = try XCTUnwrap(item.button).attributedTitle.string
        defer { instance.popoverController?.dismiss(); NSStatusBar.system.removeStatusItem(item) }
        instance.showDropdownMenu()
        XCTAssertTrue(instance.popoverController?.isShown == true)
        let content = try XCTUnwrap(NSApp.windows.first { $0.title == "Menu bar dropdown" }?.contentView)
        let toggle = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "portfolio.combined.toggle"
        })
        toggle.performClick(nil)
        XCTAssertTrue(widget.config.isCombinedPortfolioActive)
        XCTAssertTrue(instance.popoverController?.isShown == true)
        XCTAssertEqual(item.button?.attributedTitle.string, before)
        instance.popoverController?.dismiss()
        XCTAssertNotEqual(item.button?.attributedTitle.string, before)
        XCTAssertTrue(item.button?.attributedTitle.string.contains("265") == true)
    }
}
