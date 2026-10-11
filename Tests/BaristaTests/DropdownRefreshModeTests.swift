import XCTest
import Cocoa
@testable import Barista

@MainActor
final class DropdownRefreshModeTests: XCTestCase {
    private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    func testRefreshModeControlChangesWidgetAndExplainsProviderCadence() throws {
        _ = NSApplication.shared
        let widget = StockTickerWidget(
            config: StockTickerConfig(symbols: ["AAPL"], coins: []),
            notificationsEnabled: false,
            initialQuotes: [MarketQuote(symbol: "AAPL", price: 225, change: 1.8, kind: .stock, sparkline: [])]
        )
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 420, height: 560),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }

        XCTAssertEqual(widget.config.refreshMode, .standard)
        let ultraFast = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("refreshModeChanged:") && $0.tag == 1
        })
        XCTAssertTrue(ultraFast.toolTip?.contains("free data providers can limit") == true)
        ultraFast.performClick(nil)

        XCTAssertEqual(widget.config.refreshMode, .ultraFast)
        XCTAssertTrue(widget.refreshModeSummary.contains("2s during market hours"))
        XCTAssertTrue(allViews(content).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == widget.refreshModeSummary })
    }

    func testUltraFastDropdownActionPersistsAndDefersLiveStatusRedrawUntilDismissal() throws {
        _ = NSApplication.shared
        let widget = StockTickerWidget(
            config: StockTickerConfig(symbols: ["AAPL"], coins: []),
            notificationsEnabled: false,
            initialQuotes: [MarketQuote(symbol: "AAPL", price: 225, change: 1.8, kind: .stock, sparkline: [])]
        )
        let instance = WidgetInstance(id: UUID(), widgetID: "stock-ticker", widget: AnyBaristaWidget(widget), order: 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        instance.statusItem = item
        var liveRedrawRequests = 0
        widget.onDisplayUpdate = { [weak instance] in
            liveRedrawRequests += 1
            instance?.updateStatusItem()
        }
        instance.updateStatusItem()
        let initialTitle = try XCTUnwrap(item.button).title
        let configSaved = expectation(description: "refresh mode config is saved")
        let observer = NotificationCenter.default.addObserver(
            forName: .baristaWidgetConfigChanged, object: widget, queue: .main
        ) { _ in configSaved.fulfill() }
        defer {
            NotificationCenter.default.removeObserver(observer)
            instance.popoverController?.dismiss()
            NSStatusBar.system.removeStatusItem(item)
        }

        instance.showDropdownMenu()
        XCTAssertTrue(instance.popoverController?.isShown == true)
        let content = try XCTUnwrap(NSApp.windows.first { $0.title == "Menu bar dropdown" }?.contentView)
        let ultraFast = try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("refreshModeChanged:") && $0.tag == 1
        })
        ultraFast.performClick(nil)

        wait(for: [configSaved], timeout: 1)
        XCTAssertEqual(widget.config.refreshMode, .ultraFast)
        let persistedConfig = try XCTUnwrap(instance.widget.getConfigData())
        XCTAssertEqual(try JSONDecoder().decode(StockTickerConfig.self, from: persistedConfig).refreshMode, .ultraFast)
        XCTAssertEqual(liveRedrawRequests, 1, "the widget requests a redraw while the dropdown is open")
        XCTAssertTrue(instance.popoverController?.isShown == true, "refresh changes must not dismiss the dropdown")
        XCTAssertEqual(item.button?.title, initialTitle, "the live status item remains untouched while anchored dropdown is open")

        instance.popoverController?.dismiss()
        XCTAssertFalse(instance.popoverController?.isShown == true)
        XCTAssertEqual(item.button?.title, initialTitle, "refresh cadence does not change the displayed ticker text")
    }

    func testFeedStatusShowsCachedOrOfflineStateInDropdown() throws {
        _ = NSApplication.shared
        let widget = StockTickerWidget(
            config: StockTickerConfig(symbols: ["AAPL"], coins: []),
            notificationsEnabled: false,
            initialQuotes: []
        )
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        let content = controller.buildView()
        let labels = allViews(content).compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue == "FEED" })
        XCTAssertTrue(labels.contains { ["Offline", "Loading"].contains($0.stringValue) })
    }
}

@MainActor
final class DropdownRelevantSettingsTests: XCTestCase {
    private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    private func has(_ action: String, in content: NSView) -> Bool {
        allViews(content).compactMap { $0 as? NSControl }.contains { $0.action == NSSelectorFromString(action) }
    }

    private func dropdown(mode: TickerDisplayMode, refresh: StockTickerRefreshMode = .standard)
        -> (widget: StockTickerWidget, controller: MarketPopoverController, content: NSView) {
        _ = NSApplication.shared
        var config = StockTickerConfig(symbols: ["AAPL"], coins: [])
        config.displayMode = mode
        config.refreshMode = refresh
        let widget = StockTickerWidget(
            config: config, notificationsEnabled: false,
            initialQuotes: [MarketQuote(symbol: "AAPL", price: 225, change: 1.8, kind: .stock, sparkline: [])]
        )
        let controller = MarketPopoverController(widget: widget, fetchesDetailData: false)
        return (widget, controller, controller.buildView())
    }

    func testEachDisplayModeOffersOnlyTheSettingsItReads() {
        let expected: [(TickerDisplayMode, width: Bool, speed: Bool)] = [
            (.scrolling, true, true), (.sparkline, true, false),
            (.focused, false, false), (.compact, false, false), (.portfolio, false, false),
        ]
        for (mode, width, speed) in expected {
            let (_, controller, content) = dropdown(mode: mode)
            XCTAssertEqual(has("widthChanged:", in: content), width, "width in \(mode)")
            XCTAssertEqual(has("speedChanged:", in: content), speed, "speed in \(mode)")
            XCTAssertTrue(has("displayModeChanged:", in: content), "mode picker always stays")
            _ = controller
        }
    }

    func testSwitchingModeInTheOpenDropdownRemovesAndRestoresScrollControls() throws {
        let (widget, controller, content) = dropdown(mode: .scrolling)
        XCTAssertTrue(has("speedChanged:", in: content))

        // Tag 4 is Folio, tag 0 is Scroll.
        func modeButton(_ tag: Int) throws -> NSButton {
            try XCTUnwrap(allViews(content).compactMap { $0 as? NSButton }.first {
                $0.action == NSSelectorFromString("displayModeChanged:") && $0.tag == tag
            })
        }
        try modeButton(4).performClick(nil)
        XCTAssertEqual(widget.config.displayMode, .portfolio)
        XCTAssertFalse(has("speedChanged:", in: content))
        XCTAssertFalse(has("widthChanged:", in: content))

        try modeButton(0).performClick(nil)
        XCTAssertEqual(widget.config.displayMode, .scrolling)
        XCTAssertTrue(has("speedChanged:", in: content))
        XCTAssertTrue(has("widthChanged:", in: content))
        _ = controller
    }

    func testRefreshIntervalChoiceIsHiddenWhileUltraFastSetsTheCadence() {
        XCTAssertTrue(has("refreshChanged:", in: dropdown(mode: .scrolling, refresh: .standard).content))
        let ultra = dropdown(mode: .scrolling, refresh: .ultraFast)
        XCTAssertFalse(has("refreshChanged:", in: ultra.content))
        XCTAssertTrue(has("refreshModeChanged:", in: ultra.content), "the way back to Standard stays")
    }
}
