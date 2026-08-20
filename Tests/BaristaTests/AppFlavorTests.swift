import XCTest
@testable import Barista

/// Barista and Marketbar ship from one binary, so what separates them is which
/// widgets get registered. If that ever regresses, Marketbar quietly becomes the
/// full widget platform again - which is exactly what it exists not to be.
final class AppFlavorTests: XCTestCase {

    func testMarketbarRegistersOnlyTheMarketTerminal() {
        let registry = WidgetRegistry()
        registry.registerAll(for: .marketbar)
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertEqual(registry.entries.first?.widgetID, "stock-ticker")
    }

    func testBaristaRegistersTheWholePlatform() {
        let registry = WidgetRegistry()
        registry.registerAll(for: .barista)
        XCTAssertGreaterThan(registry.entries.count, 1)
        XCTAssertTrue(registry.entries.contains { $0.widgetID == "stock-ticker" },
                      "the market terminal ships in both")
    }

    func testTheTwoFlavoursNeverShareAPreferencesDomain() {
        XCTAssertNotEqual(AppFlavor.barista.defaultsSuite, AppFlavor.marketbar.defaultsSuite,
                          "a shared domain would let one app overwrite the other's portfolios")
    }

    func testMarketbarStartsWithTheTerminalAlreadyOnScreen() {
        XCTAssertEqual(AppFlavor.marketbar.defaultWidgetIDs, ["stock-ticker"])
        XCTAssertTrue(AppFlavor.barista.defaultWidgetIDs.contains("stock-ticker"))
        XCTAssertGreaterThan(AppFlavor.barista.defaultWidgetIDs.count, 1)
    }

    func testFlavourNamesAreDistinct() {
        XCTAssertEqual(AppFlavor.marketbar.displayName, "Marketbar")
        XCTAssertEqual(AppFlavor.barista.displayName, "Barista")
    }
}
