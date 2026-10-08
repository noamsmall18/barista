import XCTest
import Cocoa
@testable import Barista

@MainActor
final class HoldingsInputTests: XCTestCase {
    func testInvalidOrNegativeQuantitiesAreRejectedInsteadOfChangingHoldings() {
        let form = HoldingsForm(shares: 8, cost: 100)
        for invalid in ["-5", "wrong", "1.2.3", "NaN", "inf", ""] {
            form.shareField.stringValue = invalid
            XCTAssertNotNil(form.validationProblem, invalid)
        }
    }

    func testInvalidCostIsRejectedAndBlankCostKeepsExistingBasis() {
        let form = HoldingsForm(shares: 8, cost: 100)
        for invalid in ["-100", "wrong", "1.2.3", "NaN", "inf"] {
            form.costField.stringValue = invalid
            XCTAssertNotNil(form.validationProblem, invalid)
        }
        form.costField.stringValue = ""
        XCTAssertNil(form.validationProblem)
        XCTAssertNil(form.enteredCost)
    }

    func testExplicitZeroRemovesPositionAndFormattedAmountsAreAccepted() {
        let form = HoldingsForm(shares: 8, cost: 100)
        form.shareField.stringValue = "0"
        XCTAssertNil(form.validationProblem)
        XCTAssertEqual(form.enteredShares, 0)
        form.shareField.stringValue = "1,234.5"
        form.costField.stringValue = "$1,200.25"
        XCTAssertNil(form.validationProblem)
        XCTAssertEqual(form.enteredShares, 1234.5)
        XCTAssertEqual(form.enteredCost, 1200.25)
    }
}
