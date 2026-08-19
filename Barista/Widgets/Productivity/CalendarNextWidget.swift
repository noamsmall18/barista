import Cocoa
import EventKit

// MARK: - Config

struct CalendarNextConfig: Codable, Equatable {
    var displayMode: CalendarDisplayMode
    var showAllDay: Bool
    var showDeclined: Bool
    var showLocation: Bool
    var showCalendarName: Bool
    var alertMinutes: Int
    var lookahead: LookaheadPeriod
    var eventCount: Int
    var refreshRate: TimeInterval
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var calendarFilter: String  // comma-separated calendar identifiers, empty = all
    var showTimeUntil: Bool
    var showLocationInDropdown: Bool
    var maxTitleLength: Int
    var compactSpacing: Bool

    // Backward compatibility with AppDelegate references (not encoded)
    var minuteWarning: Int {
        get { alertMinutes }
        set { alertMinutes = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case displayMode, showAllDay, showDeclined, showLocation, showCalendarName
        case alertMinutes, lookahead, eventCount, refreshRate, accentColor, colorMode
        case calendarFilter, showTimeUntil, showLocationInDropdown, maxTitleLength, compactSpacing
    }

    static let `default` = CalendarNextConfig(
        displayMode: .timeAndTitle,
        showAllDay: false,
        showDeclined: false,
        showLocation: true,
        showCalendarName: true,
        alertMinutes: 5,
        lookahead: .today,
        eventCount: 5,
        refreshRate: 5,
        accentColor: .amber,
        colorMode: .calendarColor,
        calendarFilter: "",
        showTimeUntil: true,
        showLocationInDropdown: true,
        maxTitleLength: 30,
        compactSpacing: false
    )

    enum CalendarDisplayMode: String, Codable, Equatable {
        case timeAndTitle   // "2:30 PM Meeting"
        case countdown      // "in 25m: Meeting"
        case titleOnly      // "Meeting"
        case compact        // "25m"
        case timeRange      // "2:30-3:30 Meeting"
    }

    enum LookaheadPeriod: String, Codable, Equatable {
        case today = "today"
        case hours24 = "24h"
        case hours48 = "48h"
        case days7 = "7d"

        var calendarDays: Int {
            switch self {
            case .today: return 0
            case .hours24: return 1
            case .hours48: return 2
            case .days7: return 7
            }
        }

        var label: String {
            switch self {
            case .today: return "Today Only"
            case .hours24: return "24 Hours"
            case .hours48: return "48 Hours"
            case .days7: return "7 Days"
            }
        }
    }

    enum AccentPreset: String, Codable, Equatable, CaseIterable {
        case blue, cyan, green, amber, purple, red, white

        var color: NSColor {
            switch self {
            case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
            case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
            case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .amber:  return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
            case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
            case .red:    return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
    }

    enum ColorMode: String, Codable, Equatable {
        case calendarColor  // use the event's calendar color
        case fixed          // always uses accentColor
    }
}

// MARK: - Widget

class CalendarNextWidget: BaristaWidget {
    static let widgetID = "calendar-next"
    static let displayName = "Next Meeting"
    static let subtitle = "Countdown to your next calendar event"
    static let iconName = "calendar"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CalendarNextConfig.default

    var config: CalendarNextConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private let store = EKEventStore()
    private(set) var nextEvent: EKEvent?
    private(set) var currentEvent: EKEvent?
    private(set) var upcomingEvents: [EKEvent] = []
    // Backward compatibility alias
    var todayEvents: [EKEvent] { upcomingEvents }
    private(set) var hasAccess = false
    private var currentTimerInterval: TimeInterval = 0

    required init(config: CalendarNextConfig) {
        self.config = config
    }

    func start() {
        requestAccess()
        let rate = config.refreshRate
        currentTimerInterval = rate
        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Self-correct timer if refresh rate changed via config
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        fetchEvents()
        onDisplayUpdate?()
    }

    // MARK: - EventKit Access

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

    // MARK: - Event Fetching

    private func fetchEvents() {
        guard hasAccess else { return }

        let now = Date()
        let end: Date
        switch config.lookahead {
        case .today:
            end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        case .hours24:
            end = now.addingTimeInterval(24 * 3600)
        case .hours48:
            end = now.addingTimeInterval(48 * 3600)
        case .days7:
            end = now.addingTimeInterval(7 * 24 * 3600)
        }

        // Resolve calendar filter
        let calendars: [EKCalendar]?
        let filterIDs = config.calendarFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if filterIDs.isEmpty {
            calendars = nil
        } else {
            let all = store.calendars(for: .event)
            let matched = all.filter { filterIDs.contains($0.calendarIdentifier) }
            calendars = matched.isEmpty ? nil : matched
        }

        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: calendars)
        var events = store.events(matching: predicate)

        // Filter all-day
        if !config.showAllDay {
            events = events.filter { !$0.isAllDay }
        }

        // Filter declined
        if !config.showDeclined {
            events = events.filter { event in
                guard let attendees = event.attendees else { return true }
                let me = attendees.first { $0.isCurrentUser }
                return me?.participantStatus != .declined
            }
        }

        events.sort { $0.startDate < $1.startDate }
        upcomingEvents = events

        // Current event (happening now, non all-day)
        currentEvent = events.first { event in
            !event.isAllDay && event.startDate <= now && event.endDate > now
        }

        // Next upcoming event
        nextEvent = events.first { event in
            !event.isAllDay && event.startDate > now
        }
    }

    // MARK: - Time Formatting

    private func smartTimeUntil(_ date: Date) -> String {
        let now = Date()
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let mins = seconds / 60
        if mins < 1 { return "in <1 min" }
        if mins == 1 { return "in 1 min" }
        if mins < 60 { return "in \(mins) min" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 {
            if remMins == 0 { return "in \(hours)h" }
            return "in \(hours)h \(remMins)m"
        }
        // Tomorrow or beyond
        let cal = Calendar.current
        if cal.isDateInTomorrow(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return "Tomorrow \(fmt.string(from: date))"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE h:mm a"
        return fmt.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }

    private func eventAccentColor(_ event: EKEvent?) -> NSColor {
        switch config.colorMode {
        case .calendarColor:
            if let cal = event?.calendar, let cgColor = cal.color?.cgColor {
                return NSColor(cgColor: cgColor) ?? config.accentColor.color
            }
            return config.accentColor.color
        case .fixed:
            return config.accentColor.color
        }
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        guard hasAccess else { return .text("Cal: Grant Access") }

        let now = Date()

        // Currently in a meeting
        if let current = currentEvent {
            let minsLeft = Int(current.endDate.timeIntervalSince(now) / 60)
            let title = truncateTitle(current.title ?? "Meeting")
            let text: String
            switch config.displayMode {
            case .compact:
                text = "\(minsLeft)m left"
            case .titleOnly:
                text = "NOW: \(title)"
            case .timeRange:
                text = "NOW \(title) (-\(minsLeft)m)"
            default:
                text = "NOW: \(title) (\(minsLeft)m left)"
            }
            let color = eventAccentColor(current)
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: Theme.red,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ])
            if text.count > 28 {
                return .scrollingText(attr, width: 200)
            }
            return .attributedText(NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ]))
        }

        // Upcoming meeting
        if let next = nextEvent {
            let minsUntil = Int(next.startDate.timeIntervalSince(now) / 60)
            let title = truncateTitle(next.title ?? "Meeting")

            let text: String
            switch config.displayMode {
            case .timeAndTitle:
                text = config.showTimeUntil
                    ? "\(formatTime(next.startDate)) \(title) (\(shortCountdown(minsUntil)))"
                    : "\(formatTime(next.startDate)) \(title)"
            case .countdown:
                text = "\(shortCountdown(minsUntil)): \(title)"
            case .titleOnly:
                text = title
            case .compact:
                text = shortCountdown(minsUntil)
            case .timeRange:
                text = "\(formatTime(next.startDate))-\(formatTime(next.endDate)) \(title)"
            }

            // Urgent warning
            let isUrgent = minsUntil <= config.alertMinutes && minsUntil >= 0
            let color: NSColor = isUrgent ? Theme.brandAmber : eventAccentColor(next)
            let weight: NSFont.Weight = isUrgent ? .bold : .regular

            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: weight)
            ])
            if text.count > 28 {
                return .scrollingText(attr, width: 200)
            }
            return .attributedText(attr)
        }

        return .text("No upcoming events")
    }

    private func shortCountdown(_ mins: Int) -> String {
        if mins <= 0 { return "now" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func truncateTitle(_ title: String) -> String {
        let max = config.maxTitleLength
        if title.count <= max { return title }
        return String(title.prefix(max - 2)) + ".."
    }

    // MARK: - Dropdown Menu (fallback)

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
            menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
            return menu
        }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        if let current = currentEvent {
            let item = NSMenuItem(title: "NOW: \(current.title ?? "Meeting")", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let endStr = formatter.string(from: current.endDate)
            let endsItem = NSMenuItem(title: "  Ends at \(endStr)", action: nil, keyEquivalent: "")
            endsItem.isEnabled = false
            menu.addItem(endsItem)
            menu.addItem(NSMenuItem.separator())
        }

        let upcoming = upcomingEvents.filter { !$0.isAllDay && $0.startDate > now }
        if upcoming.isEmpty && currentEvent == nil {
            let free = NSMenuItem(title: "No more events today", action: nil, keyEquivalent: "")
            free.isEnabled = false
            menu.addItem(free)
        } else {
            for event in upcoming.prefix(config.eventCount) {
                let time = formatter.string(from: event.startDate)
                let minsUntil = Int(event.startDate.timeIntervalSince(now) / 60)
                let untilStr = minsUntil < 60 ? "in \(minsUntil)m" : "in \(minsUntil/60)h \(minsUntil%60)m"
                let item = NSMenuItem(title: "\(time) - \(event.title ?? "Event") (\(untilStr))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Calendar", action: #selector(AppDelegate.openCalendarApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

// MARK: - Interactive Dropdown

extension CalendarNextWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 80 // header
        h += 100 // hero card
        let eventRows = min(upcomingEvents.filter { $0 != currentEvent && $0 != nextEvent }.count + (currentEvent != nil ? 1 : 0), config.eventCount)
        h += CGFloat(eventRows) * 32 + 40 // upcoming section
        h += SuperWidgetKit.panelHeight + 8
        h += 50 // footer
        return NSSize(width: 340, height: min(max(h, 280), 720))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildCalHeader(in: container, y: y, pad: pad, cw: cw)

        guard hasAccess else {
            y = buildNoAccessCard(in: container, y: y, pad: pad, cw: cw)
            return container
        }

        y = buildHeroCard(in: container, y: y, pad: pad, cw: cw)
        y = buildUpcomingList(in: container, y: y, pad: pad, cw: cw)
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildCalFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let now = Date()
        let hero = currentEvent ?? nextEvent
        let activeText = currentEvent == nil ? "None" : "Now"
        let nextText = nextEvent.map { smartTimeUntil($0.startDate) } ?? "Clear"
        let allDayCount = upcomingEvents.filter { $0.isAllDay }.count
        let timedCount = upcomingEvents.filter { !$0.isAllDay }.count
        let heroTitle = hero?.title ?? "No upcoming event"
        let heroTime = hero.map { $0.isAllDay ? "All day" : "\(formatTime($0.startDate))-\(formatTime($0.endDate))" } ?? "Schedule clear"
        let nextWindow = upcomingEvents.first(where: { $0.startDate > now }) != nil ? "Next: \(heroTitle)" : "No later events"
        let accent = hero.map { eventAccentColor($0) } ?? config.accentColor.color

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Active", value: activeText, color: currentEvent == nil ? Theme.textMuted : Theme.green),
                SuperWidgetMetric(label: "Next", value: nextText, color: accent),
                SuperWidgetMetric(label: "Timed", value: "\(timedCount)", color: Theme.textSecondary),
                SuperWidgetMetric(label: "All-day", value: "\(allDayCount)", color: Theme.textMuted)
            ],
            insights: [
                nextWindow,
                heroTime,
                hasAccess ? "Calendar access active" : "Calendar access needed"
            ],
            actions: [
                "Window \(config.lookahead.label)",
                "Showing \(config.eventCount)",
                "Refresh \(Int(config.refreshRate))s"
            ],
            accent: accent
        )
    }

    // MARK: - Dropdown: Header

    private func buildCalHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Calendar")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMM d"
        let sub = NSTextField(labelWithString: dateFmt.string(from: Date()))
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = Theme.textMuted
        sub.frame = NSRect(x: pad, y: y - 36, width: cw, height: 14)
        container.addSubview(sub)

        y -= 44
        addCalDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Dropdown: No Access

    private func buildNoAccessCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 60
        let card = makeCalCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let label = NSTextField(labelWithString: "Calendar access required")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.textSecondary
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 24, width: cw - 16, height: 18)
        card.addSubview(label)

        let hint = NSTextField(labelWithString: "Grant access in System Settings > Privacy")
        hint.font = .systemFont(ofSize: 10, weight: .regular)
        hint.textColor = Theme.textFaint
        hint.alignment = .center
        hint.frame = NSRect(x: 8, y: 8, width: cw - 16, height: 14)
        card.addSubview(hint)

        y -= cardH + 8
        return y
    }

    // MARK: - Dropdown: Hero Card

    private func buildHeroCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let now = Date()

        // Determine the hero event: current > next > none
        let heroEvent = currentEvent ?? nextEvent

        guard let hero = heroEvent else {
            // Empty state
            let cardH: CGFloat = 70
            let card = makeCalCard(x: pad, y: y - cardH, w: cw, h: cardH)
            container.addSubview(card)

            let emoji = NSTextField(labelWithString: "No upcoming events")
            emoji.font = .systemFont(ofSize: 14, weight: .medium)
            emoji.textColor = Theme.textMuted
            emoji.alignment = .center
            emoji.frame = NSRect(x: 8, y: 30, width: cw - 16, height: 20)
            card.addSubview(emoji)

            let sub = NSTextField(labelWithString: "You're all clear!")
            sub.font = .systemFont(ofSize: 11, weight: .regular)
            sub.textColor = Theme.textFaint
            sub.alignment = .center
            sub.frame = NSRect(x: 8, y: 12, width: cw - 16, height: 16)
            card.addSubview(sub)

            y -= cardH + 8
            addCalDivider(in: container, y: &y, pad: pad, cw: cw)
            return y
        }

        let isCurrent = currentEvent != nil && hero == currentEvent
        let heroColor = eventAccentColor(hero)
        let cardH: CGFloat = config.showLocation && hero.location != nil && !hero.location!.isEmpty ? 94 : 78
        let card = makeCalCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Left accent bar
        let accentBar = NSView(frame: NSRect(x: 0, y: 4, width: 3, height: cardH - 8))
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = heroColor.cgColor
        accentBar.layer?.cornerRadius = 1.5
        card.addSubview(accentBar)

        var sy = cardH - 12

        // Status badge
        let statusText = isCurrent ? "NOW" : smartTimeUntil(hero.startDate)
        let statusColor = isCurrent ? Theme.red : heroColor
        let badge = NSTextField(labelWithString: statusText)
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = statusColor
        badge.frame = NSRect(x: 12, y: sy - 10, width: 120, height: 12)
        card.addSubview(badge)
        sy -= 16

        // Title
        let titleStr = hero.title ?? "Meeting"
        let titleLabel = NSTextField(labelWithString: titleStr)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 12, y: sy - 18, width: cw - 24, height: 18)
        card.addSubview(titleLabel)
        sy -= 22

        // Time range
        let timeStr: String
        if hero.isAllDay {
            timeStr = "All Day"
        } else if isCurrent {
            let minsLeft = max(Int(hero.endDate.timeIntervalSince(now) / 60), 0)
            timeStr = "\(formatTime(hero.startDate)) - \(formatTime(hero.endDate)) (\(minsLeft)m remaining)"
        } else {
            timeStr = "\(formatTime(hero.startDate)) - \(formatTime(hero.endDate))"
        }
        let timeLabel = NSTextField(labelWithString: timeStr)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = Theme.textSecondary
        timeLabel.frame = NSRect(x: 12, y: sy - 14, width: cw - 24, height: 14)
        card.addSubview(timeLabel)
        sy -= 16

        // Location
        if config.showLocationInDropdown, let loc = hero.location, !loc.isEmpty {
            let locLabel = NSTextField(labelWithString: loc)
            locLabel.font = .systemFont(ofSize: 10, weight: .regular)
            locLabel.textColor = Theme.textFaint
            locLabel.lineBreakMode = .byTruncatingTail
            locLabel.frame = NSRect(x: 12, y: sy - 12, width: cw - 24, height: 12)
            card.addSubview(locLabel)
            sy -= 14
        }

        // Calendar name (right-aligned top)
        if config.showCalendarName, let calName = hero.calendar?.title {
            let calLabel = NSTextField(labelWithString: calName)
            calLabel.font = .systemFont(ofSize: 9, weight: .medium)
            calLabel.textColor = heroColor.withAlphaComponent(0.7)
            calLabel.alignment = .right
            calLabel.frame = NSRect(x: cw - 130, y: cardH - 22, width: 120, height: 12)
            card.addSubview(calLabel)
        }

        y -= cardH + 8
        addCalDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Dropdown: Upcoming List

    private func buildUpcomingList(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let now = Date()

        let header = Theme.sectionHeader("UPCOMING")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 20

        // Gather events that aren't the hero
        let heroEvent = currentEvent ?? nextEvent
        let rest = upcomingEvents.filter { event in
            event != heroEvent && event.startDate > now.addingTimeInterval(-3600)
        }

        let visibleEvents = Array(rest.prefix(config.eventCount))

        if visibleEvents.isEmpty {
            let label = NSTextField(labelWithString: "No more events")
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = Theme.textFaint
            label.frame = NSRect(x: pad, y: y - 16, width: cw, height: 16)
            container.addSubview(label)
            y -= 22
        } else {
            for (i, event) in visibleEvents.enumerated() {
                let rowH: CGFloat = 28
                let rowBg = NSView(frame: NSRect(x: pad, y: y - rowH, width: cw, height: rowH))
                rowBg.wantsLayer = true
                rowBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.02 : 0.0).cgColor
                rowBg.layer?.cornerRadius = 4
                container.addSubview(rowBg)

                // Calendar color dot
                let dotColor = eventAccentColor(event)
                let dot = NSView(frame: NSRect(x: pad + 4, y: y - rowH + 10, width: 6, height: 6))
                dot.wantsLayer = true
                dot.layer?.backgroundColor = dotColor.cgColor
                dot.layer?.cornerRadius = 3
                container.addSubview(dot)

                // Time
                let timeStr: String
                if event.isAllDay {
                    timeStr = "All Day"
                } else {
                    timeStr = formatTime(event.startDate)
                }
                let timeLabel = NSTextField(labelWithString: timeStr)
                timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                timeLabel.textColor = Theme.textMuted
                timeLabel.frame = NSRect(x: pad + 16, y: y - rowH + 7, width: 65, height: 14)
                container.addSubview(timeLabel)

                // Title
                let titleText = event.title ?? "Event"
                let eventTitle = NSTextField(labelWithString: titleText)
                eventTitle.font = .systemFont(ofSize: 11, weight: .medium)
                eventTitle.textColor = Theme.textSecondary
                eventTitle.lineBreakMode = .byTruncatingTail
                eventTitle.frame = NSRect(x: pad + 82, y: y - rowH + 7, width: cw - 82 - 50, height: 14)
                container.addSubview(eventTitle)

                // Countdown
                let minsUntil = max(Int(event.startDate.timeIntervalSince(now) / 60), 0)
                let countdownStr: String
                if event.isAllDay {
                    countdownStr = ""
                } else {
                    countdownStr = shortCountdown(minsUntil)
                }
                if !countdownStr.isEmpty {
                    let cdLabel = NSTextField(labelWithString: countdownStr)
                    cdLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
                    cdLabel.textColor = Theme.textFaint
                    cdLabel.alignment = .right
                    cdLabel.frame = NSRect(x: pad + cw - 48, y: y - rowH + 8, width: 42, height: 12)
                    container.addSubview(cdLabel)
                }

                y -= rowH + (config.compactSpacing ? 1 : 4)
            }
        }

        return y
    }

    // MARK: - Dropdown: Footer

    @discardableResult
    private func buildCalFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y - 4
        addCalDivider(in: container, y: &y, pad: pad, cw: cw)

        let totalToday = upcomingEvents.filter { !$0.isAllDay }.count
        let footerText = "\(totalToday) event\(totalToday == 1 ? "" : "s") \u{00B7} \(config.lookahead.label)"
        let footer = NSTextField(labelWithString: footerText)
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost
        footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: - UI Helpers

    private func makeCalCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return v
    }

    private func addCalDivider(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.addSubview(d)
        y -= 8
    }
}

// MARK: - Declarative Config

extension CalendarNextWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Time + Title (2:30 PM Meeting)", value: "timeAndTitle"),
                (title: "Countdown (in 25m: Meeting)", value: "countdown"),
                (title: "Title Only", value: "titleOnly"),
                (title: "Compact (25m)", value: "compact"),
                (title: "Time Range (2:30-3:30 Meeting)", value: "timeRange"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "timeAndTitle" },
               set: { [weak self] in self?.config.displayMode = CalendarNextConfig.CalendarDisplayMode(rawValue: $0) ?? .timeAndTitle }),

            .toggle(label: "Show Time Until Event", key: "showTimeUntil",
                    get: { [weak self] in self?.config.showTimeUntil ?? true },
                    set: { [weak self] in self?.config.showTimeUntil = $0 }),

            .slider(label: "Max Title Length", key: "maxTitleLength", min: 10, max: 50, step: 5,
                    get: { [weak self] in Double(self?.config.maxTitleLength ?? 30) },
                    set: { [weak self] in self?.config.maxTitleLength = Int($0) },
                    format: "%.0f chars"),

            .section(title: "Appearance"),
            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Calendar Color", value: "calendarColor"),
                (title: "Fixed Accent", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "calendarColor" },
               set: { [weak self] in self?.config.colorMode = CalendarNextConfig.ColorMode(rawValue: $0) ?? .calendarColor }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "amber" },
               set: { [weak self] in self?.config.accentColor = CalendarNextConfig.AccentPreset(rawValue: $0) ?? .amber }),

            .section(title: "Events"),
            .picker(label: "Lookahead Period", key: "lookahead", options: [
                (title: "Today Only", value: "today"),
                (title: "24 Hours", value: "24h"),
                (title: "48 Hours", value: "48h"),
                (title: "7 Days", value: "7d"),
            ], get: { [weak self] in self?.config.lookahead.rawValue ?? "today" },
               set: { [weak self] in self?.config.lookahead = CalendarNextConfig.LookaheadPeriod(rawValue: $0) ?? .today }),

            .slider(label: "Events to Show", key: "eventCount", min: 1, max: 10, step: 1,
                    get: { [weak self] in Double(self?.config.eventCount ?? 5) },
                    set: { [weak self] in self?.config.eventCount = Int($0) },
                    format: "%.0f"),

            .slider(label: "Alert Before Event", key: "alertMinutes", min: 1, max: 30, step: 1,
                    get: { [weak self] in Double(self?.config.alertMinutes ?? 5) },
                    set: { [weak self] in self?.config.alertMinutes = Int($0) },
                    format: "%.0f min"),

            .toggle(label: "Show All-Day Events", key: "showAllDay",
                    get: { [weak self] in self?.config.showAllDay ?? false },
                    set: { [weak self] in self?.config.showAllDay = $0 }),

            .toggle(label: "Show Declined Events", key: "showDeclined",
                    get: { [weak self] in self?.config.showDeclined ?? false },
                    set: { [weak self] in self?.config.showDeclined = $0 }),

            .section(title: "Dropdown"),
            .toggle(label: "Show Location", key: "showLocationInDropdown",
                    get: { [weak self] in self?.config.showLocationInDropdown ?? true },
                    set: { [weak self] in self?.config.showLocationInDropdown = $0 }),

            .toggle(label: "Show Calendar Name", key: "showCalendarName",
                    get: { [weak self] in self?.config.showCalendarName ?? true },
                    set: { [weak self] in self?.config.showCalendarName = $0 }),

            .toggle(label: "Compact Spacing", key: "compactSpacing",
                    get: { [weak self] in self?.config.compactSpacing ?? false },
                    set: { [weak self] in self?.config.compactSpacing = $0 }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 5, max: 60, step: 5,
                    get: { [weak self] in self?.config.refreshRate ?? 5 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),

            .text(label: "Calendar Filter", key: "calendarFilter", placeholder: "Calendar IDs (comma-separated, empty = all)",
                  get: { [weak self] in self?.config.calendarFilter ?? "" },
                  set: { [weak self] in self?.config.calendarFilter = $0 }),
        ]
    }
}
