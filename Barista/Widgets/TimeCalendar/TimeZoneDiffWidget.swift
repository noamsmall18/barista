import Cocoa

struct TimeZoneDiffConfig: Codable, Equatable {
    var targetTimeZone: String
    var label: String
    var use24Hour: Bool

    static let `default` = TimeZoneDiffConfig(
        targetTimeZone: "Asia/Tokyo",
        label: "Tokyo",
        use24Hour: false
    )
}

class TimeZoneDiffWidget: BaristaWidget {
    static let widgetID = "tz-diff"
    static let displayName = "Time Zone Diff"
    static let subtitle = "Time difference to another city"
    static let iconName = "globe"
    static let category = WidgetCategory.timeCalendar
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = TimeZoneDiffConfig.default

    var config: TimeZoneDiffConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?

    required init(config: TimeZoneDiffConfig) {
        self.config = config
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func render() -> WidgetDisplayMode {
        guard let tz = TimeZone(identifier: config.targetTimeZone) else {
            return .text("\(config.label): ?")
        }

        let now = Date()
        let localOffset = TimeZone.current.secondsFromGMT(for: now)
        let targetOffset = tz.secondsFromGMT(for: now)
        let diffSeconds = targetOffset - localOffset
        let diffHours = diffSeconds / 3600
        let diffMins = abs(diffSeconds % 3600) / 60
        let sign = diffHours >= 0 ? "+" : ""

        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.dateFormat = config.use24Hour ? "HH:mm" : "h:mm a"
        let timeStr = formatter.string(from: now)

        let offsetStr = diffMins > 0 ? "\(sign)\(diffHours):\(String(format: "%02d", diffMins))" : "\(sign)\(diffHours)h"
        return .text("\(config.label) \(offsetStr) (\(timeStr))")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "TIME ZONE DIFF", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let now = Date()

        if let tz = TimeZone(identifier: config.targetTimeZone) {
            let localOffset = TimeZone.current.secondsFromGMT(for: now)
            let targetOffset = tz.secondsFromGMT(for: now)
            let diffSeconds = targetOffset - localOffset
            let diffHours = diffSeconds / 3600
            let diffMins = abs(diffSeconds % 3600) / 60

            let formatter = DateFormatter()
            formatter.timeZone = tz

            formatter.dateFormat = "h:mm a"
            let time12 = formatter.string(from: now)
            formatter.dateFormat = "HH:mm"
            let time24 = formatter.string(from: now)
            formatter.dateFormat = "EEEE, MMM d"
            let dateStr = formatter.string(from: now)

            let sign = diffHours >= 0 ? "+" : ""
            let offsetStr = diffMins > 0 ? "\(sign)\(diffHours):\(String(format: "%02d", diffMins))" : "\(sign)\(diffHours)h"
            let utcH = targetOffset / 3600
            let utcM = abs(targetOffset % 3600) / 60
            let utcStr = utcM > 0 ? "UTC\(utcH >= 0 ? "+" : "")\(utcH):\(String(format: "%02d", utcM))" : "UTC\(utcH >= 0 ? "+" : "")\(utcH)"

            let items: [(String, String)] = [
                (config.label, "\(time12) / \(time24)"),
                ("Date", dateStr),
                ("Offset", "\(offsetStr) from you"),
                ("UTC Offset", utcStr),
                ("Timezone", config.targetTimeZone),
            ]
            for (label, value) in items {
                let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
