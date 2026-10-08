import Foundation

/// A helper has its own bundle identity, but reads and writes the owning
/// product's persisted data explicitly. It never impersonates the app in macOS.
enum ResearchWorkspaceDefaults {
    static let shared: UserDefaults = {
        if AppPreferences.isRunningTests { return AppPreferences.shared }
        guard Bundle.main.object(forInfoDictionaryKey: "BAResearchHelper") as? Bool == true,
              let suite = Bundle.main.object(forInfoDictionaryKey: "BAResearchDefaultsSuite") as? String,
              let defaults = UserDefaults(suiteName: suite) else { return AppPreferences.shared }
        return defaults
    }()
}
