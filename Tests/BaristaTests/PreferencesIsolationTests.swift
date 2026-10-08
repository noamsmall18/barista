import XCTest
@testable import Barista

final class PreferencesIsolationTests: XCTestCase {
    func testTestProcessUsesSeparatePreferencesForPortfoliosAndHistory() throws {
        XCTAssertTrue(AppPreferences.isRunningTests)
        XCTAssertFalse(AppPreferences.shared === UserDefaults.standard)
        XCTAssertTrue(AppPreferences.shared is InMemoryTestPreferences)
        XCTAssertTrue(ResearchWorkspaceDefaults.shared === AppPreferences.shared)
        XCTAssertNotEqual(AppPreferences.testSuiteName, AppFlavor.barista.defaultsSuite)
        XCTAssertNotEqual(AppPreferences.testSuiteName, AppFlavor.marketbar.defaultsSuite)
        let id = UUID()
        let data = try JSONEncoder().encode(StockTickerConfig(symbols: [], coins: [], cash: 123))
        WidgetStore.shared.save([SavedWidget(instanceID: id, widgetID: "stock-ticker", order: 0,
                                             configData: data, isEnabled: true)])
        let stored = try XCTUnwrap(AppPreferences.shared.data(forKey: "barista.activeWidgets"))
        XCTAssertEqual(try JSONDecoder().decode([SavedWidget].self, from: stored).first?.instanceID, id)
        XCTAssertEqual(ResearchWorkspaceService.configuration().cash, 123)
        let diskReader = try XCTUnwrap(UserDefaults(suiteName: AppPreferences.testSuiteName))
        XCTAssertNil(diskReader.data(forKey: "barista.activeWidgets"), "Test portfolio writes must remain entirely in memory")
        AppPreferences.shared.removeObject(forKey: "barista.activeWidgets")
        XCTAssertFalse(FlavorMigration.importFromBaristaIfNeeded(flavor: .marketbar))
    }
}
