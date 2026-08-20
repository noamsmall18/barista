import Foundation

/// Which product this bundle is.
///
/// Barista and Marketbar ship from one codebase and one binary, distinguished by
/// the bundle they are launched from. Splitting them into separate SwiftPM
/// targets would mean moving thirty thousand lines into a shared library and
/// marking every cross-boundary type public - a large refactor for something no
/// user would ever see. The cost of doing it this way is that Marketbar's binary
/// still contains the other widgets' code; it is simply unreachable.
enum AppFlavor {
    /// The full widget platform: 52 widgets across 12 categories.
    case barista
    /// The market terminal on its own, with no other widgets.
    case marketbar

    static let current: AppFlavor = {
        // An explicit Info.plist key, so the flavour is a stated property of the
        // bundle rather than something inferred from a string that might change.
        if let raw = Bundle.main.object(forInfoDictionaryKey: "BAAppFlavor") as? String,
           raw.lowercased() == "marketbar" {
            return .marketbar
        }
        if Bundle.main.bundleIdentifier?.contains("marketbar") == true {
            return .marketbar
        }
        return .barista
    }()

    var displayName: String {
        switch self {
        case .barista:   return "Barista"
        case .marketbar: return "Marketbar"
        }
    }

    /// The preferences domain this flavour reads and writes.
    var defaultsSuite: String {
        switch self {
        case .barista:   return "com.noam.barista.app"
        case .marketbar: return "com.noam.marketbar.app"
        }
    }

    /// Marketbar starts with the market terminal already on screen; there is
    /// nothing else for it to show.
    var defaultWidgetIDs: [String] {
        switch self {
        case .barista:   return ["stock-ticker", "system-health", "today-brief", "weather-current"]
        case .marketbar: return ["stock-ticker"]
        }
    }
}
