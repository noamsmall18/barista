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
