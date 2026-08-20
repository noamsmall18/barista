import Foundation

/// Brings a user's existing setup across the first time Marketbar runs.
///
/// Marketbar has its own bundle identifier, so it has its own preferences
/// domain and would otherwise open with no portfolios, no cost basis and no
/// history. Barista's copy is only ever read, never modified, so both apps keep
/// working and nothing can be lost by trying.
enum FlavorMigration {

    /// Keys worth carrying over. Layout and appearance come too, so the app does
    /// not look factory-fresh, but widgets Marketbar does not register are
    /// filtered out by WidgetStore on load.
    private static let keys = [
        "barista.activeWidgets",
        "barista.widgetMemory",
        "barista.portfolioHistory",
        "barista.stockTicker.lastGoodQuotes",
        "barista.stockTicker.earningsNotified",
        "barista.benchmarkCloses",
        "barista.earningsCalendar",
        "barista.earningsCalendar.date",
        "barista.menuBarAppearance",
        "barista.hasLaunched",
    ]

    private static let importedFlag = "barista.importedFromBarista"

    /// Copies Barista's settings across, once, on Marketbar's first launch.
    /// Returns true if anything was imported.
    @discardableResult
    static func importFromBaristaIfNeeded(flavor: AppFlavor = .current) -> Bool {
        guard flavor == .marketbar else { return false }

        let ours = UserDefaults.standard
        // Already done, or the user has been using Marketbar on its own. Either
        // way, importing now would overwrite real work.
        guard !ours.bool(forKey: importedFlag) else { return false }
        guard ours.data(forKey: "barista.activeWidgets") == nil else {
            ours.set(true, forKey: importedFlag)
            return false
        }

        guard let theirs = UserDefaults(suiteName: AppFlavor.barista.defaultsSuite) else {
            return false
        }

        var imported = 0
        for key in keys {
            guard let value = theirs.object(forKey: key) else { continue }
            ours.set(value, forKey: key)
            imported += 1
        }

        ours.set(true, forKey: importedFlag)
        if imported > 0 {
            NSLog("Marketbar: imported \(imported) settings from Barista, including portfolios and history")
        }
        return imported > 0
    }
}
