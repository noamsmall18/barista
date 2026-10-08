import Cocoa

if AppPreferences.isRunningTests {
    // XCTest imports this executable target; it must never start the real app.
} else if Bundle.main.object(forInfoDictionaryKey: "BAResearchHelper") as? Bool == true {
    ResearchWorkspaceService.run()
} else {
    let canonical = NativeAppInstallation.canonicalURL(for: AppFlavor.current)
    switch NativeAppInstallation.launchAction(for: AppFlavor.current, bundleURL: Bundle.main.bundleURL,
                                             installedBundleIdentifier: Bundle(url: canonical)?.bundleIdentifier) {
    case .run:
        break
    case .openInstalled(let url):
        exit(NSWorkspace.shared.open(url) ? 0 : 1)
    case .needsInstallation(let url):
        let alert = NSAlert()
        alert.messageText = "Install \(AppFlavor.current.displayName) in Applications"
        alert.informativeText = "Keep one app at \(url.path). Install or update that copy before opening \(AppFlavor.current.displayName)."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }
    do {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent(AppFlavor.current.displayName + "/App", isDirectory: true)
        guard let instance = try AppInstanceLock(directory: directory) else {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("MarketbarShowSettings"), object: AppFlavor.current.defaultsSuite,
                userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(instance) { app.run() }
    } catch {
        let alert = NSAlert()
        alert.messageText = "Couldn't start " + AppFlavor.current.displayName
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
