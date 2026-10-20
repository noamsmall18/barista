import XCTest
import Cocoa
@testable import Barista

@MainActor
final class DropdownToggleTests: XCTestCase {
    private func fixture() -> WidgetInstance {
        _ = NSApplication.shared
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["AAPL", "MSFT"], coins: []), notificationsEnabled: false,
            initialQuotes: [MarketQuote(symbol: "AAPL", price: 225, change: 1, kind: .stock, sparkline: []),
                            MarketQuote(symbol: "MSFT", price: 400, change: 1, kind: .stock, sparkline: [])])
        let instance = WidgetInstance(id: UUID(), widgetID: "stock-ticker", widget: AnyBaristaWidget(widget), order: 0)
        instance.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        instance.updateStatusItem()
        return instance
    }

    private final class MouseRelease: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    /// Run the real AppKit cell tracking and registered target/action. No events
    /// are posted to another process, and no installed app or saved data is used.
    private func nativeClick(_ instance: WidgetInstance, modifiers: NSEvent.ModifierFlags = [],
                             beforeRelease: (() -> Void)? = nil) throws {
        let button = try XCTUnwrap(instance.statusItem?.button)
        let window = try XCTUnwrap(button.window)
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: modifiers,
            timestamp: timestamp, windowNumber: window.windowNumber,
            context: nil, eventNumber: 42, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: modifiers,
            timestamp: timestamp + 0.001, windowNumber: window.windowNumber,
            context: nil, eventNumber: 43, clickCount: 1, pressure: 0))
        let releaser = MouseRelease {
            beforeRelease?()
            NSApp.postEvent(up, atStart: true)
        }
        let release = Timer(timeInterval: 0.02, target: releaser, selector: #selector(MouseRelease.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(release, forMode: .eventTracking)
        RunLoop.main.add(release, forMode: .default)
        defer { release.invalidate() }
        NSApp.postEvent(down, atStart: true)
        let next = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown,
            until: Date().addingTimeInterval(1), inMode: .default, dequeue: true))
        XCTAssertTrue(try XCTUnwrap(button.cell).trackMouse(with: next, in: button.bounds, of: button, untilMouseUp: true))
        // A mouse-down action may end AppKit's tracking immediately. Still
        // deliver the release, including any dismissal scheduled before it.
        let deadline = Date().addingTimeInterval(1)
        while release.isValid, Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        XCTAssertFalse(release.isValid, "every native press must receive its release")
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    func testNativePressClosesOnMouseDownAndReleaseCannotReopenIt() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        try nativeClick(instance)
        XCTAssertTrue(instance.popoverController?.isShown == true)
        var checkedBeforeRelease = false
        try nativeClick(instance) {
            checkedBeforeRelease = true
            XCTAssertFalse(instance.popoverController?.isShown == true, "closing must finish on press, before mouse-up")
            // Reproduce a dismissal arriving before the old mouse-up action.
            instance.popoverController?.dismiss()
        }
        XCTAssertTrue(checkedBeforeRelease)
        XCTAssertFalse(instance.popoverController?.isShown == true, "release must never reopen a dropdown dismissed during this press")
        try nativeClick(instance)
        XCTAssertTrue(instance.popoverController?.isShown == true, "the next independent click still opens it")
    }

    func testRapidNativeClicksToggleOncePerPressWhileStatusUpdatesAreDeferred() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        let widget = try XCTUnwrap(instance.widget.underlying(as: StockTickerWidget.self))
        for mode in [TickerDisplayMode.scrolling, .compact, .focused, .sparkline, .portfolio] {
            widget.config.displayMode = mode
            instance.updateStatusItem()
            for index in 0..<20 {
                let shouldOpen = index.isMultiple(of: 2)
                try nativeClick(instance) {
                    XCTAssertEqual(instance.popoverController?.isShown == true, shouldOpen, "\(mode) press \(index) must toggle before release")
                    instance.updateStatusItem()
                }
                XCTAssertEqual(instance.popoverController?.isShown == true, shouldOpen, "\(mode) press \(index) must toggle exactly once")
            }
        }
    }

    func testOptionClickStillCyclesWithoutOpeningDropdown() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        instance.widget.underlying(as: StockTickerWidget.self)?.config.displayMode = .focused
        instance.updateStatusItem()
        let before = instance.widget.currentIndex
        try nativeClick(instance, modifiers: .option)
        XCTAssertNotEqual(instance.widget.currentIndex, before)
        XCTAssertFalse(instance.popoverController?.isShown == true)
    }

    private func forwardAction(_ instance: WidgetInstance, type: NSEvent.EventType = .leftMouseDown,
                               location: NSPoint? = nil, beforeAction: ((NSEvent) -> Void)? = nil,
                               deliveries: Int = 1) throws {
        let button = try XCTUnwrap(instance.statusItem?.button)
        let window = try XCTUnwrap(button.window)
        let point = location ?? button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 44, clickCount: 1, pressure: 1))
        NSApp.postEvent(event, atStart: true)
        let next = try XCTUnwrap(NSApp.nextEvent(matching: NSEvent.EventTypeMask(rawValue: 1 << type.rawValue),
            until: Date().addingTimeInterval(1), inMode: .default, dequeue: true))
        beforeAction?(next)
        // Dispatch can enter AppKit tracking and advance currentEvent to the
        // release. A forwarded action still belongs to the original press.
        if NSApp.currentEvent !== next {
            NSApp.postEvent(next, atStart: true)
            _ = NSApp.nextEvent(matching: NSEvent.EventTypeMask(rawValue: 1 << type.rawValue),
                               until: .distantPast, inMode: .default, dequeue: true)
        }
        for _ in 0..<deliveries { XCTAssertTrue(button.sendAction(button.action, to: button.target)) }
    }

    func testDuplicateForwardedPressAndLateReleaseCannotToggleTwice() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        try forwardAction(instance, deliveries: 2)
        XCTAssertTrue(instance.popoverController?.isShown == true)
        try forwardAction(instance, deliveries: 2)
        XCTAssertFalse(instance.popoverController?.isShown == true)
        try forwardAction(instance, type: .leftMouseUp)
        XCTAssertFalse(instance.popoverController?.isShown == true, "a stray mouse-up cannot reopen it")
        try nativeClick(instance)
        XCTAssertTrue(instance.popoverController?.isShown == true, "new presses must not be swallowed by a time-based debounce")
    }

    func testOutsideDismissalBeforeForwardedActionCannotReopenSamePress() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        try nativeClick(instance)
        let dropdown = try XCTUnwrap(instance.popoverController)
        XCTAssertTrue(dropdown.isShown)
        // Cover monitor-first delivery when status-item geometry has moved by
        // the time macOS forwards this press to the registered target.
        try forwardAction(instance, location: NSPoint(x: -100000, y: -100000), beforeAction: { event in
            dropdown.handleGlobalMouseDown(event)
            XCTAssertFalse(dropdown.isShown)
        })
        XCTAssertFalse(dropdown.isShown, "the forwarded action belongs to the dismissal that already happened")
        try nativeClick(instance)
        XCTAssertTrue(dropdown.isShown)
    }

    func testControlAndRightClickStillToggleAndRightReleaseDoesNotReopen() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        try nativeClick(instance, modifiers: .control)
        XCTAssertTrue(instance.popoverController?.isShown == true)
        try nativeClick(instance, modifiers: .control)
        XCTAssertFalse(instance.popoverController?.isShown == true)
        try forwardAction(instance, type: .rightMouseDown)
        XCTAssertTrue(instance.popoverController?.isShown == true)
        try forwardAction(instance, type: .rightMouseDown)
        XCTAssertFalse(instance.popoverController?.isShown == true)
        try forwardAction(instance, type: .rightMouseUp)
        XCTAssertFalse(instance.popoverController?.isShown == true)
    }

    func testInstalledLocalMonitorAndForwardedStatusActionCloseExactlyOnce() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        instance.showDropdownMenu()
        let dropdown = try XCTUnwrap(instance.popoverController)
        let originalDismiss = dropdown.onDismiss
        var dismissals = 0
        dropdown.onDismiss = { dismissals += 1; originalDismiss?() }
        try forwardAction(instance, beforeAction: { event in
            // Run the real installed local monitor and status-window dispatch,
            // followed by the system's forwarded target/action for this press.
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow, modifierFlags: [],
                timestamp: event.timestamp + 0.001, windowNumber: event.windowNumber,
                context: nil, eventNumber: 46, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(event)
        })
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(up)
        }
        XCTAssertFalse(dropdown.isShown)
        XCTAssertEqual(dismissals, 1)
        try nativeClick(instance)
        XCTAssertTrue(dropdown.isShown)
    }

    func testInstalledLocalMonitorDismissesAnotherWindowAndAllowsNextPress() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        instance.showDropdownMenu()
        let dropdown = try XCTUnwrap(instance.popoverController)
        let other = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 200, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.level = .normal
        other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        other.orderFront(nil)
        defer { other.orderOut(nil); other.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 100, y: 60), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: other.windowNumber, context: nil, eventNumber: 45, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
        XCTAssertFalse(dropdown.isShown, "the installed outside-click monitor must dismiss a different app window")
        try nativeClick(instance)
        XCTAssertTrue(dropdown.isShown)
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is StatusDropdownPanel && $0.isVisible })
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        XCTAssertFalse(dropdown.isShown, "Escape must continue to dismiss through the installed key monitor")
    }

    func testGlobalMouseDownUsesEventPositionEvenIfPointerHasMoved() throws {
        let instance = fixture()
        defer { instance.deactivate() }
        instance.showDropdownMenu()
        let dropdown = try XCTUnwrap(instance.popoverController)
        let button = try XCTUnwrap(instance.statusItem?.button)
        let window = try XCTUnwrap(button.window)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let onButton = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: anchor.midX, y: anchor.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: -100000, y: -100000), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1))
        dropdown.handleGlobalMouseDown(onButton)
        XCTAssertTrue(dropdown.isShown, "a delayed anchor event must not be classified using the current pointer position")
        dropdown.handleGlobalMouseDown(outside)
        XCTAssertFalse(dropdown.isShown, "an outside event must dismiss even when the pointer has since moved inside")
    }

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
