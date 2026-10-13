import XCTest
import Cocoa
import CryptoKit
@testable import Barista

final class RecoveryStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: InMemoryTestPreferences!
    private var store: RecoveryStore!
    private let domain = "com.noam.barista.tests.recovery"

    override func setUpWithError() throws {
        XCTAssertTrue(AppPreferences.isRunningTests)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-" + UUID().uuidString)
        defaults = InMemoryTestPreferences(suiteName: domain)
        store = RecoveryStore(defaults: defaults, directory: root.appendingPathComponent("Recovery"), domain: domain)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func seed(cash: Double = 250) throws {
        var config = StockTickerConfig(symbols: ["AAPL", "MSFT"], coins: [], holdings: ["AAPL": 2], cash: cash)
        config.setQuantity(2, for: "AAPL", averageCost: 150)
        let data = try JSONEncoder().encode(config)
        let widget = SavedWidget(instanceID: UUID(), widgetID: "stock-ticker", order: 0, configData: data, isEnabled: true)
        defaults.set(try JSONEncoder().encode([widget]), forKey: "barista.activeWidgets")
        defaults.set(try JSONEncoder().encode(["stock-ticker": data]), forKey: "barista.widgetMemory")
        defaults.set(try JSONEncoder().encode([WidgetProfile(name: "Test", widgets: [widget])]), forKey: "barista.profiles")
        defaults.set(try JSONEncoder().encode(["history": [PortfolioHistoryService.Point(time: Date(), value: 100)]]), forKey: "barista.portfolioHistory")
        defaults.set(Data(#"{"notes":{"AAPL":{"thesis":"Keep this","risks":"","catalysts":""}},"preferences":{"compact":true}}"#.utf8), forKey: "marketbar.researchWorkspace.v1")
        defaults.set(try JSONEncoder().encode(MenuBarAppearance.default), forKey: "barista.menuBarAppearance")
        defaults.set("Test layout", forKey: "barista.activeProfile")
        defaults.set("outside this app", forKey: "unrelated.setting")
    }

    func testCompleteRoundTripAndUndoPreserveEveryOwnedKeyAndUnrelatedSettings() throws {
        try seed()
        let original = defaults.dictionaryRepresentation().filter { RecoveryStore.owns($0.key) }
        let backup = try store.capture(reason: "Before edit")
        defaults.removeObject(forKey: "barista.activeWidgets")
        defaults.removeObject(forKey: "marketbar.researchWorkspace.v1")
        defaults.set("changed", forKey: "barista.newSetting")
        defaults.set("new unrelated", forKey: "unrelated.setting")
        let changed = defaults.dictionaryRepresentation().filter { RecoveryStore.owns($0.key) }
        let undo = try store.restore(backup)
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: defaults.dictionaryRepresentation().filter { RecoveryStore.owns($0.key) }))
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "new unrelated")
        XCTAssertTrue(try store.preview(backup).summary.contains("2 watchlist entries"))
        XCTAssertTrue(try store.preview(backup).summary.contains("1 positions"))
        _ = try store.restore(undo)
        XCTAssertTrue(NSDictionary(dictionary: changed).isEqual(to: defaults.dictionaryRepresentation().filter { RecoveryStore.owns($0.key) }))
        XCTAssertTrue(try store.preview(undo).archive.kept)
    }

    func testProtectedEditSavesBeforeAndAfterAndNoOpDoesNotFillTimeline() throws {
        try seed()
        let old = defaults.data(forKey: "barista.activeWidgets")
        store.protect("Delete widget") { defaults.set(Data("[]".utf8), forKey: "barista.activeWidgets") }
        let backups = try store.backups()
        XCTAssertEqual(backups.count, 2)
        let before = try XCTUnwrap(backups.first { $0.archive.reason == "Before Delete widget" })
        _ = try store.restore(before.url)
        XCTAssertEqual(defaults.data(forKey: "barista.activeWidgets"), old)
        let count = try store.backups().count
        _ = try store.capture()
        XCTAssertEqual(try store.backups().count, count)
    }

    func testDamagedWrongProductAndFutureVersionAreRejectedWithoutAnyWrites() throws {
        try seed()
        let backup = try store.capture()
        let original = defaults.dictionaryRepresentation()
        let beforeCount = try store.backups().count
        let good = try PropertyListDecoder().decode(RecoveryStore.Archive.self, from: Data(contentsOf: backup))
        var variants = [good, good, good]
        variants[0].payload.append(0)
        variants[1].domain = "com.noam.different.app"
        variants[2].version = 999
        for (index, archive) in variants.enumerated() {
            let bad = root.appendingPathComponent("bad-\(index).marketbarbackup")
            try PropertyListEncoder().encode(archive).write(to: bad)
            XCTAssertThrowsError(try store.restore(bad))
            XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: defaults.dictionaryRepresentation()))
        }
        XCTAssertEqual(try store.backups().count, beforeCount, "Validation must happen before the safety backup or any preference mutation")
    }

    func testSemanticallyInvalidPortfolioIsRejectedEvenWithValidChecksum() throws {
        try seed()
        let backup = try store.capture()
        var archive = try PropertyListDecoder().decode(RecoveryStore.Archive.self, from: Data(contentsOf: backup))
        var values = try XCTUnwrap(PropertyListSerialization.propertyList(from: archive.payload, format: nil) as? [String: Any])
        var widgets = try JSONDecoder().decode([SavedWidget].self, from: try XCTUnwrap(values["barista.activeWidgets"] as? Data))
        widgets[0].configData = Data(#"{"symbols":["AAPL"],"portfolios":[{"id":"x","name":"Bad","holdings":{"AAPL":-5},"cash":10}]}"#.utf8)
        values["barista.activeWidgets"] = try JSONEncoder().encode(widgets)
        archive.payload = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        archive.checksum = SHA256.hash(data: archive.payload).map { String(format: "%02x", $0) }.joined()
        let bad = root.appendingPathComponent("invalid.marketbarbackup")
        try PropertyListEncoder().encode(archive).write(to: bad)
        let original = defaults.dictionaryRepresentation()
        XCTAssertThrowsError(try store.restore(bad))
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: defaults.dictionaryRepresentation()))
    }

    func testCorruptCurrentDataIsPreservedAndDoesNotHideOlderUsableBackup() throws {
        try seed()
        let good = try store.capture()
        defaults.set(Data("broken layout".utf8), forKey: "barista.activeWidgets")
        let damaged = try store.capture(force: true)
        XCTAssertNotNil(store.currentDataProblem())
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
        XCTAssertEqual(try store.backups().map(\.url), [good])
        _ = try store.restore(good)
        XCTAssertNil(store.currentDataProblem())
    }

    func testExportCanRestoreInANewInstallationWithoutLocalHistory() throws {
        try seed()
        let exported = root.appendingPathComponent("portable.marketbarbackup")
        try store.export(to: exported)
        let fresh = try XCTUnwrap(InMemoryTestPreferences(suiteName: "com.noam.barista.tests.fresh"))
        let target = RecoveryStore(defaults: fresh, directory: root.appendingPathComponent("New/Recovery"), domain: domain)
        _ = try target.restore(exported)
        XCTAssertEqual(fresh.data(forKey: "barista.activeWidgets"), defaults.data(forKey: "barista.activeWidgets"))
        XCTAssertEqual(fresh.data(forKey: "marketbar.researchWorkspace.v1"), defaults.data(forKey: "marketbar.researchWorkspace.v1"))
        XCTAssertNil(fresh.object(forKey: "unrelated.setting"))
        let mode = try FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testQuoteNoiseIsDeduplicatedButPeriodicHistoryIsCaptured() throws {
        try seed()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let clocked = RecoveryStore(defaults: defaults, directory: root.appendingPathComponent("Recovery"), domain: domain, clock: { now })
        let first = try clocked.capture()
        defaults.set(Data("cached quote".utf8), forKey: "barista.stockTicker.lastGoodQuotes")
        XCTAssertEqual(try clocked.capture(), first)
        now.addTimeInterval(901)
        XCTAssertNotEqual(try clocked.capture(), first)
        XCTAssertEqual(try clocked.backups().count, 2)
    }

    func testRetentionKeepsDailyStartingPointAndManualAndUndoBackups() throws {
        try seed()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let clocked = RecoveryStore(defaults: defaults, directory: root.appendingPathComponent("Recovery"), domain: domain, recentLimit: 2, clock: { now })
        let first = try clocked.capture(force: true)
        let manual = try clocked.capture(reason: "Manual backup", kept: true, force: true)
        for index in 1...8 {
            now.addTimeInterval(10)
            defaults.set("change-\(index)", forKey: "barista.activeProfile")
            _ = try clocked.capture(force: true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "Repeated edits must not evict the day's starting state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertEqual(try clocked.backups().count, 4)
        _ = try clocked.restore(first)
        XCTAssertTrue(try clocked.backups().contains { $0.archive.reason.contains("undo this restore") && $0.archive.kept })
    }

    func testFailedSafetyBackupPreventsRestore() throws {
        try seed()
        let backup = try store.capture()
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: blocker)
        let blocked = RecoveryStore(defaults: defaults, directory: blocker.appendingPathComponent("Recovery"), domain: domain)
        let original = defaults.dictionaryRepresentation()
        XCTAssertThrowsError(try blocked.restore(backup))
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: defaults.dictionaryRepresentation()))
    }

    func testNestedProtectedChangesMakeOneCompleteBeforeAndAfterSnapshot() throws {
        try seed()
        store.protect("Edit portfolio") {
            store.protect("Save active widgets") {
                defaults.set(Data("[]".utf8), forKey: "barista.activeWidgets")
            }
            store.protect("Save memory") {
                defaults.set(Data("{}".utf8), forKey: "barista.widgetMemory")
            }
        }
        let backups = try store.backups()
        XCTAssertEqual(backups.count, 2)
        XCTAssertEqual(Set(backups.map { $0.archive.reason }), ["Before Edit portfolio", "Edit portfolio"])
    }

    func testWholePortfolioDeletionBacksUpHistoryBeforeForgettingIt() throws {
        var config = StockTickerConfig(symbols: [], coins: [], cash: 100)
        let deleted = Portfolio(name: "Disposable", holdings: ["TEST": 2], costBasis: ["TEST": 10], cash: 25)
        config.portfolios.append(deleted)
        let widgets = [SavedWidget(instanceID: UUID(), widgetID: "stock-ticker", order: 0,
            configData: try JSONEncoder().encode(config), isEnabled: true)]
        defaults.set(try JSONEncoder().encode(widgets), forKey: "barista.activeWidgets")
        let history = try JSONEncoder().encode([deleted.id: [PortfolioHistoryService.Point(time: Date(), value: 45)]])
        defaults.set(history, forKey: "barista.portfolioHistory")
        let historyService = PortfolioHistoryService(defaults: defaults)
        let widget = StockTickerWidget(config: config, notificationsEnabled: false,
            historyService: historyService, recoveryStore: store)
        XCTAssertTrue(widget.deletePortfolio(id: deleted.id))
        historyService.flushPendingWrites()
        let before = try XCTUnwrap(try store.backups().first { $0.archive.reason == "Before portfolio deletion" })
        _ = try store.restore(before.url)
        XCTAssertEqual(defaults.data(forKey: "barista.portfolioHistory"), history)
        XCTAssertEqual(ResearchWorkspaceService.configuration(defaults: defaults).portfolios.count, 2)
    }

    func testRestoringBackupFromBeforeHistoryDoesNotResurrectOldInMemoryChart() throws {
        try seed()
        defaults.removeObject(forKey: "barista.portfolioHistory")
        let beforeHistory = try store.capture()
        defaults.set(try JSONEncoder().encode(["x": [PortfolioHistoryService.Point(time: Date(), value: 100)]]), forKey: "barista.portfolioHistory")
        let service = PortfolioHistoryService(defaults: defaults)
        XCTAssertEqual(service.points(for: "x", range: .all, continuous: true).count, 1)
        _ = try store.restore(beforeHistory)
        XCTAssertTrue(service.points(for: "x", range: .all, continuous: true).isEmpty)
    }

    func testMissingPreferencesAreDetectedWhenAnOlderBackupCanRecoverThem() throws {
        try seed()
        let backup = try store.capture()
        defaults.setPersistentDomain([:], forName: domain)
        _ = try store.capture(force: true)
        XCTAssertTrue(store.currentDataProblem()?.contains("missing") == true)
        _ = try store.restore(backup)
        XCTAssertNil(store.currentDataProblem())
        XCTAssertEqual(ResearchWorkspaceService.configuration(defaults: defaults).cash, 250)
    }

    func testProductionRecoveryStoreIsDisabledForTests() {
        XCTAssertNil(RecoveryStore.shared)
        XCTAssertTrue(AppPreferences.shared is InMemoryTestPreferences)
    }
}

@MainActor
final class RecoveryInterfaceTests: XCTestCase {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    func testRestoreButtonShowsPreviewAndRunsReversibleRestoreWithIsolatedData() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(InMemoryTestPreferences(suiteName: "com.noam.barista.tests.recovery.ui"))
        let store = RecoveryStore(defaults: defaults, directory: root.appendingPathComponent("Recovery"), domain: "test")
        let config = StockTickerConfig(symbols: [], coins: [], cash: 250)
        let widgets = [SavedWidget(instanceID: UUID(), widgetID: "stock-ticker", order: 0, configData: try JSONEncoder().encode(config), isEnabled: true)]
        defaults.set(try JSONEncoder().encode(widgets), forKey: "barista.activeWidgets")
        _ = try store.capture()
        defaults.set(Data("[]".utf8), forKey: "barista.activeWidgets")
        var confirmations = 0
        var lifecycle: [String] = []
        let controller = RecoveryWindowController(store: store,
            willRestore: { lifecycle.append("stop old widgets") }, didRestore: { lifecycle.append("reload widgets") },
            confirmRestore: { backup in confirmations += 1; return backup.summary.contains("250.00") })
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(content.bounds.width, 460)
        XCTAssertLessThanOrEqual(content.bounds.height, 380)
        let preview = try XCTUnwrap(views(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "recovery.preview" })
        XCTAssertTrue(preview.stringValue.contains("cash 250.00"))
        XCTAssertNotNil(preview.enclosingScrollView)
        XCTAssertEqual(preview.enclosingScrollView?.bounds.height, 100)
        let restore = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "recovery.restore" })
        restore.performClick(nil)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(lifecycle, ["stop old widgets", "reload widgets"])
        XCTAssertEqual(ResearchWorkspaceService.configuration(defaults: defaults).cash, 250)
        XCTAssertTrue(try store.backups().contains { $0.archive.reason.contains("undo this restore") })
        XCTAssertTrue(views(content).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("Restored successfully") })
        content.layoutSubtreeIfNeeded()
        for view in views(content) where view is NSButton || view.identifier?.rawValue == "recovery.status" {
            let frame = view.convert(view.bounds, to: content)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, content.bounds.height)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width)
        }
    }

    func testCancelledRestoreLeavesCurrentDataAndRunningWidgetsAlone() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(InMemoryTestPreferences(suiteName: "com.noam.barista.tests.recovery.cancel"))
        let store = RecoveryStore(defaults: defaults, directory: root.appendingPathComponent("Recovery"), domain: "test")
        defaults.set("old", forKey: "barista.activeProfile")
        _ = try store.capture()
        defaults.set("new", forKey: "barista.activeProfile")
        let controller = RecoveryWindowController(store: store, willRestore: { XCTFail("Cancelled restore must not stop widgets") }, confirmRestore: { _ in false })
        let button = try XCTUnwrap(views(try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "recovery.restore" })
        button.performClick(nil)
        XCTAssertEqual(defaults.string(forKey: "barista.activeProfile"), "new")
        XCTAssertEqual(try store.backups().count, 1)
    }

    func testFailedQuoteRetryInDropdownPreservesPositionCostAndLedgerAndRedrawsLiveItem() throws {
        _ = NSApplication.shared
        var config = StockTickerConfig(symbols: ["AAPL"], coins: [], holdings: ["AAPL": 2], cash: 100)
        config.setQuantity(2, for: "AAPL", averageCost: 150)
        let widget = StockTickerWidget(config: config, notificationsEnabled: false)
        let instance = WidgetInstance(id: UUID(), widgetID: "stock-ticker", widget: AnyBaristaWidget(widget), order: 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        instance.statusItem = item
        defer { NSStatusBar.system.removeStatusItem(item) }
        var redraws = 0
        widget.onDisplayUpdate = { redraws += 1; instance.updateStatusItem() }
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        var y: CGFloat = 500
        controller.addFailedRow("AAPL", y: &y, pad: 16, cw: 388)
        let retry = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "retry:stock:AAPL" })
        let before = try JSONEncoder().encode(widget.config)
        retry.performClick(nil)
        XCTAssertEqual(widget.config.holdings, ["AAPL": 2])
        XCTAssertEqual(widget.config.costBasis, ["AAPL": 150])
        XCTAssertEqual(try JSONDecoder().decode(StockTickerConfig.self, from: before).portfolios, widget.config.portfolios)
        XCTAssertEqual(widget.config.symbols, ["AAPL"])
        XCTAssertEqual(redraws, 1)
        XCTAssertTrue(retry.toolTip?.contains("preserved") == true)
    }

    func testRestoreReplacesLiveWidgetAndMenuImmediatelyWithRecoveredState() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if WidgetRegistry.shared.entry(for: "stock-ticker") == nil { WidgetRegistry.shared.register(StockTickerWidget.self) }
        let delegate = AppDelegate()
        defer { delegate.statusBarController.removeAllWidgets() }
        let store = RecoveryStore(defaults: AppPreferences.shared, directory: root.appendingPathComponent("Recovery"), domain: AppPreferences.testSuiteName)
        var config = StockTickerConfig(symbols: [], coins: [], cash: 250)
        config.displayMode = .portfolio
        let id = UUID()
        func save(_ config: StockTickerConfig) throws {
            WidgetStore.shared.save([SavedWidget(instanceID: id, widgetID: "stock-ticker", order: 0,
                configData: try JSONEncoder().encode(config), isEnabled: true)])
        }
        try save(config)
        let backup = try store.capture()
        config.cash = 9
        try save(config)
        delegate.statusBarController.syncMenuBar()
        let old = try XCTUnwrap(delegate.statusBarController.instances[id])
        old.showDropdownMenu()
        XCTAssertTrue(old.popoverController?.isShown == true)
        let titleBefore = old.statusItem?.button?.attributedTitle.string
        delegate.prepareForRecovery()
        _ = try store.restore(backup)
        delegate.reloadAfterRecovery()
        let recovered = try XCTUnwrap(delegate.statusBarController.instances[id])
        XCTAssertFalse(recovered === old)
        XCTAssertEqual(recovered.widget.underlying(as: StockTickerWidget.self)?.config.cash, 250)
        XCTAssertNotEqual(recovered.statusItem?.button?.attributedTitle.string, titleBefore)
        recovered.showDropdownMenu()
        XCTAssertTrue(recovered.popoverController?.isShown == true)
        let content = try XCTUnwrap(NSApp.windows.first { $0.title == "Menu bar dropdown" && $0.isVisible }?.contentView)
        XCTAssertTrue(views(content).compactMap { $0 as? NSButton }.contains { $0.title == "Backup & Recovery…" })
        let recovery = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "recovery.open" })
        let footer = try XCTUnwrap(recovery.superview)
        XCTAssertTrue(footer.subviews.compactMap { $0 as? NSButton }.contains { $0.title == "Refresh now" })
        XCTAssertEqual(footer.frame.maxY + 14, footer.superview?.bounds.maxY)
        XCTAssertLessThanOrEqual(recovery.frame.height, 18)
        XCTAssertLessThanOrEqual(recovery.frame.width, 112)
        XCTAssertFalse(recovery.isBordered)
        recovered.popoverController?.dismiss()
    }

    func testRecoveryIsDiscoverableFromAppMenuAndNativeSidebar() throws {
        _ = NSApplication.shared
        let appMenu = try XCTUnwrap(AppDelegate().makeApplicationMenu().items.first?.submenu)
        XCTAssertTrue(appMenu.items.contains { $0.title == "Backup & Recovery…" && $0.action == #selector(AppDelegate.showRecoveryWindow) })
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: [], coins: []), notificationsEnabled: false)
        let controller = MarketbarWindowController(widget: widget)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(views(content).compactMap { $0 as? NSButton }.contains { $0.title == "Backup & Recovery…" })
        let recovery = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "recovery.open" })
        let sidebar = try XCTUnwrap(recovery.superview as? NSStackView)
        XCTAssertTrue(sidebar.arrangedSubviews.last === recovery)
        XCTAssertEqual(recovery.controlSize, .mini)
        XCTAssertFalse(recovery.isBordered)
    }
}
