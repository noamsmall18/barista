import Cocoa

struct UptimeConfig: Codable, Equatable {
    var showLabel: Bool
    var showSeconds: Bool

    static let `default` = UptimeConfig(
        showLabel: true,
        showSeconds: false
    )
}

class UptimeWidget: BaristaWidget {
    static let widgetID = "uptime"
    static let displayName = "Uptime"
    static let subtitle = "How long since last reboot"
    static let iconName = "power"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = UptimeConfig.default

    var config: UptimeConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.showSeconds ? 1 : 60 }

    private var timer: Timer?

    required init(config: UptimeConfig) {
        self.config = config
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: config.showSeconds ? 1 : 60, repeats: true) { [weak self] _ in
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func uptime() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    private func bootTime() -> Date {
        return Date().addingTimeInterval(-uptime())
    }

    func render() -> WidgetDisplayMode {
        let up = uptime()
        let days = Int(up) / 86400
        let hours = (Int(up) % 86400) / 3600
        let mins = (Int(up) % 3600) / 60
        let secs = Int(up) % 60

        let prefix = config.showLabel ? "Up " : ""

        if days > 0 {
            return .text("\(prefix)\(days)d \(hours)h")
        } else if config.showSeconds {
            return .text("\(prefix)\(hours):\(String(format: "%02d", mins)):\(String(format: "%02d", secs))")
        } else {
            return .text("\(prefix)\(hours)h \(mins)m")
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "UPTIME", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let up = uptime()
        let days = Int(up) / 86400
        let hours = (Int(up) % 86400) / 3600
        let mins = (Int(up) % 3600) / 60
        let secs = Int(up) % 60

        let fullStr = String(format: "%dd %dh %dm %ds", days, hours, mins, secs)
        let uptimeItem = NSMenuItem(title: "Uptime: \(fullStr)", action: nil, keyEquivalent: "")
        uptimeItem.isEnabled = false
        menu.addItem(uptimeItem)

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let bootItem = NSMenuItem(title: "Boot: \(df.string(from: bootTime()))", action: nil, keyEquivalent: "")
        bootItem.isEnabled = false
        menu.addItem(bootItem)

        let ver = ProcessInfo.processInfo.operatingSystemVersionString
        let osItem = NSMenuItem(title: "macOS \(ver)", action: nil, keyEquivalent: "")
        osItem.isEnabled = false
        menu.addItem(osItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
