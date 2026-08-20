import XCTest
@testable import Barista

/// Redraws of the menu bar are suppressed while a popover is open, because
/// mutating the status-item button dismisses a transient NSPopover. They used to
/// be *discarded* rather than deferred, and nothing redrew on close, so an edit
/// made in the dropdown did not reach the menu bar until the next refresh tick -
/// up to five minutes when the market is closed.
final class MenuBarRefreshTests: XCTestCase {

    // MARK: The deferral itself

    func testARedrawRequestedWhileSuppressedIsRemembered() {
        var pending = DeferredRedraw()
        XCTAssertFalse(pending.isPending)
        pending.request()
        XCTAssertTrue(pending.isPending, "a suppressed redraw must not be thrown away")
    }

    func testTakingThePendingRedrawClearsIt() {
        var pending = DeferredRedraw()
        pending.request()
        XCTAssertTrue(pending.take(), "the deferred redraw must be handed back once")
        XCTAssertFalse(pending.isPending)
        XCTAssertFalse(pending.take(), "and not a second time")
    }

    func testRepeatedRequestsCoalesceIntoOne() {
        var pending = DeferredRedraw()
        pending.request(); pending.request(); pending.request()
        XCTAssertTrue(pending.take())
        XCTAssertFalse(pending.take(), "ten refreshes while open still mean one redraw after")
    }

    func testNothingPendingMeansNoRedraw() {
        var pending = DeferredRedraw()
        XCTAssertFalse(pending.take())
    }

    // MARK: The close hook every dismissal path funnels through

    @MainActor
    func testDismissNotifiesSoTheMenuBarCanCatchUp() {
        let controller = PopoverController()
        var closed = 0
        controller.onDismiss = { closed += 1 }
        controller.dismiss()
        XCTAssertEqual(closed, 1,
                       "click-outside, Escape, deactivate and toggle all route through dismiss()")
    }
}
