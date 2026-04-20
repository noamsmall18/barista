import Cocoa

struct CountdownConfig: Codable, Equatable {
    var eventName: String
    var targetDate: Date
    var emoji: String
    var showSeconds: Bool
    var countUpAfter: Bool

    static let `default` = CountdownConfig(
        eventName: "New Year",
        targetDate: {
            var comps = DateComponents()
            comps.year = Calendar.current.component(.year, from: Date()) + 1
            comps.month = 1
            comps.day = 1
            return Calendar.current.date(from: comps) ?? Date()
        }(),
        emoji: "\u{1F389}",
        showSeconds: false,
        countUpAfter: false
    )
}

class CountdownWidget: BaristaWidget {
    static let widgetID = "countdown"
    static let displayName = "Countdown Timer"
    static let subtitle = "Count down to any date or event"
    static let iconName = "hourglass"
    static let category = WidgetCategory.timeCalendar
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = CountdownConfig.default

    var config: CountdownConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.showSeconds ? 1 : 60 }

    private var timer: Timer?

    required init(config: CountdownConfig) {
        self.config = config
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: config.showSeconds ? 1.0 : 30.0, repeats: true) { [weak self] _ in
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func render() -> WidgetDisplayMode {
        let now = Date()
        let diff = config.targetDate.timeIntervalSince(now)

        if diff <= 0 && !config.countUpAfter {
            if abs(diff) < 86400 {
                return .text("\(config.emoji) It's here!")
            }
            return .text("\(config.emoji) Passed")
        }

        let absDiff = config.countUpAfter && diff < 0 ? abs(diff) : max(diff, 0)
        let prefix = diff < 0 ? "+" : ""

        let days = Int(absDiff) / 86400
        let hours = (Int(absDiff) % 86400) / 3600
        let minutes = (Int(absDiff) % 3600) / 60
        let seconds = Int(absDiff) % 60

        var text = "\(config.emoji) "
        if days > 0 {
            text += "\(prefix)\(days)d \(hours)h"
            if days < 2 {
                text += " \(minutes)m"
            }
        } else if hours > 0 {
            text += "\(prefix)\(hours)h \(minutes)m"
        } else if config.showSeconds {
            text += "\(prefix)\(minutes)m \(seconds)s"
        } else {
            text += "\(prefix)\(minutes)m"
        }

        // Pulse red when under 1 minute
        if diff > 0 && diff < 60 {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            ])
            return .attributedText(attr)
        }

        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "COUNTDOWN", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let nameItem = NSMenuItem(title: "\(config.emoji) \(config.eventName)", action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let dateItem = NSMenuItem(title: "Target: \(df.string(from: config.targetDate))", action: nil, keyEquivalent: "")
        dateItem.isEnabled = false
        menu.addItem(dateItem)

        let diff = config.targetDate.timeIntervalSince(Date())
        let days = Int(abs(diff)) / 86400
        let hours = (Int(abs(diff)) % 86400) / 3600
        let minutes = (Int(abs(diff)) % 3600) / 60
        let seconds = Int(abs(diff)) % 60

        let fullStr = String(format: "%dd %dh %dm %ds", days, hours, minutes, seconds)
        let fullItem = NSMenuItem(title: diff >= 0 ? "Remaining: \(fullStr)" : "Elapsed: \(fullStr)", action: nil, keyEquivalent: "")
        fullItem.isEnabled = false
        menu.addItem(fullItem)

        // Milestones
        if diff > 0 {
            menu.addItem(NSMenuItem.separator())
            let milestones: [(Int, String)] = [(90, "90 days"), (60, "60 days"), (30, "30 days"), (7, "7 days"), (1, "1 day")]
            for (d, label) in milestones {
                let passed = days < d
                let mark = passed ? "\u{2705}" : (days == d ? "\u{1F534}" : "\u{2B1C}")
                let item = NSMenuItem(title: "\(mark) \(label)", action: nil, keyEquivalent: "")
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
