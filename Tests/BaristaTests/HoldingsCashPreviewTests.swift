import XCTest
import Cocoa
@testable import Barista

@MainActor
final class HoldingsCashPreviewTests: XCTestCase {
    private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    private func textFields(in root: NSView) -> [NSTextField] {
        [root].compactMap { $0 as? NSTextField } + root.subviews.flatMap { textFields(in: $0) }
    }

    func testBuySellAndSetModesUpdateCashPreview() throws {
        _ = NSApplication.shared
        let form = HoldingsForm(shares: 4, cost: 12, availableCash: 100)
        XCTAssertTrue(textFields(in: form.view).contains { $0.stringValue == "Available cash (USD)  $100.00" })

        let mode = try XCTUnwrap(allViews(form.view).compactMap { $0 as? NSSegmentedControl }.first)
        mode.selectedSegment = HoldingsForm.Mode.buy.rawValue
        mode.sendAction(mode.action, to: mode.target)
        form.shareField.stringValue = "3"
        form.costField.stringValue = "20"
        form.controlTextDidChange(Notification(name: Notification.Name("HoldingsCashPreviewTest"), object: form.shareField))
        XCTAssertTrue(textFields(in: form.view).contains { $0.stringValue == "Cost $60.00 · cash after $40.00" })

        form.shareField.stringValue = "6"
        form.controlTextDidChange(Notification(name: Notification.Name("HoldingsCashPreviewTest"), object: form.shareField))
        XCTAssertNil(form.validationProblem, "cash shortfall is confirmed by the dialog and may be overridden")
        XCTAssertTrue(textFields(in: form.view).contains {
            $0.stringValue == "Cash after -$20.00 · short $20.00"
        })

        mode.selectedSegment = HoldingsForm.Mode.sell.rawValue
        mode.sendAction(mode.action, to: mode.target)
        form.shareField.stringValue = "2"
        form.costField.stringValue = "15"
        form.controlTextDidChange(Notification(name: Notification.Name("HoldingsCashPreviewTest"), object: form.costField))
        XCTAssertTrue(textFields(in: form.view).contains { $0.stringValue == "Proceeds $30.00 · cash after $130.00" })

        mode.selectedSegment = HoldingsForm.Mode.set.rawValue
        mode.sendAction(mode.action, to: mode.target)
        XCTAssertTrue(textFields(in: form.view).contains {
            $0.stringValue == "Manual correction · cash unchanged · no trade logged"
        })
    }

    func testForeignQuoteDoesNotCompareItsTradeValueToUSDPortfolioCash() throws {
        _ = NSApplication.shared
        let form = HoldingsForm(shares: 0, cost: nil, availableCash: 100, quoteCurrency: "EUR")
        let mode = try XCTUnwrap(allViews(form.view).compactMap { $0 as? NSSegmentedControl }.first)
        mode.selectedSegment = HoldingsForm.Mode.buy.rawValue
        mode.sendAction(mode.action, to: mode.target)
        form.shareField.stringValue = "2"
        form.costField.stringValue = "15"
        form.controlTextDidChange(Notification(name: Notification.Name("HoldingsCashPreviewTest"), object: form.costField))

        XCTAssertTrue(textFields(in: form.view).contains { $0.stringValue == "Quote is in EUR · portfolio cash is USD" })
        XCTAssertFalse(textFields(in: form.view).contains { $0.stringValue.contains("cash after") })
    }
}
