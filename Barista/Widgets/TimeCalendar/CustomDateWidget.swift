import Cocoa

struct CustomDateConfig: Codable, Equatable {
    var format: String
    var showDayProgress: Bool

    static let `default` = CustomDateConfig(
        format: "EEE MMM d | 'Week' w | 'Q'{quarter}",
        showDayProgress: false
    )
}

class CustomDateWidget: BaristaWidget {
    static let widgetID = "custom-date"
    static let displayName = "Custom Date"
    static let subtitle = "Fully customizable date display"
    static let iconName = "calendar"
    static let category = WidgetCategory.timeCalendar
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = CustomDateConfig.default

    var config: CustomDateConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?

    required init(config: CustomDateConfig) {
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

    private func formatDate() -> String {
        let now = Date()
        let cal = Calendar.current

        // Replace custom tokens first
        var fmt = config.format

        // {quarter}
        let month = cal.component(.month, from: now)
        let quarter = (month - 1) / 3 + 1
        fmt = fmt.replacingOccurrences(of: "{quarter}", with: "\(quarter)")

        // {dayOfYear}
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        fmt = fmt.replacingOccurrences(of: "{dayOfYear}", with: "\(dayOfYear)")

        // {daysLeft}
        let daysInYear = cal.range(of: .day, in: .year, for: now)?.count ?? 365
        fmt = fmt.replacingOccurrences(of: "{daysLeft}", with: "\(daysInYear - dayOfYear)")

        // {week}
        let week = cal.component(.weekOfYear, from: now)
        fmt = fmt.replacingOccurrences(of: "{week}", with: "\(week)")

        // {daysInMonth}
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        fmt = fmt.replacingOccurrences(of: "{daysInMonth}", with: "\(daysInMonth)")

        // Now format with DateFormatter
        let df = DateFormatter()
        df.dateFormat = fmt
        return df.string(from: now)
    }

    func render() -> WidgetDisplayMode {
        var text = formatDate()
        if config.showDayProgress {
            let cal = Calendar.current
            let now = Date()
            let hour = cal.component(.hour, from: now)
            let pct = Int(Double(hour) / 24.0 * 100)
            text += " \(pct)%"
        }
        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "CUSTOM DATE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let now = Date()
        let cal = Calendar.current

        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .none
        let fullDate = NSMenuItem(title: df.string(from: now), action: nil, keyEquivalent: "")
        fullDate.isEnabled = false
        menu.addItem(fullDate)

        menu.addItem(NSMenuItem.separator())

        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        let daysInYear = cal.range(of: .day, in: .year, for: now)?.count ?? 365
        let week = cal.component(.weekOfYear, from: now)
        let month = cal.component(.month, from: now)
        let quarter = (month - 1) / 3 + 1

        let info: [(String, String)] = [
            ("Day of Year", "\(dayOfYear) / \(daysInYear)"),
            ("Days Left", "\(daysInYear - dayOfYear)"),
            ("Week", "\(week)"),
            ("Quarter", "Q\(quarter)"),
        ]

        for (label, value) in info {
            let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Day progress bar
        let hour = cal.component(.hour, from: now)
        let pct = Double(hour) / 24.0
        let filled = Int(pct * 10)
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
        menu.addItem(NSMenuItem.separator())
        let progItem = NSMenuItem(title: "Day: [\(bar)] \(Int(pct * 100))%", action: nil, keyEquivalent: "")
        progItem.isEnabled = false
        menu.addItem(progItem)

        // Format tokens cheat sheet
        menu.addItem(NSMenuItem.separator())
        let cheatHeader = NSMenuItem(title: "Format Tokens:", action: nil, keyEquivalent: "")
        cheatHeader.isEnabled = false
        menu.addItem(cheatHeader)
        let tokens = [
            "EEE = Day name (Mon)",
            "MMM = Month (Apr)",
            "d = Day number",
            "w = Week of year",
            "{quarter} = Quarter",
            "{dayOfYear} = Day of year",
            "{daysLeft} = Days remaining",
        ]
        for t in tokens {
            let item = NSMenuItem(title: "  \(t)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
