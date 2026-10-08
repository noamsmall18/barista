import Foundation

/// A downloaded or leftover build must never become a second native app.
/// Redirect before app startup can touch preferences. Installation is explicit;
/// the running app never copies itself into another folder.
enum NativeAppInstallation {
    enum LaunchAction: Equatable {
        case run
        case openInstalled(URL)
        case needsInstallation(URL)
    }

    static func canonicalURL(for flavor: AppFlavor) -> URL {
        URL(fileURLWithPath: "/Applications/\(flavor.displayName).app", isDirectory: true)
    }

    static func launchAction(for flavor: AppFlavor, bundleURL: URL,
                             installedBundleIdentifier: String?) -> LaunchAction {
        // Raw Swift executables and test runners aren't installed applications.
        guard bundleURL.pathExtension == "app" else { return .run }
        let canonical = canonicalURL(for: flavor)
        if bundleURL.resolvingSymlinksInPath().standardizedFileURL == canonical.resolvingSymlinksInPath().standardizedFileURL {
            return .run
        }
        if installedBundleIdentifier == flavor.defaultsSuite { return .openInstalled(canonical) }
        return .needsInstallation(canonical)
    }
}
