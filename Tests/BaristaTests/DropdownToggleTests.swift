import XCTest
import Cocoa
@testable import Barista

@MainActor
final class DropdownToggleTests: XCTestCase {
    func testStatusButtonMouseDownThenToggleClosesDropdownAndNextClickReopensIt() throws {
        _ = NSApplication.shared
        let widget = StockTickerWidget(
            config: StockTickerConfig(symbols: ["AAPL"], coins: [], holdings: ["AAPL": 2], cash: 100),
            notificationsEnabled: false,
            initialQuotes: [MarketQuote(symbol: "AAPL", price: 225, change: 1, kind: .stock, sparkline: [])]
        )
        widget.config.displayMode = .portfolio
        let instance = WidgetInstance(id: UUID(), widgetID: "stock-ticker", widget: AnyBaristaWidget(widget), order: 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        instance.statusItem = item
        defer { instance.deactivate() }
        widget.onDisplayUpdate = { [weak instance] in instance?.updateStatusItem() }
        instance.updateStatusItem()
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let buttonCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        let before = button.attributedTitle.string

        instance.showDropdownMenu()
        let dropdown = try XCTUnwrap(instance.popoverController)
        XCTAssertTrue(dropdown.isShown)
        widget.setCash(500)
        XCTAssertEqual(button.attributedTitle.string, before, "updates stay deferred while the dropdown is open")

        // macOS can report the status-item mouse-down to the global monitor
        // before forwarding the mouse-up action to the button's toggle.
        dropdown.dismissIfOutside(at: buttonCenter)
        XCTAssertTrue(dropdown.isShown, "the anchor's mouse-down belongs to the button's toggle")
        instance.showDropdownMenu()
        XCTAssertFalse(dropdown.isShown, "the closing click must not reopen the dropdown")
        XCTAssertNotEqual(button.attributedTitle.string, before, "closing through the button flushes deferred redraws")

        instance.showDropdownMenu()
        XCTAssertTrue(dropdown.isShown, "a subsequent click must still open the dropdown")
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is StatusDropdownPanel && $0.isVisible })
        dropdown.dismissIfOutside(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        XCTAssertTrue(dropdown.isShown, "clicking inside the dropdown must leave it open")
        dropdown.dismissIfOutside(at: NSPoint(x: panel.frame.minX - 20, y: panel.frame.minY - 20))
        XCTAssertFalse(dropdown.isShown, "clicking elsewhere must still dismiss it")
    }
}
