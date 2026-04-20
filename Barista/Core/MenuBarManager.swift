import Cocoa
import ApplicationServices

struct MenuBarItem: Identifiable, Equatable {
    let id: String           // unique key: "bundleID:title" or pid-based
    let title: String
    let bundleID: String?
    let appName: String
    let pid: pid_t
    let element: AXUIElement
    var isHidden: Bool = false

    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.id == rhs.id
    }
}

class MenuBarManager {
    static let shared = MenuBarManager()

    private(set) var detectedItems: [MenuBarItem] = []
    private var hiddenItemIDs: Set<String> = []
    private var coverWindows: [String: NSWindow] = [:]
    private let hiddenKey = "barista.hiddenMenuBarItems"

    // Our own bundle ID to exclude from detection
    private let selfBundleID = Bundle.main.bundleIdentifier ?? "com.noam.barista"

    init() {
        loadHiddenItems()
    }

    // MARK: - Accessibility Check

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Detection

    func detectMenuBarItems() {
        guard MenuBarManager.hasAccessibilityPermission else { return }

        var newItems: [MenuBarItem] = []

        // Get all running apps
        let apps = NSWorkspace.shared.runningApplications

        for app in apps {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != selfBundleID,
                  app.activationPolicy == .regular || app.activationPolicy == .accessory
            else { continue }

            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            // Get the menu bar extras (status items) for this app
            var extrasValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasValue)

            if result == .success, let extrasBar = extrasValue {
                var children: AnyObject?
                if AXUIElementCopyAttributeValue(extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                   let items = children as? [AXUIElement] {
                    for item in items {
                        var titleValue: AnyObject?
                        var title = ""
                        if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleValue) == .success {
                            title = titleValue as? String ?? ""
                        }
                        if title.isEmpty {
                            AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &titleValue)
                            title = (titleValue as? String) ?? ""
                        }

                        let appName = app.localizedName ?? bundleID
                        let itemID = "\(bundleID):\(title.isEmpty ? "\(pid)" : title)"

                        var menuItem = MenuBarItem(
                            id: itemID,
                            title: title.isEmpty ? appName : title,
                            bundleID: bundleID,
                            appName: appName,
                            pid: pid,
                            element: item
                        )
                        menuItem.isHidden = hiddenItemIDs.contains(itemID)
                        newItems.append(menuItem)
                    }
                }
            }

            // Also check regular menu bar
            var menuBarValue: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success {
                // We mainly care about extras (status items), not app menus
            }
        }

        // Also detect SystemUIServer items (WiFi, Bluetooth, Battery, Clock, etc.)
        let systemApps = apps.filter {
            $0.bundleIdentifier == "com.apple.systemuiserver" ||
            $0.bundleIdentifier == "com.apple.controlcenter"
        }

        for app in systemApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            let bundleID = app.bundleIdentifier ?? "system"

            var extrasValue: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasValue) == .success,
               let extrasBar = extrasValue as! AXUIElement? {
                var children: AnyObject?
                if AXUIElementCopyAttributeValue(extrasBar, kAXChildrenAttribute as CFString, &children) == .success,
                   let items = children as? [AXUIElement] {
                    for item in items {
                        var titleValue: AnyObject?
                        var title = ""
                        if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleValue) == .success {
                            title = titleValue as? String ?? ""
                        }
                        if title.isEmpty {
                            AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &titleValue)
                            title = (titleValue as? String) ?? ""
                        }
                        if title.isEmpty { continue }

                        let appName = app.localizedName ?? "System"
                        let itemID = "\(bundleID):\(title)"

                        var menuItem = MenuBarItem(
                            id: itemID,
                            title: title,
                            bundleID: bundleID,
                            appName: appName,
                            pid: pid,
                            element: item
                        )
                        menuItem.isHidden = hiddenItemIDs.contains(itemID)
                        newItems.append(menuItem)
                    }
                }
            }
        }

        detectedItems = newItems
    }

    // MARK: - Hide / Show

    func hideItem(_ item: MenuBarItem) {
        hiddenItemIDs.insert(item.id)
        saveHiddenItems()

        // Get the item's position and cover it with an invisible window
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(item.element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(item.element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // Create a cover window at the menu bar level
        // Convert from screen coordinates (top-left origin) to Cocoa (bottom-left)
        if let screen = NSScreen.main {
            let cocoaY = screen.frame.height - pos.y - size.height
            let window = NSWindow(
                contentRect: NSRect(x: pos.x, y: cocoaY, width: size.width, height: size.height),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            window.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.17, alpha: 1.0)
            window.isOpaque = true
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.orderFront(nil)

            coverWindows[item.id] = window
        }

        if let idx = detectedItems.firstIndex(where: { $0.id == item.id }) {
            detectedItems[idx].isHidden = true
        }
    }

    func showItem(_ item: MenuBarItem) {
        hiddenItemIDs.remove(item.id)
        saveHiddenItems()

        // Remove the cover window
        if let window = coverWindows[item.id] {
            window.orderOut(nil)
            coverWindows.removeValue(forKey: item.id)
        }

        if let idx = detectedItems.firstIndex(where: { $0.id == item.id }) {
            detectedItems[idx].isHidden = false
        }
    }

    func toggleItem(_ item: MenuBarItem) {
        if item.isHidden {
            showItem(item)
        } else {
            hideItem(item)
        }
    }

    func showAllHidden() {
        for item in detectedItems where item.isHidden {
            showItem(item)
        }
    }

    func reapplyHidden() {
        detectMenuBarItems()
        for item in detectedItems where hiddenItemIDs.contains(item.id) {
            hideItem(item)
        }
    }

    // MARK: - Persistence

    private func loadHiddenItems() {
        if let saved = UserDefaults.standard.stringArray(forKey: hiddenKey) {
            hiddenItemIDs = Set(saved)
        }
    }

    private func saveHiddenItems() {
        UserDefaults.standard.set(Array(hiddenItemIDs), forKey: hiddenKey)
    }

    // MARK: - Auto-Hide Timer

    private var autoHideTimer: Timer?
    private var autoHideInterval: TimeInterval = 0  // 0 = disabled

    /// Set auto-hide: hidden items briefly reappear then hide again after `seconds`.
    func setAutoHide(interval: TimeInterval) {
        autoHideInterval = interval
        UserDefaults.standard.set(interval, forKey: "barista.autoHideInterval")
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    /// Temporarily reveal all hidden items, then re-hide after the configured interval.
    func temporaryReveal() {
        showAllHidden()
        guard autoHideInterval > 0 else { return }
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: autoHideInterval, repeats: false) { [weak self] _ in
            self?.reapplyHidden()
        }
    }

    func loadAutoHideInterval() {
        autoHideInterval = UserDefaults.standard.double(forKey: "barista.autoHideInterval")
    }

    // MARK: - Hover-to-Reveal

    private var hoverMonitor: Any?
    private var isHoverRevealed = false
    private var hoverHideTimer: Timer?

    /// Enable hover-to-reveal: when mouse enters the menu bar area, temporarily show hidden items.
    func enableHoverReveal() {
        disableHoverReveal()
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove(event)
        }
        UserDefaults.standard.set(true, forKey: "barista.hoverReveal")
    }

    func disableHoverReveal() {
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
        }
        isHoverRevealed = false
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
        UserDefaults.standard.set(false, forKey: "barista.hoverReveal")
    }

    var isHoverRevealEnabled: Bool {
        UserDefaults.standard.bool(forKey: "barista.hoverReveal")
    }

    private func handleMouseMove(_ event: NSEvent) {
        guard let screen = NSScreen.main else { return }
        let mouseY = event.locationInWindow.y
        let screenHeight = screen.frame.height
        let menuBarHeight = screenHeight - screen.visibleFrame.height - screen.visibleFrame.origin.y + screen.frame.origin.y

        // Mouse is in the menu bar area (top of screen)
        let inMenuBar = mouseY >= screenHeight - menuBarHeight - 5

        if inMenuBar && !isHoverRevealed && hiddenCount > 0 {
            isHoverRevealed = true
            showAllHidden()
            hoverHideTimer?.invalidate()
        } else if !inMenuBar && isHoverRevealed {
            // Delay before re-hiding
            hoverHideTimer?.invalidate()
            hoverHideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.isHoverRevealed = false
                self?.reapplyHidden()
            }
        }
    }

    // MARK: - Stats

    var hiddenCount: Int { hiddenItemIDs.count }
    var visibleCount: Int { detectedItems.count - detectedItems.filter(\.isHidden).count }
    var totalCount: Int { detectedItems.count }
}
