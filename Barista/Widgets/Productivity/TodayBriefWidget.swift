import Cocoa
import EventKit

struct TodayBriefConfig: Codable, Equatable {
    var refreshRate: TimeInterval = 5
    var eventCount: Int = 6
    var includeAllDay: Bool = true
    var includeDeclined: Bool = false
    var showMeetingLoad: Bool = true
    var compactMode: Bool = false

    static let `default` = TodayBriefConfig()
}

class TodayBriefWidget: BaristaWidget {
    static let widgetID = "today-brief"
    static let displayName = "Today Brief"
    static let subtitle = "Agenda, open windows, meeting load and day status"
    static let iconName = "sun.max.circle"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = TodayBriefConfig.default

    var config: TodayBriefConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    private let store = EKEventStore()

    private(set) var hasAccess = false
    private(set) var events: [EKEvent] = []
    private(set) var currentEvent: EKEvent?
    private(set) var nextEvent: EKEvent?
    private(set) var meetingMinutes: Int = 0
    private(set) var openWindowText = "Calculating"
    private(set) var dayScore = 100

    required init(config: TodayBriefConfig) {
        self.config = config
    }

    func start() {
        requestAccess()
        currentTimerInterval = config.refreshRate
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
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

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.hasAccess = granted
                    self?.fetchEvents()
                    self?.onDisplayUpdate?()
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.hasAccess = granted
                    self?.fetchEvents()
                    self?.onDisplayUpdate?()
                }
            }
        }
    }

    private func fetchEvents() {
        guard hasAccess else { return }
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var fetched = store.events(matching: predicate)

        if !config.includeAllDay {
            fetched = fetched.filter { !$0.isAllDay }
        }
        if !config.includeDeclined {
            fetched = fetched.filter { event in
                guard let attendees = event.attendees else { return true }
                let me = attendees.first { $0.isCurrentUser }
                return me?.participantStatus != .declined
            }
        }

        fetched.sort { $0.startDate < $1.startDate }
        events = fetched
        currentEvent = fetched.first { !$0.isAllDay && $0.startDate <= now && $0.endDate > now }
        nextEvent = fetched.first { !$0.isAllDay && $0.startDate > now }
        meetingMinutes = fetched
            .filter { !$0.isAllDay }
            .reduce(0) { total, event in total + max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), 0) }
        openWindowText = computeOpenWindow(now: now, endOfDay: end, events: fetched.filter { !$0.isAllDay })
        computeDayScore()
    }

    private func computeOpenWindow(now: Date, endOfDay: Date, events: [EKEvent]) -> String {
        var cursor = now
        for event in events where event.endDate > now {
            if event.startDate > cursor {
                let gap = Int(event.startDate.timeIntervalSince(cursor) / 60)
                if gap >= 30 {
                    return "\(formatDuration(gap)) open now"
                }
            }
            if event.endDate > cursor {
                cursor = event.endDate
            }
        }
        let finalGap = Int(endOfDay.timeIntervalSince(cursor) / 60)
        if finalGap >= 30 { return "\(formatDuration(finalGap)) later" }
        return "Packed day"
    }

    private func computeDayScore() {
        let allDayCount = events.filter { $0.isAllDay }.count
        var score = 100
        score -= min(meetingMinutes / 8, 45)
        score -= min(max(events.count - 6, 0) * 4, 24)
        score -= min(allDayCount * 2, 8)
        if currentEvent != nil { score -= 5 }
        dayScore = max(min(score, 100), 0)
    }

    func render() -> WidgetDisplayMode {
        if !hasAccess { return .text("TODAY --") }
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: config.compactMode ? "DAY " : "TODAY ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.textMuted
        ]))
        str.append(NSAttributedString(string: "\(events.count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: scoreColor
        ]))
        if !config.compactMode {
            str.append(NSAttributedString(string: " \(formatDuration(meetingMinutes))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Theme.textFaint
            ]))
        }
        return .attributedText(str)
    }

    private var scoreColor: NSColor {
        if dayScore >= 75 { return Theme.green }
        if dayScore >= 50 { return Theme.orange }
        return Theme.red
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "TODAY BRIEF", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

extension TodayBriefWidget: InteractiveDropdown {
    var dropdownSize: NSSize { NSSize(width: 360, height: 560) }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 360
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)

        guard hasAccess else {
            y = buildAccessCard(in: container, y: y, pad: pad, cw: cw)
            y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
            buildFooter(in: container, y: y, pad: pad, cw: cw)
            return container
        }

        y = buildScoreCard(in: container, y: y, pad: pad, cw: cw)
        y = buildAgenda(in: container, y: y, pad: pad, cw: cw)
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let title = NSTextField(labelWithString: "Today Brief")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 180, height: 20)
        container.addSubview(title)

        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let date = NSTextField(labelWithString: df.string(from: Date()))
        date.font = .systemFont(ofSize: 10, weight: .semibold)
        date.textColor = scoreColor
        date.alignment = .right
        date.frame = NSRect(x: pad + cw - 120, y: y - 18, width: 120, height: 16)
        container.addSubview(date)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildAccessCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let card = makeCard(x: pad, y: y - 74, w: cw, h: 74)
        container.addSubview(card)
        let label = NSTextField(labelWithString: "Calendar access required")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.textSecondary
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 38, width: cw - 20, height: 18)
        card.addSubview(label)
        let hint = NSTextField(labelWithString: "Grant access in System Settings to unlock the day terminal")
        hint.font = .systemFont(ofSize: 10, weight: .regular)
        hint.textColor = Theme.textFaint
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 10, y: 18, width: cw - 20, height: 14)
        card.addSubview(hint)
        y -= 82
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildScoreCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 92
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let score = NSTextField(labelWithString: "\(dayScore)")
        score.font = .monospacedDigitSystemFont(ofSize: 34, weight: .heavy)
        score.textColor = scoreColor
        score.frame = NSRect(x: 16, y: 38, width: 80, height: 38)
        card.addSubview(score)

        let scoreLabel = NSTextField(labelWithString: "day score")
        scoreLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        scoreLabel.textColor = Theme.textFaint
        scoreLabel.frame = NSRect(x: 18, y: 24, width: 80, height: 12)
        card.addSubview(scoreLabel)

        let current = currentEvent?.title ?? "No current event"
        let next = nextEvent.map { "\($0.title ?? "Event") at \(formatTime($0.startDate))" } ?? "No later event"
        let rows = [
            ("Now", current, currentEvent == nil ? Theme.textMuted : Theme.green),
            ("Next", next, nextEvent == nil ? Theme.textMuted : Theme.textSecondary),
            ("Open", openWindowText, scoreColor)
        ]
        var sy = cardH - 20
        for (label, value, color) in rows {
            addRow(in: card, label: label, value: value, color: color, x: 104, y: sy, w: cw - 116)
            sy -= 22
        }

        y -= cardH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildAgenda(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let header = Theme.sectionHeader("AGENDA")
        header.frame = NSRect(x: pad, y: y - 12, width: 100, height: 12)
        container.addSubview(header)
        y -= 18

        let visible = Array(events.prefix(config.eventCount))
        if visible.isEmpty {
            let empty = NSTextField(labelWithString: "No events today")
            empty.font = .systemFont(ofSize: 11, weight: .medium)
            empty.textColor = Theme.textFaint
            empty.frame = NSRect(x: pad, y: y - 16, width: cw, height: 16)
            container.addSubview(empty)
            y -= 24
            return y
        }

        for event in visible {
            let rowH: CGFloat = 28
            let bg = NSView(frame: NSRect(x: pad, y: y - rowH, width: cw, height: rowH))
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 5
            bg.layer?.backgroundColor = NSColor.white.withAlphaComponent(event == currentEvent ? 0.06 : 0.02).cgColor
            container.addSubview(bg)

            let time = event.isAllDay ? "All day" : formatTime(event.startDate)
            let timeLabel = NSTextField(labelWithString: time)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            timeLabel.textColor = event == currentEvent ? Theme.green : Theme.textMuted
            timeLabel.frame = NSRect(x: pad + 8, y: y - rowH + 7, width: 58, height: 14)
            container.addSubview(timeLabel)

            let title = NSTextField(labelWithString: event.title ?? "Event")
            title.font = .systemFont(ofSize: 11, weight: event == currentEvent ? .semibold : .medium)
            title.textColor = Theme.textSecondary
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: pad + 70, y: y - rowH + 7, width: cw - 78, height: 14)
            container.addSubview(title)

            y -= rowH + 4
        }

        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let allDay = events.filter { $0.isAllDay }.count
        let timed = events.count - allDay
        let nextText = nextEvent.map { "\($0.title ?? "Event") \(formatTime($0.startDate))" } ?? "No upcoming event"
        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            title: "DAY TERMINAL",
            metrics: [
                SuperWidgetMetric(label: "Score", value: "\(dayScore)", color: scoreColor),
                SuperWidgetMetric(label: "Events", value: "\(events.count)", color: Theme.textSecondary),
                SuperWidgetMetric(label: "Meetings", value: formatDuration(meetingMinutes), color: meetingMinutes > 240 ? Theme.orange : Theme.green),
                SuperWidgetMetric(label: "Open", value: openWindowText.replacingOccurrences(of: " open now", with: ""), color: scoreColor)
            ],
            insights: [
                nextText,
                "\(timed) timed / \(allDay) all-day",
                currentEvent == nil ? "No active meeting" : "Currently in \(currentEvent?.title ?? "event")"
            ],
            actions: [
                "Showing \(config.eventCount)",
                config.includeDeclined ? "Declined visible" : "Declined hidden",
                "Refresh \(Int(config.refreshRate))s"
            ],
            accent: scoreColor
        )
    }

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let footer = NSTextField(labelWithString: "Agenda plus open-window signal")
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost
        footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 18, width: cw, height: 14)
        container.addSubview(footer)
        return y - 20
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    private func makeCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.cardBg.cgColor
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = Theme.cardBorder.cgColor
        return view
    }

    private func addDivider(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let line = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.cardBorder.cgColor
        container.addSubview(line)
        y -= 8
    }

    private func addRow(in parent: NSView, label: String, value: String, color: NSColor, x: CGFloat, y: CGFloat, w: CGFloat) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 9, weight: .semibold)
        labelView.textColor = Theme.textFaint
        labelView.frame = NSRect(x: x, y: y - 12, width: 42, height: 12)
        parent.addSubview(labelView)

        let valueView = NSTextField(labelWithString: value)
        valueView.font = .systemFont(ofSize: 10.5, weight: .medium)
        valueView.textColor = color
        valueView.lineBreakMode = .byTruncatingTail
        valueView.frame = NSRect(x: x + 44, y: y - 13, width: w - 44, height: 14)
        parent.addSubview(valueView)
    }
}

extension TodayBriefWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .toggle(label: "Compact Menu Bar", key: "compactMode",
                    get: { [weak self] in self?.config.compactMode ?? false },
                    set: { [weak self] in self?.config.compactMode = $0 }),
            .toggle(label: "Include All-Day Events", key: "includeAllDay",
                    get: { [weak self] in self?.config.includeAllDay ?? true },
                    set: { [weak self] in self?.config.includeAllDay = $0 }),
            .toggle(label: "Include Declined Events", key: "includeDeclined",
                    get: { [weak self] in self?.config.includeDeclined ?? false },
                    set: { [weak self] in self?.config.includeDeclined = $0 }),
            .slider(label: "Events Shown", key: "eventCount", min: 3, max: 10, step: 1,
                    get: { [weak self] in Double(self?.config.eventCount ?? 6) },
                    set: { [weak self] in self?.config.eventCount = Int($0) },
                    format: "%.0f"),
            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 5, max: 60, step: 5,
                    get: { [weak self] in self?.config.refreshRate ?? 5 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s")
        ]
    }
}
