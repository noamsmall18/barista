import Cocoa

if Bundle.main.object(forInfoDictionaryKey: "BAResearchHelper") as? Bool == true {
    ResearchWorkspaceService.run()
} else {
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
