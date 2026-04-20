import Cocoa
import EventKit

struct CalendarGridConfig: Codable, Equatable {
    var showEventDots: Bool
    var showWeekNumbers: Bool
    var weekStartsOnMonday: Bool
    var use24Hour: Bool

    static let `default` = CalendarGridConfig(
        showEventDots: true,
        showWeekNumbers: false,
        weekStartsOnMonday: false,
        use24Hour: false
    )
}

class CalendarGridWidget: BaristaWidget, InteractiveDropdown {
    static let widgetID = "calendar-grid"
    static let displayName = "Calendar Grid"
    static let subtitle = "Mini month calendar with event indicators"
    static let iconName = "calendar.badge.clock"
    static let category = WidgetCategory.timeCalendar
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CalendarGridConfig.default

    var config: CalendarGridConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?
    private let store = EKEventStore()
    private(set) var hasAccess = false
    private(set) var monthEvents: [Date: Int] = [:]  // day -> event count
    private(set) var todayEvents: [EKEvent] = []
    private(set) var displayMonth = Date()

    required init(config: CalendarGridConfig) {
        self.config = config
    }

    func start() {
        requestAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchEvents()
            self?.onDisplayUpdate?()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                self?.hasAccess = granted
                DispatchQueue.main.async {
                    self?.fetchEvents()
                    self?.onDisplayUpdate?()
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                self?.hasAccess = granted
                DispatchQueue.main.async {
                    self?.fetchEvents()
                    self?.onDisplayUpdate?()
                }
            }
        }
    }

    private func fetchEvents() {
        guard hasAccess else { return }

        let cal = Calendar.current
        let now = Date()

        // Fetch events for the display month
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)),
              let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return }

        let predicate = store.predicateForEvents(withStart: monthStart, end: monthEnd, calendars: nil)
        let events = store.events(matching: predicate)

        // Count events per day
        monthEvents = [:]
        for event in events {
            let dayStart = cal.startOfDay(for: event.startDate)
            monthEvents[dayStart, default: 0] += 1
        }

        // Today's events for the sidebar
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let todayPred = store.predicateForEvents(withStart: todayStart, end: todayEnd, calendars: nil)
        todayEvents = store.events(matching: todayPred)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        let cal = Calendar.current
        let now = Date()
        let day = cal.component(.day, from: now)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        let dateStr = formatter.string(from: now)

        if let next = todayEvents.first(where: { $0.startDate > now }) {
            let minsUntil = Int(next.startDate.timeIntervalSince(now) / 60)
            if minsUntil <= 30 {
                let title = (next.title ?? "Event").prefix(12)
                return .text("\u{1F4C5} \(day) | \(title) \(minsUntil)m")
            }
        }

        let eventCount = todayEvents.count
        if eventCount > 0 {
            return .text("\u{1F4C5} \(dateStr) | \(eventCount) events")
        }

        return .text("\u{1F4C5} \(dateStr)")
    }

    // MARK: - Interactive Dropdown (Calendar Grid)

    func buildDropdownPopover() -> NSView {
        let width: CGFloat = 340
        let height: CGFloat = 380
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        let padding: CGFloat = 16
        var y = height - padding

        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        // Month/Year header with nav arrows
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let monthStr = formatter.string(from: displayMonth)

        let monthLabel = NSTextField(labelWithString: monthStr)
        monthLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        monthLabel.textColor = Theme.textPrimary
        monthLabel.frame = NSRect(x: padding + 30, y: y - 20, width: width - padding * 2 - 60, height: 20)
        monthLabel.alignment = .center
        container.addSubview(monthLabel)

        // Prev/Next buttons
        let prevBtn = NSButton(frame: NSRect(x: padding, y: y - 22, width: 24, height: 24))
        prevBtn.title = "\u{25C0}"
        prevBtn.bezelStyle = .inline
        prevBtn.isBordered = false
        prevBtn.font = .systemFont(ofSize: 12)
        prevBtn.target = self
        prevBtn.action = #selector(prevMonth)
        container.addSubview(prevBtn)

        let nextBtn = NSButton(frame: NSRect(x: width - padding - 24, y: y - 22, width: 24, height: 24))
        nextBtn.title = "\u{25B6}"
        nextBtn.bezelStyle = .inline
        nextBtn.isBordered = false
        nextBtn.font = .systemFont(ofSize: 12)
        nextBtn.target = self
        nextBtn.action = #selector(nextMonth)
        container.addSubview(nextBtn)

        y -= 32

        // Day-of-week headers
        let dayNames = config.weekStartsOnMonday
            ? ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
            : ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let cellW: CGFloat = (width - padding * 2) / 7
        for (i, day) in dayNames.enumerated() {
            let label = NSTextField(labelWithString: day)
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = Theme.textMuted
            label.alignment = .center
            label.frame = NSRect(x: padding + CGFloat(i) * cellW, y: y - 14, width: cellW, height: 14)
            container.addSubview(label)
        }
        y -= 20

        // Calendar grid
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)),
              let range = cal.range(of: .day, in: .month, for: monthStart) else { return container }

        var weekday = cal.component(.weekday, from: monthStart)
        if config.weekStartsOnMonday {
            weekday = weekday == 1 ? 7 : weekday - 1
        }
        let offset = weekday - 1

        let cellH: CGFloat = 28
        var col = offset
        var row = 0

        for dayNum in range {
            guard let date = cal.date(byAdding: .day, value: dayNum - 1, to: monthStart) else { continue }
            let dayStart = cal.startOfDay(for: date)

            let x = padding + CGFloat(col) * cellW
            let cellY = y - CGFloat(row) * cellH

            let isToday = cal.isDate(date, inSameDayAs: today)
            let eventCount = monthEvents[dayStart] ?? 0

            // Day number
            let dayLabel = NSTextField(labelWithString: "\(dayNum)")
            dayLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: isToday ? .bold : .regular)
            dayLabel.alignment = .center
            dayLabel.frame = NSRect(x: x, y: cellY - 18, width: cellW, height: 18)

            if isToday {
                dayLabel.textColor = Theme.bg
                let circle = NSView(frame: NSRect(x: x + (cellW - 22) / 2, y: cellY - 20, width: 22, height: 22))
                circle.wantsLayer = true
                circle.layer?.backgroundColor = Theme.accent.cgColor
                circle.layer?.cornerRadius = 11
                container.addSubview(circle)
            } else {
                dayLabel.textColor = Theme.textPrimary
            }

            container.addSubview(dayLabel)

            // Event dots
            if config.showEventDots && eventCount > 0 {
                let dotCount = min(eventCount, 3)
                let dotSize: CGFloat = 4
                let dotSpacing: CGFloat = 6
                let dotsWidth = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * (dotSpacing - dotSize)
                let dotX = x + (cellW - dotsWidth) / 2

                for d in 0..<dotCount {
                    let dot = NSView(frame: NSRect(x: dotX + CGFloat(d) * dotSpacing, y: cellY - 24, width: dotSize, height: dotSize))
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = (isToday ? Theme.bg : Theme.accent).cgColor
                    dot.layer?.cornerRadius = dotSize / 2
                    container.addSubview(dot)
                }
            }

            col += 1
            if col >= 7 {
                col = 0
                row += 1
            }
        }

        y -= CGFloat(row + 1) * cellH + 8

        // Today's events list
        if !todayEvents.isEmpty {
            let divider = NSView(frame: NSRect(x: padding, y: y, width: width - padding * 2, height: 1))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Theme.divider.cgColor
            container.addSubview(divider)
            y -= 12

            let todayHeader = NSTextField(labelWithString: "TODAY")
            todayHeader.font = .systemFont(ofSize: 9, weight: .medium)
            todayHeader.textColor = Theme.textMuted
            todayHeader.frame = NSRect(x: padding, y: y - 12, width: 60, height: 12)
            container.addSubview(todayHeader)
            y -= 18

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = config.use24Hour ? "HH:mm" : "h:mm a"

            for event in todayEvents.prefix(4) {
                let time = timeFormatter.string(from: event.startDate)
                let title = (event.title ?? "Event").prefix(24)

                let color = event.startDate <= now && event.endDate > now ? Theme.red : Theme.textSecondary

                let eventLabel = NSTextField(labelWithString: "\(time)  \(title)")
                eventLabel.font = .systemFont(ofSize: 11)
                eventLabel.textColor = color
                eventLabel.frame = NSRect(x: padding, y: y - 16, width: width - padding * 2, height: 16)
                container.addSubview(eventLabel)
                y -= 20
            }
        }

        return container
    }

    var dropdownSize: NSSize { NSSize(width: 340, height: 380) }

    @objc private func prevMonth() {
        displayMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
        fetchEvents()
        onDisplayUpdate?()
    }

    @objc private func nextMonth() {
        displayMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
        fetchEvents()
        onDisplayUpdate?()
    }

    // MARK: - Standard Dropdown (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "CALENDAR", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard hasAccess else {
            let noAccess = NSMenuItem(title: "Grant calendar access in System Settings", action: nil, keyEquivalent: "")
            noAccess.isEnabled = false
            menu.addItem(noAccess)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return menu
        }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        for event in todayEvents.prefix(8) {
            let time = formatter.string(from: event.startDate)
            let active = event.startDate <= now && event.endDate > now
            let prefix = active ? "\u{1F534} " : ""
            let item = NSMenuItem(title: "\(prefix)\(time) - \(event.title ?? "Event")", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if todayEvents.isEmpty {
            let free = NSMenuItem(title: "No events today", action: nil, keyEquivalent: "")
            free.isEnabled = false
            menu.addItem(free)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Calendar", action: #selector(AppDelegate.openCalendarApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
