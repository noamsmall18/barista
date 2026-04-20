import Cocoa

struct DailyGoalConfig: Codable, Equatable {
    var goalName: String
    var target: Int
    var unit: String
    var showBar: Bool
    var incrementOptions: [Int]

    static let `default` = DailyGoalConfig(
        goalName: "Steps",
        target: 10000,
        unit: "steps",
        showBar: true,
        incrementOptions: [100, 500, 1000]
    )
}

class DailyGoalWidget: BaristaWidget {
    static let widgetID = "daily-goal"
    static let displayName = "Daily Goal"
    static let subtitle = "Track progress toward a daily target"
    static let iconName = "flag.checkered"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = DailyGoalConfig.default

    var config: DailyGoalConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { nil }

    private var timer: Timer?
    private(set) var current: Int = 0
    private var todayKey: String { "barista.goal.\(config.goalName).\(dateString())" }

    required init(config: DailyGoalConfig) {
        self.config = config
        current = UserDefaults.standard.integer(forKey: todayKey)
    }

    func start() {
        current = UserDefaults.standard.integer(forKey: todayKey)
        // Check for midnight reset
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkReset()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkReset() {
        let newKey = todayKey
        let stored = UserDefaults.standard.integer(forKey: newKey)
        if stored != current {
            current = stored
            onDisplayUpdate?()
        }
    }

    func increment(by amount: Int) {
        current += amount
        UserDefaults.standard.set(current, forKey: todayKey)
        onDisplayUpdate?()
    }

    func resetToday() {
        current = 0
        UserDefaults.standard.set(0, forKey: todayKey)
        onDisplayUpdate?()
    }

    func render() -> WidgetDisplayMode {
        let pct = config.target > 0 ? min(Double(current) / Double(config.target) * 100, 100) : 0

        if config.showBar {
            let filled = Int(pct / 10)
            let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
            return .text("\(bar) \(Int(pct))%")
        }

        return .text(formatNumber(current) + " / " + formatNumber(config.target))
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000)
        }
        return "\(n)"
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: config.goalName.uppercased(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let pct = config.target > 0 ? Double(current) / Double(config.target) * 100 : 0
        let progressItem = NSMenuItem(title: "\(current) / \(config.target) \(config.unit) (\(Int(pct))%)", action: nil, keyEquivalent: "")
        progressItem.isEnabled = false
        menu.addItem(progressItem)

        let remaining = max(config.target - current, 0)
        let remItem = NSMenuItem(title: "Remaining: \(remaining) \(config.unit)", action: nil, keyEquivalent: "")
        remItem.isEnabled = false
        menu.addItem(remItem)

        // Progress bar
        let filled = Int(min(pct, 100) / 10)
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
        let barItem = NSMenuItem(title: "[\(bar)]", action: nil, keyEquivalent: "")
        barItem.isEnabled = false
        menu.addItem(barItem)

        menu.addItem(NSMenuItem.separator())

        // Increment buttons
        for amount in config.incrementOptions {
            let item = NSMenuItem(title: "+\(amount)", action: #selector(AppDelegate.goalIncrement(_:)), keyEquivalent: "")
            item.representedObject = amount
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(title: "Reset Today", action: #selector(AppDelegate.goalReset), keyEquivalent: "")
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }

    private func dateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}
