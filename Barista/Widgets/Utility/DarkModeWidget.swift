import Cocoa

struct DarkModeConfig: Codable, Equatable {
    var showLabel: Bool

    static let `default` = DarkModeConfig(showLabel: true)
}

class DarkModeWidget: BaristaWidget {
    static let widgetID = "dark-mode-toggle"
    static let displayName = "Dark Mode Toggle"
    static let subtitle = "One-click appearance switch"
    static let iconName = "circle.lefthalf.filled"
    static let category = WidgetCategory.utility
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = DarkModeConfig.default

    var config: DarkModeConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 5 }

    private var timer: Timer?
    private(set) var isDarkMode = false

    required init(config: DarkModeConfig) {
        self.config = config
    }

    func start() {
        checkAppearance()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkAppearance()
        }

        // Also observe appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func appearanceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkAppearance()
            self?.onDisplayUpdate?()
        }
    }

    private func checkAppearance() {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        isDarkMode = style?.lowercased() == "dark"
        onDisplayUpdate?()
    }

    // MARK: - Toggle

    private func toggleDarkMode() {
        let script: String
        if isDarkMode {
            script = "tell application \"System Events\" to tell appearance preferences to set dark mode to false"
        } else {
            script = "tell application \"System Events\" to tell appearance preferences to set dark mode to true"
        }

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                isDarkMode.toggle()
                onDisplayUpdate?()
            }
        }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        let icon = isDarkMode ? "\u{1F319}" : "\u{2600}\u{FE0F}"
        if config.showLabel {
            let label = isDarkMode ? "Dark" : "Light"
            return .text("\(icon) \(label)")
        }
        return .text(icon)
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "APPEARANCE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let current = NSMenuItem(title: "Current: \(isDarkMode ? "Dark Mode" : "Light Mode")", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)

        menu.addItem(NSMenuItem.separator())

        let toggleLabel = isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"
        let toggleItem = NSMenuItem(title: toggleLabel, action: #selector(doToggle), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func doToggle() {
        toggleDarkMode()
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
