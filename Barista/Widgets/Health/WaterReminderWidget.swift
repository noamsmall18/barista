import Cocoa

struct WaterReminderConfig: Codable, Equatable {
    var dailyGoal: Int
    var currentCount: Int
    var lastResetDate: String

    static let `default` = WaterReminderConfig(
        dailyGoal: 8,
        currentCount: 0,
        lastResetDate: ""
    )
}

class WaterReminderWidget: BaristaWidget, Cycleable {
    static let widgetID = "water-reminder"
    static let displayName = "Water Reminder"
    static let subtitle = "Track daily water intake"
    static let iconName = "drop.fill"
    static let category = WidgetCategory.health
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = WaterReminderConfig.default

    var config: WaterReminderConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?

    required init(config: WaterReminderConfig) {
        self.config = config
        checkMidnightReset()
    }

    func start() {
        checkMidnightReset()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkMidnightReset()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Cycleable

    var itemCount: Int { config.dailyGoal + 1 }
    var currentIndex: Int { config.currentCount }
    var cycleInterval: TimeInterval { 0 }

    func cycleNext() {
        if config.currentCount >= config.dailyGoal {
            config.currentCount = 0
        } else {
            config.currentCount += 1
        }
        onDisplayUpdate?()
    }

    // MARK: - Midnight Reset

    private func todayString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func checkMidnightReset() {
        let today = todayString()
        if config.lastResetDate != today {
            config.currentCount = 0
            config.lastResetDate = today
        }
    }

    @objc func logGlass() {
        if config.currentCount < config.dailyGoal {
            config.currentCount += 1
        }
        onDisplayUpdate?()
    }

    @objc func resetCount() {
        config.currentCount = 0
        onDisplayUpdate?()
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        let goalMet = config.currentCount >= config.dailyGoal

        if goalMet {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attr = NSAttributedString(string: "\u{1F4A7} \(config.currentCount)/\(config.dailyGoal)", attributes: [
                .font: font,
                .foregroundColor: Theme.green
            ])
            return .attributedText(attr)
        }

        return .text("\u{1F4A7} \(config.currentCount)/\(config.dailyGoal)")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "WATER REMINDER", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Progress bar
        let pct = config.dailyGoal > 0 ? min(Double(config.currentCount) / Double(config.dailyGoal) * 100, 100) : 0
        let filled = Int(pct / 10)
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
        let progressItem = NSMenuItem(title: "[\(bar)] \(Int(pct))%", action: nil, keyEquivalent: "")
        progressItem.isEnabled = false
        menu.addItem(progressItem)

        let countItem = NSMenuItem(title: "\(config.currentCount) / \(config.dailyGoal) glasses", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        menu.addItem(countItem)

        if config.currentCount >= config.dailyGoal {
            let doneItem = NSMenuItem(title: "\u{2705} Goal reached!", action: nil, keyEquivalent: "")
            doneItem.isEnabled = false
            menu.addItem(doneItem)
        }

        menu.addItem(NSMenuItem.separator())

        let logItem = NSMenuItem(title: "Log Glass", action: #selector(logGlass), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let resetItem = NSMenuItem(title: "Reset", action: #selector(resetCount), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
