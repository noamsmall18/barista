import Cocoa

struct ScreenTimeConfig: Codable, Equatable {
    var showLabel: Bool

    static let `default` = ScreenTimeConfig(showLabel: true)
}

class ScreenTimeWidget: BaristaWidget {
    static let widgetID = "screen-time"
    static let displayName = "Screen Time"
    static let subtitle = "How long you've been on your Mac today"
    static let iconName = "desktopcomputer"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = ScreenTimeConfig.default

    var config: ScreenTimeConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?
    private var sessionStart: Date = Date()
    private(set) var totalActiveMinutes: Int = 0
    private var lastCheckTime: Date = Date()
    private var wasIdle: Bool = false
    private var currentDay: Int = 0

    required init(config: ScreenTimeConfig) {
        self.config = config
    }

    func start() {
        // Track from when we started today
        let now = Date()
        sessionStart = now
        lastCheckTime = now
        totalActiveMinutes = 0

        // Check boot time for a rough "time on Mac today"
        let uptime = ProcessInfo.processInfo.systemUptime
        let bootTime = Date(timeIntervalSinceNow: -uptime)
        let todayStart = Calendar.current.startOfDay(for: now)

        // If booted today, use time since boot. Otherwise use time since midnight.
        if bootTime > todayStart {
            totalActiveMinutes = Int(uptime / 60)
        } else {
            totalActiveMinutes = Int(now.timeIntervalSince(todayStart) / 60)
        }
        currentDay = Calendar.current.ordinality(of: .day, in: .year, for: now) ?? 0

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateTime()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTime() {
        // Reset at midnight
        let today = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        if today != currentDay {
            currentDay = today
            totalActiveMinutes = 0
            return
        }
        totalActiveMinutes += 1
    }

    private var formattedTime: String {
        let h = totalActiveMinutes / 60
        let m = totalActiveMinutes % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }

    func render() -> WidgetDisplayMode {
        let time = formattedTime
        if config.showLabel {
            return .text("\u{1F4BB} \(time)")
        }
        return .text(time)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "SCREEN TIME", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let timeItem = NSMenuItem(title: "Active today: \(formattedTime)", action: nil, keyEquivalent: "")
        timeItem.isEnabled = false
        menu.addItem(timeItem)

        let uptime = ProcessInfo.processInfo.systemUptime
        let uptimeH = Int(uptime / 3600)
        let uptimeM = Int(uptime.truncatingRemainder(dividingBy: 3600) / 60)
        let uptimeItem = NSMenuItem(title: "System uptime: \(uptimeH)h \(uptimeM)m", action: nil, keyEquivalent: "")
        uptimeItem.isEnabled = false
        menu.addItem(uptimeItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
