import Cocoa

struct MarketStatusConfig: Codable, Equatable {
    var showCountdown: Bool
    var showDot: Bool

    static let `default` = MarketStatusConfig(
        showCountdown: true,
        showDot: true
    )
}

class MarketStatusWidget: BaristaWidget {
    static let widgetID = "market-status"
    static let displayName = "Market Status"
    static let subtitle = "Is the stock market open or closed?"
    static let iconName = "building.columns"
    static let category = WidgetCategory.finance
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = MarketStatusConfig.default

    var config: MarketStatusConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?

    required init(config: MarketStatusConfig) {
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

    private enum MarketState {
        case preMarket
        case open
        case afterHours
        case closed
    }

    private func currentState() -> (MarketState, String) {
        let now = Date()

        // Convert to ET
        guard let et = TimeZone(identifier: "America/New_York") else { return (.closed, "") }
        var etCal = Calendar.current
        etCal.timeZone = et

        let weekday = etCal.component(.weekday, from: now)
        let hour = etCal.component(.hour, from: now)
        let minute = etCal.component(.minute, from: now)
        let totalMin = hour * 60 + minute

        // Weekend
        if weekday == 1 || weekday == 7 {
            // Find next Monday 9:30 AM ET
            let daysToMon = weekday == 7 ? 2 : 1
            let mondayComponents = etCal.dateComponents([.year, .month, .day], from: now)
            if let baseDate = etCal.date(from: mondayComponents),
               let mondayDate = etCal.date(byAdding: .day, value: daysToMon, to: baseDate) {
                var openComponents = etCal.dateComponents([.year, .month, .day], from: mondayDate)
                openComponents.hour = 9
                openComponents.minute = 30
                openComponents.second = 0
                if let nextOpen = etCal.date(from: openComponents) {
                    let diff = nextOpen.timeIntervalSince(now)
                    let h = Int(diff) / 3600
                    let m = (Int(diff) % 3600) / 60
                    return (.closed, "Opens Mon \(h)h \(m)m")
                }
            }
            return (.closed, "Opens Monday")
        }

        let preMarketStart = 4 * 60     // 4:00 AM
        let marketOpen = 9 * 60 + 30    // 9:30 AM
        let marketClose = 16 * 60       // 4:00 PM
        let afterHoursEnd = 20 * 60     // 8:00 PM

        if totalMin < preMarketStart {
            let minsLeft = preMarketStart - totalMin
            return (.closed, "Pre-mkt in \(minsLeft / 60)h \(minsLeft % 60)m")
        } else if totalMin < marketOpen {
            let minsLeft = marketOpen - totalMin
            return (.preMarket, "Opens in \(minsLeft / 60)h \(minsLeft % 60)m")
        } else if totalMin < marketClose {
            let minsLeft = marketClose - totalMin
            return (.open, "\(minsLeft / 60)h \(minsLeft % 60)m left")
        } else if totalMin < afterHoursEnd {
            let minsLeft = afterHoursEnd - totalMin
            return (.afterHours, "\(minsLeft / 60)h \(minsLeft % 60)m")
        } else {
            return (.closed, "Opens tomorrow 9:30a")
        }
    }

    func render() -> WidgetDisplayMode {
        let (state, countdown) = currentState()

        let dot: String
        let label: String

        switch state {
        case .preMarket:
            dot = "\u{1F7E1}"; label = "Pre-Mkt"
        case .open:
            dot = "\u{1F7E2}"; label = "Open"
        case .afterHours:
            dot = "\u{1F7E0}"; label = "After Hrs"
        case .closed:
            dot = "\u{1F534}"; label = "Closed"
        }

        var text = ""
        if config.showDot { text += dot + " " }
        text += label
        if config.showCountdown && !countdown.isEmpty {
            text += " | " + countdown
        }

        if state == .open {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor(red: 0.16, green: 0.85, blue: 0.54, alpha: 1)
            ])
            return .attributedText(attr)
        }

        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "MARKET STATUS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let markets = [
            ("NYSE / NASDAQ", "America/New_York", 9*60+30, 16*60),
            ("LSE (London)", "Europe/London", 8*60, 16*60+30),
            ("TSE (Tokyo)", "Asia/Tokyo", 9*60, 15*60),
            ("HKEX (Hong Kong)", "Asia/Hong_Kong", 9*60+30, 16*60),
        ]

        for (name, tzId, openMin, closeMin) in markets {
            guard let tz = TimeZone(identifier: tzId) else { continue }
            var cal = Calendar.current
            cal.timeZone = tz
            let now = Date()
            let weekday = cal.component(.weekday, from: now)
            let hour = cal.component(.hour, from: now)
            let minute = cal.component(.minute, from: now)
            let totalMin = hour * 60 + minute

            let isWeekend = weekday == 1 || weekday == 7
            let isOpen = !isWeekend && totalMin >= openMin && totalMin < closeMin
            let dot = isOpen ? "\u{1F7E2}" : "\u{1F534}"

            let df = DateFormatter()
            df.timeZone = tz
            df.dateFormat = "h:mm a"
            let localTime = df.string(from: now)

            let item = NSMenuItem(title: "\(dot) \(name) - \(localTime)", action: nil, keyEquivalent: "")
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
