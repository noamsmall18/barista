import Cocoa

struct StandReminderConfig: Codable, Equatable {
    var intervalMinutes: Int
    var isActive: Bool

    static let `default` = StandReminderConfig(
        intervalMinutes: 60,
        isActive: true
    )
}

class StandReminderWidget: BaristaWidget, Cycleable {
    static let widgetID = "stand-reminder"
    static let displayName = "Stand Reminder"
    static let subtitle = "Hourly stand-up reminders"
    static let iconName = "figure.stand"
    static let category = WidgetCategory.health
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = StandReminderConfig.default

    var config: StandReminderConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 1 }

    private var timer: Timer?
    private(set) var secondsRemaining: Int = 0
    private(set) var standCount: Int = 0
    private(set) var needsStand: Bool = false
    private var lastStandDate: String = ""

    required init(config: StandReminderConfig) {
        self.config = config
        self.secondsRemaining = config.intervalMinutes * 60
        restoreStreak()
    }

    func start() {
        checkDayReset()
        if secondsRemaining <= 0 {
            secondsRemaining = config.intervalMinutes * 60
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Cycleable

    var itemCount: Int { 1 }
    var currentIndex: Int { 0 }
    var cycleInterval: TimeInterval { 0 }

    func cycleNext() {
        if needsStand {
            // User acknowledged the stand reminder
            needsStand = false
            standCount += 1
            secondsRemaining = config.intervalMinutes * 60
            saveStreak()
            onDisplayUpdate?()
        }
    }

    // MARK: - Timer

    private func tick() {
        checkDayReset()

        guard config.isActive else {
            onDisplayUpdate?()
            return
        }

        if needsStand {
            onDisplayUpdate?()
            return
        }

        secondsRemaining -= 1

        if secondsRemaining <= 0 {
            needsStand = true
            secondsRemaining = 0
        }

        onDisplayUpdate?()
    }

    private func checkDayReset() {
        let today = todayString()
        if lastStandDate != today {
            standCount = 0
            lastStandDate = today
            saveStreak()
        }
    }

    @objc func toggleActive() {
        config.isActive.toggle()
        if config.isActive && secondsRemaining <= 0 {
            secondsRemaining = config.intervalMinutes * 60
            needsStand = false
        }
        onDisplayUpdate?()
    }

    // MARK: - Persistence

    private func todayString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func saveStreak() {
        UserDefaults.standard.set(standCount, forKey: "barista.stand.count")
        UserDefaults.standard.set(lastStandDate, forKey: "barista.stand.date")
    }

    private func restoreStreak() {
        let savedDate = UserDefaults.standard.string(forKey: "barista.stand.date") ?? ""
        let today = todayString()
        if savedDate == today {
            standCount = UserDefaults.standard.integer(forKey: "barista.stand.count")
        }
        lastStandDate = today
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        if !config.isActive {
            return .text("\u{1F9CD} Paused")
        }

        if needsStand {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let attr = NSAttributedString(string: "\u{1F9CD} STAND UP!", attributes: [
                .font: font,
                .foregroundColor: Theme.red
            ])
            return .attributedText(attr)
        }

        let minutes = secondsRemaining / 60
        return .text("\u{1F9CD} \(minutes)m")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "STAND REMINDER", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let streakItem = NSMenuItem(title: "Stands today: \(standCount)", action: nil, keyEquivalent: "")
        streakItem.isEnabled = false
        menu.addItem(streakItem)

        if needsStand {
            let alertItem = NSMenuItem(title: "Time to stand up!", action: nil, keyEquivalent: "")
            alertItem.isEnabled = false
            menu.addItem(alertItem)
        } else if config.isActive {
            let min = secondsRemaining / 60
            let sec = secondsRemaining % 60
            let nextItem = NSMenuItem(title: String(format: "Next stand in: %d:%02d", min, sec), action: nil, keyEquivalent: "")
            nextItem.isEnabled = false
            menu.addItem(nextItem)
        }

        let statusItem = NSMenuItem(title: "Status: \(config.isActive ? "Active" : "Paused")", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        let toggleTitle = config.isActive ? "Pause" : "Resume"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleActive), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
