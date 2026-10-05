import Cocoa

// The companion never constructs NSApplication, AppDelegate, or a status item.
if Bundle.main.object(forInfoDictionaryKey: "BAResearchHelper") as? Bool == true {
    ResearchWorkspaceService.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
