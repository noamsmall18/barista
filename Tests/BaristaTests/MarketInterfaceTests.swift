import XCTest
import Cocoa
@testable import Barista

@MainActor
final class MarketInterfaceTests: XCTestCase {
    private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }

    private func fixtureWidget() -> StockTickerWidget {
        let config = StockTickerConfig(symbols: ["AAPL", "MSFT"], coins: [], holdings: ["AAPL": 8, "MSFT": 3], cash: 250)
        let apple = MarketQuote(symbol: "AAPL", price: 225, change: 1.8, kind: .stock,
                                dayHigh: 228, dayLow: 221, volume: 42_000_000,
                                sparkline: [219, 221, 220, 223, 222, 224, 225], marketCap: 3_400_000_000_000)
        let microsoft = MarketQuote(symbol: "MSFT", price: 420, change: -0.7, kind: .stock, sparkline: [424, 423, 421, 422, 420])
        return StockTickerWidget(config: config, notificationsEnabled: false, initialQuotes: [apple, microsoft])
    }

    private func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private func waitForUI(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { turnRunLoop() }
    }

    func testNativeApplicationMenuProvidesQuitAndTextEditingShortcuts() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = delegate.makeApplicationMenu()
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(appMenu.items.first { $0.action == #selector(NSApplication.terminate(_:)) }?.keyEquivalent, "q")
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        XCTAssertEqual(edit.items.first { $0.action == #selector(NSText.paste(_:)) }?.keyEquivalent, "v")
        XCTAssertEqual(edit.items.first { $0.action == #selector(NSText.selectAll(_:)) }?.keyEquivalent, "a")
    }

    func testDetailUsesLatestQuoteAndUpdatesPositionWithoutReplacingChart() throws {
        _ = NSApplication.shared
        let widget = fixtureWidget()
        let old = MarketQuote(symbol: "AAPL", price: 100, change: 0, kind: .stock, sparkline: [])
        let detail = StockDetailPopoverController(widget: widget, quote: old, fetchesRemoteData: false)
        _ = detail.view
        detail.viewDidAppear()
        defer { detail.viewDidDisappear() }
        XCTAssertEqual(detail.quote.price, 225, "details must follow the widget rather than the opening quote")
        let chart = try XCTUnwrap(allViews(detail.view).first { String(describing: type(of: $0)) == "TerminalStockChartView" })
        widget.config.holdings = ["AAPL": 4]
        widget.setCash(300)
        waitForUI { allViews(detail.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("4 shares") } }
        XCTAssertTrue(allViews(detail.view).contains { $0 === chart }, "a live update must preserve chart range and hover state")
        XCTAssertTrue(allViews(detail.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("4 shares") })
    }

    func testDetailTabsNavigateAndReturnToOverview() throws {
        _ = NSApplication.shared
        let widget = fixtureWidget()
        let detail = StockDetailPopoverController(widget: widget, quote: widget.quotes[0], fetchesRemoteData: false)
        let tabs = try XCTUnwrap(allViews(detail.view).compactMap { $0 as? NSSegmentedControl }.first)
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertTrue(allViews(detail.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("SEC FUNDAMENTALS"))
        tabs.selectedSegment = 2
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertTrue(allViews(detail.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("HEADLINES"))
        tabs.selectedSegment = 0
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertTrue(allViews(detail.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("YOUR POSITION"))
        try preview(detail.view, named: "ticker-detail")
    }

    func testClickingTickerOpensChildAndClosingParentClosesChild() throws {
        _ = NSApplication.shared
        let widget = fixtureWidget()
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 420, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        let ticker = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "detail:stock:AAPL" })
        ticker.performClick(nil)
        turnRunLoop()
        let child = try XCTUnwrap(controller.detailPopover)
        XCTAssertTrue(child.isShown)
        widget.setCash(400)
        turnRunLoop()
        XCTAssertTrue(child.isShown, "quote/config updates must not remove a nested popover's anchor")
        child.close()
        waitForUI { controller.detailPopover == nil }
        XCTAssertNil(controller.detailPopover)
        let nextTicker = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "detail:stock:AAPL" })
        nextTicker.performClick(nil)
        turnRunLoop()
        let nextChild = try XCTUnwrap(controller.detailPopover)
        panel.contentView = nil
        waitForUI { !nextChild.isShown }
        XCTAssertFalse(nextChild.isShown, "children must never be left floating when their parent closes")
    }

    func testDropdownEditReachesLiveStatusItemWhenDismissed() throws {
        _ = NSApplication.shared
        let widget = fixtureWidget()
        widget.config.displayMode = .compact
        let instance = WidgetInstance(id: UUID(), widgetID: "stock-ticker", widget: AnyBaristaWidget(widget), order: 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        instance.statusItem = item
        defer { instance.popoverController?.dismiss(); NSStatusBar.system.removeStatusItem(item) }
        widget.onDisplayUpdate = { [weak instance] in instance?.updateStatusItem() }
        instance.updateStatusItem()
        let before = try XCTUnwrap(item.button).attributedTitle.string
        instance.showDropdownMenu()
        XCTAssertTrue(instance.popoverController?.isShown == true)
        // The production button handler saves the edit and requests a redraw.
        let content = try XCTUnwrap(NSApp.windows.first { $0.title == "Menu bar dropdown" }?.contentView)
        let mode = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("displayModeChanged:") && $0.tag == 4 })
        mode.performClick(nil)
        XCTAssertEqual(widget.config.displayMode, .portfolio)
        XCTAssertEqual(item.button?.attributedTitle.string, before)
        instance.popoverController?.dismiss()
        XCTAssertNotEqual(item.button?.attributedTitle.string, before)
        XCTAssertTrue(item.button?.attributedTitle.string.contains("$") == true)
    }

    func testMarketbarWindowKeepsDraftAndSelectionDuringLiveUpdates() throws {
        _ = NSApplication.shared
        let widget = fixtureWidget()
        let controller = MarketbarWindowController(widget: widget)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        defer { _ = controller.windowShouldClose(window) }
        let content = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.placeholderString?.contains("Add a ticker") == true })
        let table = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)
        field.stringValue = "DRAFT"
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        widget.setCash(500)
        turnRunLoop()
        XCTAssertTrue(allViews(content).contains { $0 === field })
        XCTAssertEqual(field.stringValue, "DRAFT")
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertFalse(allViews(content).compactMap { ($0 as? NSTextField)?.stringValue }.contains("WIDGET GALLERY"))
        try preview(content, named: "marketbar-window")
        let nav = try XCTUnwrap(allViews(content).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 })
        nav.selectedSegment = 1
        nav.sendAction(nav.action, to: nav.target)
        let mode = try XCTUnwrap(allViews(content).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Compact ticker") })
        mode.selectItem(at: 3)
        mode.sendAction(mode.action, to: mode.target)
        XCTAssertEqual(widget.config.displayMode, .compact)
        XCTAssertEqual(widget.stockInterval(during: .open), 5, "window preferences must preserve fetching cadence")
        try preview(content, named: "marketbar-preferences")
    }

    func testStaticOrDetachedTickerDoesNotAnimate() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 30), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let ticker = TickerScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        window.contentView?.addSubview(ticker)
        ticker.updateText("AAPL 225")
        XCTAssertFalse(ticker.isAnimating)
        ticker.updateText(String(repeating: "AAPL 225 +1.8%   ", count: 10))
        XCTAssertEqual(ticker.isAnimating, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ticker.removeFromSuperview()
        XCTAssertFalse(ticker.isAnimating)
        window.contentView?.addSubview(ticker)
        XCTAssertEqual(ticker.isAnimating, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ticker.speed = 0
        XCTAssertFalse(ticker.isAnimating)
        ticker.speed = 0.3
        ticker.isHidden = true
        XCTAssertFalse(ticker.isAnimating)
        window.close()
    }

    func testQuoteNotificationsCanHaveMultipleIndependentSubscribers() {
        let widget = fixtureWidget()
        let identifier = ObjectIdentifier(widget)
        let first = expectation(description: "first window")
        let second = expectation(description: "second window")
        let a = NotificationCenter.default.addObserver(forName: StockTickerWidget.dataDidChange, object: nil, queue: .main) { note in
            if let object = note.object as? StockTickerWidget, ObjectIdentifier(object) == identifier { first.fulfill() }
        }
        let b = NotificationCenter.default.addObserver(forName: StockTickerWidget.dataDidChange, object: nil, queue: .main) { note in
            if let object = note.object as? StockTickerWidget, ObjectIdentifier(object) == identifier { second.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(a); NotificationCenter.default.removeObserver(b) }
        widget.setCash(100)
        widget.setCash(200)
        wait(for: [first, second], timeout: 2)
    }

    private func preview(_ view: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BARISTA_UI_PREVIEW_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
