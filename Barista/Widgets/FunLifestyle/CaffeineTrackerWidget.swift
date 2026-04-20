import Cocoa

struct CaffeineEntry: Codable, Equatable {
    var mg: Int
    var timestamp: Date
}

struct CaffeineTrackerConfig: Codable, Equatable {
    var dailyLimitMg: Int
    var items: [CaffeineEntry]

    static let `default` = CaffeineTrackerConfig(
        dailyLimitMg: 400,
        items: []
    )
}

class CaffeineTrackerWidget: BaristaWidget {
    static let widgetID = "caffeine-tracker"
    static let displayName = "Caffeine Tracker"
    static let subtitle = "Track caffeine intake with half-life decay"
    static let iconName = "mug.fill"
    static let category = WidgetCategory.funLifestyle
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CaffeineTrackerConfig.default

    var config: CaffeineTrackerConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?

    required init(config: CaffeineTrackerConfig) {
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

    // MARK: - Caffeine Math

    private let halfLifeHours: Double = 5.7

    private func activeCaffeine() -> Double {
        let now = Date()
        var total: Double = 0
        for entry in config.items {
            let hoursElapsed = now.timeIntervalSince(entry.timestamp) / 3600
            guard hoursElapsed >= 0 else { continue }
            let remaining = Double(entry.mg) * pow(0.5, hoursElapsed / halfLifeHours)
            total += remaining
        }
        return total
    }

    private func totalCaffeineToday() -> Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return config.items
            .filter { $0.timestamp >= startOfDay }
            .reduce(0) { $0 + $1.mg }
    }

    private func todayEntries() -> [CaffeineEntry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return config.items.filter { $0.timestamp >= startOfDay }
    }

    func logCaffeine(mg: Int) {
        config.items.append(CaffeineEntry(mg: mg, timestamp: Date()))
        onDisplayUpdate?()
    }

    @objc func logCaffeine(_ sender: NSMenuItem) {
        logCaffeine(mg: sender.tag)
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        let active = Int(activeCaffeine())
        let overLimit = totalCaffeineToday() >= config.dailyLimitMg

        if overLimit {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let attr = NSAttributedString(string: "\u{2615} \(active)mg", attributes: [
                .font: font,
                .foregroundColor: Theme.red
            ])
            return .attributedText(attr)
        }

        return .text("\u{2615} \(active)mg")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "CAFFEINE TRACKER", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let active = Int(activeCaffeine())
        let totalToday = totalCaffeineToday()
        let activeItem = NSMenuItem(title: "Active: \(active)mg", action: nil, keyEquivalent: "")
        activeItem.isEnabled = false
        menu.addItem(activeItem)

        let totalItem = NSMenuItem(title: "Today: \(totalToday)mg / \(config.dailyLimitMg)mg", action: nil, keyEquivalent: "")
        totalItem.isEnabled = false
        menu.addItem(totalItem)

        menu.addItem(NSMenuItem.separator())

        let coffeeItem = NSMenuItem(title: "Log Coffee (95mg)", action: #selector(logCaffeine(_:)), keyEquivalent: "")
        coffeeItem.target = self
        coffeeItem.tag = 95
        menu.addItem(coffeeItem)

        let espressoItem = NSMenuItem(title: "Log Espresso (63mg)", action: #selector(logCaffeine(_:)), keyEquivalent: "")
        espressoItem.target = self
        espressoItem.tag = 63
        menu.addItem(espressoItem)

        let teaItem = NSMenuItem(title: "Log Tea (47mg)", action: #selector(logCaffeine(_:)), keyEquivalent: "")
        teaItem.target = self
        teaItem.tag = 47
        menu.addItem(teaItem)

        let energyItem = NSMenuItem(title: "Log Energy Drink (80mg)", action: #selector(logCaffeine(_:)), keyEquivalent: "")
        energyItem.target = self
        energyItem.tag = 80
        menu.addItem(energyItem)

        // Today's log
        let entries = todayEntries()
        if !entries.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let logHeader = NSMenuItem(title: "TODAY'S LOG", action: nil, keyEquivalent: "")
            logHeader.isEnabled = false
            menu.addItem(logHeader)

            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            for entry in entries.reversed() {
                let time = formatter.string(from: entry.timestamp)
                let logItem = NSMenuItem(title: "  \(time) - \(entry.mg)mg", action: nil, keyEquivalent: "")
                logItem.isEnabled = false
                menu.addItem(logItem)
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
