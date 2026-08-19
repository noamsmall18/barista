import Cocoa

// MARK: - Config

struct WorldClockConfig: Codable, Equatable {
    var displayMode: DisplayMode
    var use24Hour: Bool
    var showFlags: Bool
    var showSeconds: Bool
    var showDate: Bool
    var compactMode: Bool
    var highlightBusinessHours: Bool
    var showDayNight: Bool
    var showUTCOffset: Bool
    var separatorStyle: SeparatorStyle
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var refreshRate: TimeInterval

    // Stored arrays (backward compat with AppDelegate)
    var timezoneIDs: [String]
    var labels: [String]

    static let `default` = WorldClockConfig(
        displayMode: .text,
        use24Hour: false,
        showFlags: true,
        showSeconds: false,
        showDate: false,
        compactMode: false,
        highlightBusinessHours: true,
        showDayNight: true,
        showUTCOffset: true,
        separatorStyle: .pipe,
        accentColor: .cyan,
        colorMode: .fixed,
        refreshRate: 1,
        timezoneIDs: ["America/New_York", "Europe/London", "Asia/Tokyo"],
        labels: ["NYC", "LON", "TYO"]
    )

    // MARK: Enums

    enum DisplayMode: String, Codable, Equatable {
        case text       // "NYC 3:45 PM"
        case compact    // "3:45p"
        case flagsTime  // Flag + time
        case multiZone  // "NYC 3p | LON 8p | TYO 4a"
        case analogIcon // clock icon + time
    }

    enum SeparatorStyle: String, Codable, Equatable {
        case pipe  // |
        case dot   // .
        case dash  // -

        var character: String {
            switch self {
            case .pipe: return " | "
            case .dot:  return " \u{00B7} "
            case .dash: return " - "
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
        case dynamic // day=warm, night=cool tones
        case fixed   // always uses accentColor
    }

    // MARK: Timezone helpers

    /// Active timezones (non-empty entries)
    var activeTimezones: [String] {
        timezoneIDs.filter { !$0.isEmpty }
    }

    /// Labels matching active timezones, deriving from ID if label is empty
    var activeLabels: [String] {
        var result: [String] = []
        for (i, tzID) in timezoneIDs.enumerated() {
            guard !tzID.isEmpty else { continue }
            let lbl = i < labels.count ? labels[i] : ""
            result.append(lbl.isEmpty ? String(tzID.split(separator: "/").last ?? Substring(tzID)) : lbl)
        }
        return result
    }

    // Safe accessors for config fields (up to 6 slots)
    func tzAt(_ i: Int) -> String {
        i < timezoneIDs.count ? timezoneIDs[i] : ""
    }
    func labelAt(_ i: Int) -> String {
        i < labels.count ? labels[i] : ""
    }
    mutating func setTz(_ i: Int, _ val: String) {
        while timezoneIDs.count <= i { timezoneIDs.append("") }
        timezoneIDs[i] = val
    }
    mutating func setLabel(_ i: Int, _ val: String) {
        while labels.count <= i { labels.append("") }
        labels[i] = val
    }
}

// MARK: - Widget

class WorldClockWidget: BaristaWidget, Cycleable, InteractiveDropdown {
    static let widgetID = "world-clock"
    static let displayName = "World Clock"
    static let subtitle = "Multi-zone time with day/night and business hours"
    static let iconName = "clock"
    static let category = WidgetCategory.timeCalendar
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = WorldClockConfig.default

    var config: WorldClockConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    private(set) var displayIndex: Int = 0

    /// Offset hours from the time scroller (0 = now)
    private var scrollerOffset: Int = 0

    // MARK: - Cycleable

    var itemCount: Int { config.activeTimezones.count }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 4 }

    func cycleNext() {
        guard config.activeTimezones.count > 1 else { return }
        displayIndex = (displayIndex + 1) % config.activeTimezones.count
        onDisplayUpdate?()
    }

    required init(config: WorldClockConfig) {
        self.config = config
    }

    func start() {
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
        // Self-correcting timer
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        onDisplayUpdate?()
    }

    // MARK: - Accent color

    private var accent: NSColor {
        switch config.colorMode {
        case .fixed: return config.accentColor.color
        case .dynamic: return config.accentColor.color // could shift by hour
        }
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        let now = Date()
        let tzIDs = config.activeTimezones
        let lbls = config.activeLabels
        guard !tzIDs.isEmpty else { return .text("No zones") }

        switch config.displayMode {
        case .multiZone:
            return renderMultiZone(now: now, tzIDs: tzIDs, labels: lbls)

        case .compact:
            return renderCycling(now: now, tzIDs: tzIDs, labels: lbls, compact: true)

        case .flagsTime:
            return renderCycling(now: now, tzIDs: tzIDs, labels: lbls, flagsMode: true)

        case .analogIcon:
            return renderAnalogIcon(now: now, tzIDs: tzIDs, labels: lbls)

        case .text:
            return renderCycling(now: now, tzIDs: tzIDs, labels: lbls)
        }
    }

    private func renderMultiZone(now: Date, tzIDs: [String], labels: [String]) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        let sep = config.separatorStyle.character

        for (i, tzID) in tzIDs.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            if i > 0 {
                str.append(NSAttributedString(string: sep, attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: Theme.textFaint
                ]))
            }

            let label = i < labels.count ? labels[i] : ""
            let timeStr = formatTimeShort(for: tz, date: now)
            let prefix = config.showFlags ? flagForTimezone(tzID) + " " : (label + " ")
            let isDaytime = isDayTime(in: tz, at: now)
            let color = config.showDayNight ? (isDaytime ? accent : accent.withAlphaComponent(0.55)) : accent

            str.append(NSAttributedString(string: prefix, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Theme.textMuted
            ]))
            str.append(NSAttributedString(string: timeStr, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: color
            ]))
        }
        return .attributedText(str)
    }

    private func renderCycling(now: Date, tzIDs: [String], labels: [String], compact: Bool = false, flagsMode: Bool = false) -> WidgetDisplayMode {
        let idx = displayIndex % max(tzIDs.count, 1)
        guard idx < tzIDs.count, let tz = TimeZone(identifier: tzIDs[idx]) else {
            return .text("Invalid zone")
        }

        let label = idx < labels.count ? labels[idx] : ""
        let str = NSMutableAttributedString()

        if flagsMode {
            let flag = flagForTimezone(tzIDs[idx])
            str.append(NSAttributedString(string: flag + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 12)
            ]))
        } else if !compact {
            str.append(NSAttributedString(string: label + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: Theme.textMuted
            ]))
        }

        let timeStr = compact ? formatTimeShort(for: tz, date: now) : formatTime(for: tz, date: now)
        let isDaytime = isDayTime(in: tz, at: now)
        let color = config.showDayNight ? (isDaytime ? accent : accent.withAlphaComponent(0.55)) : accent

        str.append(NSAttributedString(string: timeStr, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]))

        if config.showDate && !compact {
            let dateStr = formatDateShort(for: tz, date: now)
            str.append(NSAttributedString(string: " " + dateStr, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]))
        }

        return .attributedText(str)
    }

    private func renderAnalogIcon(now: Date, tzIDs: [String], labels: [String]) -> WidgetDisplayMode {
        let idx = displayIndex % max(tzIDs.count, 1)
        guard idx < tzIDs.count, let tz = TimeZone(identifier: tzIDs[idx]) else {
            return .text("No zone")
        }

        let clockImg = renderMiniClock(for: tz, at: now, size: 16)
        let label = idx < labels.count ? labels[idx] : ""
        let timeStr = formatTime(for: tz, date: now)
        return .iconAndText(clockImg, "\(label) \(timeStr)")
    }

    // MARK: - Time Formatting

    private func formatTime(for tz: TimeZone, date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = tz
        if config.use24Hour {
            fmt.dateFormat = config.showSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            fmt.dateFormat = config.showSeconds ? "h:mm:ss a" : "h:mm a"
        }
        return fmt.string(from: date)
    }

    private func formatTimeShort(for tz: TimeZone, date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = tz
        if config.use24Hour {
            fmt.dateFormat = "HH:mm"
        } else {
            fmt.dateFormat = "h:mma"
        }
        return fmt.string(from: date).lowercased()
    }

    private func formatDateShort(for tz: TimeZone, date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = tz
        fmt.dateFormat = "EEE d"
        return fmt.string(from: date)
    }

    // MARK: - Day/Night & Business Hours

    private func isDayTime(in tz: TimeZone, at date: Date) -> Bool {
        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: date)
        return hour >= 6 && hour < 20
    }

    private func isBusinessHours(in tz: TimeZone, at date: Date) -> Bool {
        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date)
        return weekday >= 2 && weekday <= 6 && hour >= 9 && hour < 17
    }

    private func dayNightEmoji(in tz: TimeZone, at date: Date) -> String {
        isDayTime(in: tz, at: date) ? "\u{2600}\u{FE0F}" : "\u{1F319}"
    }

    // MARK: - Mini Analog Clock

    private func renderMiniClock(for tz: TimeZone, at date: Date, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - 2) / 2

        // Face
        let face = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: size - 2, height: size - 2))
        NSColor.white.withAlphaComponent(0.08).setFill()
        face.fill()
        accent.withAlphaComponent(0.5).setStroke()
        face.lineWidth = 1
        face.stroke()

        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)

        // Hour hand
        let hourAngle = (CGFloat(hour % 12) + CGFloat(minute) / 60.0) / 12.0 * 2 * .pi
        let hourLen = radius * 0.5
        let hourEnd = NSPoint(
            x: center.x + sin(hourAngle) * hourLen,
            y: center.y + cos(hourAngle) * hourLen
        )
        let hourPath = NSBezierPath()
        hourPath.move(to: center)
        hourPath.line(to: hourEnd)
        hourPath.lineWidth = 2
        hourPath.lineCapStyle = .round
        Theme.textPrimary.setStroke()
        hourPath.stroke()

        // Minute hand
        let minuteAngle = CGFloat(minute) / 60.0 * 2 * .pi
        let minuteLen = radius * 0.75
        let minuteEnd = NSPoint(
            x: center.x + sin(minuteAngle) * minuteLen,
            y: center.y + cos(minuteAngle) * minuteLen
        )
        let minutePath = NSBezierPath()
        minutePath.move(to: center)
        minutePath.line(to: minuteEnd)
        minutePath.lineWidth = 1
        minutePath.lineCapStyle = .round
        accent.setStroke()
        minutePath.stroke()

        // Center dot
        let dotR: CGFloat = 1.5
        let dotRect = NSRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)
        accent.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        img.unlockFocus()
        return img
    }

    // Larger analog clock for dropdown cards
    private func renderAnalogClock(for tz: TimeZone, at date: Date, size: CGFloat, color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - 4) / 2

        // Face circle
        let face = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size - 4, height: size - 4))
        NSColor.white.withAlphaComponent(0.05).setFill()
        face.fill()
        color.withAlphaComponent(0.3).setStroke()
        face.lineWidth = 1.5
        face.stroke()

        // Hour tick marks
        for i in 0..<12 {
            let angle = CGFloat(i) / 12.0 * 2 * .pi
            let inner = radius * 0.82
            let outer = radius * 0.95
            let p1 = NSPoint(x: center.x + sin(angle) * inner, y: center.y + cos(angle) * inner)
            let p2 = NSPoint(x: center.x + sin(angle) * outer, y: center.y + cos(angle) * outer)
            let tick = NSBezierPath()
            tick.move(to: p1)
            tick.line(to: p2)
            tick.lineWidth = i % 3 == 0 ? 1.5 : 0.8
            tick.lineCapStyle = .round
            (i % 3 == 0 ? Theme.textSecondary : Theme.textFaint).setStroke()
            tick.stroke()
        }

        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let second = cal.component(.second, from: date)

        // Hour hand
        let hourAngle = (CGFloat(hour % 12) + CGFloat(minute) / 60.0) / 12.0 * 2 * .pi
        let hourLen = radius * 0.5
        let hEnd = NSPoint(x: center.x + sin(hourAngle) * hourLen, y: center.y + cos(hourAngle) * hourLen)
        let hp = NSBezierPath()
        hp.move(to: center)
        hp.line(to: hEnd)
        hp.lineWidth = 2.5
        hp.lineCapStyle = .round
        Theme.textPrimary.setStroke()
        hp.stroke()

        // Minute hand
        let minAngle = CGFloat(minute) / 60.0 * 2 * .pi
        let minLen = radius * 0.75
        let mEnd = NSPoint(x: center.x + sin(minAngle) * minLen, y: center.y + cos(minAngle) * minLen)
        let mp = NSBezierPath()
        mp.move(to: center)
        mp.line(to: mEnd)
        mp.lineWidth = 1.5
        mp.lineCapStyle = .round
        color.setStroke()
        mp.stroke()

        // Second hand
        let secAngle = CGFloat(second) / 60.0 * 2 * .pi
        let secLen = radius * 0.85
        let sEnd = NSPoint(x: center.x + sin(secAngle) * secLen, y: center.y + cos(secAngle) * secLen)
        let sp = NSBezierPath()
        sp.move(to: center)
        sp.line(to: sEnd)
        sp.lineWidth = 0.8
        sp.lineCapStyle = .round
        NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 0.8).setStroke()
        sp.stroke()

        // Center dot
        let dotR: CGFloat = 2.5
        let dotRect = NSRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        img.unlockFocus()
        return img
    }

    // MARK: - Dropdown Menu (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "WORLD CLOCK", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())

        let now = Date()
        for (i, tzID) in config.activeTimezones.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            let label = i < config.activeLabels.count ? config.activeLabels[i] : ""
            let flag = flagForTimezone(tzID)
            let fmt = DateFormatter()
            fmt.timeZone = tz
            fmt.dateFormat = "h:mm:ss a"
            let timeStr = fmt.string(from: now)
            fmt.dateFormat = "EEE, MMM d"
            let dateStr = fmt.string(from: now)
            let offset = tz.secondsFromGMT(for: now)
            let hrs = offset / 3600
            let mins = abs(offset % 3600) / 60
            let utcStr = mins > 0 ? String(format: "UTC%+d:%02d", hrs, mins) : String(format: "UTC%+d", hrs)
            let bullet = i == displayIndex ? "\u{25B6}" : " "
            let title = "\(bullet) \(flag) \(label)    \(timeStr)    \(dateStr)    \(utcStr)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let copyItem = NSMenuItem(title: "Copy All Times", action: #selector(copyTimes), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func copyTimes() {
        let now = Date()
        var lines: [String] = []
        for (i, tzID) in config.activeTimezones.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            let label = i < config.activeLabels.count ? config.activeLabels[i] : ""
            let fmt = DateFormatter()
            fmt.timeZone = tz
            fmt.dateFormat = "h:mm a, EEE MMM d"
            lines.append("\(label): \(fmt.string(from: now))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }

    // MARK: - Interactive Dropdown Popover

    var dropdownSize: NSSize {
        let zoneCount = CGFloat(config.activeTimezones.count)
        let cardH: CGFloat = 72
        var h: CGFloat = 16 + 24 + 8 + zoneCount * (cardH + 6) + 8 + 50 + 16 + 30
        h += SuperWidgetKit.panelHeight + 8
        return NSSize(width: 380, height: min(max(h, 280), 780))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 380
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        // Header
        y = buildHeader(in: container, y: y, pad: pad, cw: cw)

        // Zone cards
        let now = Date()
        let displayDate = Calendar.current.date(byAdding: .hour, value: scrollerOffset, to: now) ?? now

        for (i, tzID) in config.activeTimezones.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            y = buildZoneCard(in: container, y: y, pad: pad, cw: cw, index: i, tzID: tzID, tz: tz, date: displayDate)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw, date: displayDate)
        y -= 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)

        // Time travel slider
        y = buildTimeTravel(in: container, y: y, pad: pad, cw: cw)

        // Footer
        buildFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    // MARK: - Dropdown Sections

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "World Clock")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 160, height: 20)
        container.addSubview(title)

        // Date label + offset indicator
        let now = Date()
        let displayDate = Calendar.current.date(byAdding: .hour, value: scrollerOffset, to: now) ?? now
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        let dateStr = scrollerOffset == 0 ? "Now" : fmt.string(from: displayDate)
        let offsetStr = scrollerOffset == 0 ? "" : " (\(scrollerOffset > 0 ? "+" : "")\(scrollerOffset)h)"

        let dateLbl = NSTextField(labelWithString: "\(dateStr)\(offsetStr)")
        dateLbl.font = .systemFont(ofSize: 10, weight: .medium)
        dateLbl.textColor = scrollerOffset == 0 ? Theme.textMuted : accent
        dateLbl.alignment = .right
        dateLbl.frame = NSRect(x: pad + 160, y: y - 18, width: cw - 160, height: 16)
        container.addSubview(dateLbl)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildZoneCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat, index: Int, tzID: String, tz: TimeZone, date: Date) -> CGFloat {
        let cardH: CGFloat = 72
        let isActive = index == displayIndex
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)

        if isActive {
            card.layer?.borderColor = accent.withAlphaComponent(0.3).cgColor
            card.layer?.borderWidth = 1
            card.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        }
        container.addSubview(card)

        let label = index < config.activeLabels.count ? config.activeLabels[index] : ""
        let flag = flagForTimezone(tzID)
        let isDaytime = isDayTime(in: tz, at: date)
        let isBiz = isBusinessHours(in: tz, at: date)

        // Analog clock face
        let clockSize: CGFloat = 48
        let clockColor = isActive ? accent : Theme.textMuted
        let clockImg = renderAnalogClock(for: tz, at: date, size: clockSize, color: clockColor)
        let clockView = NSImageView(frame: NSRect(x: 10, y: (cardH - clockSize) / 2, width: clockSize, height: clockSize))
        clockView.image = clockImg
        card.addSubview(clockView)

        // Name + flag row
        let nameX: CGFloat = clockSize + 18
        let nameW = cw - nameX - 8
        let dayNight = config.showDayNight ? (isDaytime ? " \u{2600}\u{FE0F}" : " \u{1F319}") : ""

        let nameLabel = NSTextField(labelWithString: "\(flag) \(label)\(dayNight)")
        nameLabel.font = .systemFont(ofSize: 13, weight: isActive ? .bold : .semibold)
        nameLabel.textColor = isActive ? accent : Theme.textPrimary
        nameLabel.frame = NSRect(x: nameX, y: cardH - 22, width: nameW, height: 18)
        card.addSubview(nameLabel)

        // Time (large)
        let timeFmt = DateFormatter()
        timeFmt.timeZone = tz
        timeFmt.dateFormat = config.use24Hour ? (config.showSeconds ? "HH:mm:ss" : "HH:mm") : (config.showSeconds ? "h:mm:ss a" : "h:mm a")
        let timeStr = timeFmt.string(from: date)

        let timeLabel = NSTextField(labelWithString: timeStr)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .heavy)
        timeLabel.textColor = isActive ? accent : Theme.textSecondary
        timeLabel.frame = NSRect(x: nameX, y: cardH - 44, width: nameW, height: 20)
        card.addSubview(timeLabel)

        // Bottom row: date | UTC offset | business hours | diff from local
        var infoparts: [String] = []

        let dateFmt = DateFormatter()
        dateFmt.timeZone = tz
        dateFmt.dateFormat = "EEE, MMM d"
        infoparts.append(dateFmt.string(from: date))

        if config.showUTCOffset {
            let offset = tz.secondsFromGMT(for: date)
            let hrs = offset / 3600
            let mins = abs(offset % 3600) / 60
            let utcStr = mins > 0 ? String(format: "UTC%+d:%02d", hrs, mins) : String(format: "UTC%+d", hrs)
            infoparts.append(utcStr)
        }

        if config.highlightBusinessHours {
            infoparts.append(isBiz ? "Open" : "Closed")
        }

        // Diff from local
        let localOffset = TimeZone.current.secondsFromGMT(for: date)
        let remoteOffset = tz.secondsFromGMT(for: date)
        let diffHours = (remoteOffset - localOffset) / 3600
        if diffHours != 0 {
            let diffStr = diffHours > 0 ? "+\(diffHours)h" : "\(diffHours)h"
            infoparts.append(diffStr)
        }

        let infoColor: NSColor
        if config.highlightBusinessHours && isBiz {
            infoColor = Theme.green
        } else {
            infoColor = Theme.textFaint
        }

        let infoStr = NSMutableAttributedString()
        for (j, part) in infoparts.enumerated() {
            if j > 0 {
                infoStr.append(NSAttributedString(string: "  \u{00B7}  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: Theme.textGhost
                ]))
            }
            let partColor: NSColor
            if config.highlightBusinessHours && part == "Open" {
                partColor = Theme.green
            } else if config.highlightBusinessHours && part == "Closed" {
                partColor = Theme.red.withAlphaComponent(0.6)
            } else {
                partColor = infoColor
            }
            infoStr.append(NSAttributedString(string: part, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: partColor
            ]))
        }

        let infoLabel = NSTextField(labelWithAttributedString: infoStr)
        infoLabel.frame = NSRect(x: nameX, y: 4, width: nameW, height: 14)
        card.addSubview(infoLabel)

        return y - cardH - 6
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat, date: Date) -> CGFloat {
        var validZones: [(id: String, tz: TimeZone, label: String)] = []
        for (idx, tzID) in config.activeTimezones.enumerated() {
            if let tz = TimeZone(identifier: tzID) {
                let label = idx < config.activeLabels.count ? config.activeLabels[idx] : tzID
                validZones.append((tzID, tz, label))
            }
        }

        let businessCount = validZones.filter { isBusinessHours(in: $0.tz, at: date) }.count
        let dayCount = validZones.filter { isDayTime(in: $0.tz, at: date) }.count
        let activeZone = validZones.indices.contains(displayIndex) ? validZones[displayIndex] : validZones.first
        let activeText = activeZone.map { "\($0.label) \(formatTimeShort(for: $0.tz, date: date))" } ?? "No zones"
        let localName = TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier
        let travelText = scrollerOffset == 0 ? "Now" : "\(scrollerOffset > 0 ? "+" : "")\(scrollerOffset)h"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Zones", value: "\(validZones.count)", color: accent),
                SuperWidgetMetric(label: "Open", value: "\(businessCount)", color: businessCount > 0 ? Theme.green : Theme.textMuted),
                SuperWidgetMetric(label: "Day", value: "\(dayCount)", color: Theme.textSecondary),
                SuperWidgetMetric(label: "Travel", value: travelText, color: scrollerOffset == 0 ? Theme.textMuted : accent)
            ],
            insights: [
                "Active \(activeText)",
                "Local \(localName)",
                "\(businessCount) business windows open"
            ],
            actions: [
                config.use24Hour ? "24-hour" : "12-hour",
                config.showSeconds ? "Seconds on" : "Seconds off",
                "Refresh \(Int(config.refreshRate))s"
            ],
            accent: accent
        )
    }

    private func buildTimeTravel(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("TIME TRAVEL")
        header.frame = NSRect(x: pad, y: y - 12, width: 100, height: 12)
        container.addSubview(header)

        let offsetLabel = NSTextField(labelWithString: scrollerOffset == 0 ? "Now" : "\(scrollerOffset > 0 ? "+" : "")\(scrollerOffset)h")
        offsetLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        offsetLabel.textColor = scrollerOffset == 0 ? Theme.textMuted : accent
        offsetLabel.alignment = .right
        offsetLabel.frame = NSRect(x: pad + cw - 80, y: y - 12, width: 80, height: 12)
        container.addSubview(offsetLabel)
        y -= 18

        let slider = NSSlider(frame: NSRect(x: pad, y: y - 20, width: cw - 60, height: 20))
        slider.minValue = -24
        slider.maxValue = 24
        slider.doubleValue = Double(scrollerOffset)
        slider.target = self
        slider.action = #selector(scrollerChanged(_:))
        slider.isContinuous = true
        container.addSubview(slider)

        let resetBtn = NSButton(frame: NSRect(x: pad + cw - 50, y: y - 22, width: 50, height: 24))
        resetBtn.title = "Now"
        resetBtn.bezelStyle = .inline
        resetBtn.font = .systemFont(ofSize: 10, weight: .medium)
        resetBtn.target = self
        resetBtn.action = #selector(resetScroller)
        container.addSubview(resetBtn)

        y -= 28
        return y
    }

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        let localTz = TimeZone.current
        let localName = localTz.localizedName(for: .standard, locale: .current) ?? localTz.identifier
        let footer = NSTextField(labelWithString: "Local: \(localName)")
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost
        footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: - Scroller Actions

    @objc private func scrollerChanged(_ sender: NSSlider) {
        scrollerOffset = Int(sender.doubleValue)
        onDisplayUpdate?()
    }

    @objc private func resetScroller() {
        scrollerOffset = 0
        onDisplayUpdate?()
    }

    // MARK: - UI Helpers

    private func makeCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return v
    }

    private func addDivider(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.addSubview(d)
        y -= 8
    }

    // MARK: - Flag Mapping

    private func flagForTimezone(_ tzID: String) -> String {
        let countryMap: [String: String] = [
            "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US",
            "America/Los_Angeles": "US", "America/Anchorage": "US", "Pacific/Honolulu": "US",
            "Europe/London": "GB", "Europe/Paris": "FR", "Europe/Berlin": "DE",
            "Europe/Rome": "IT", "Europe/Madrid": "ES", "Europe/Amsterdam": "NL",
            "Europe/Zurich": "CH", "Europe/Stockholm": "SE", "Europe/Oslo": "NO",
            "Europe/Moscow": "RU", "Europe/Istanbul": "TR",
            "Asia/Tokyo": "JP", "Asia/Shanghai": "CN", "Asia/Hong_Kong": "HK",
            "Asia/Seoul": "KR", "Asia/Singapore": "SG", "Asia/Dubai": "AE",
            "Asia/Kolkata": "IN", "Asia/Bangkok": "TH",
            "Australia/Sydney": "AU", "Pacific/Auckland": "NZ",
            "America/Toronto": "CA", "America/Sao_Paulo": "BR",
            "America/Mexico_City": "MX", "Africa/Johannesburg": "ZA",
            "Asia/Jerusalem": "IL", "Asia/Taipei": "TW",
        ]

        guard let code = countryMap[tzID] else { return "\u{1F310}" }
        let base: UInt32 = 127397
        let flag = code.unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }.map(String.init).joined()
        return flag
    }
}

// MARK: - Declarative Config

extension WorldClockWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Label + Time (NYC 3:45 PM)", value: "text"),
                (title: "Compact (3:45p)", value: "compact"),
                (title: "Flag + Time", value: "flagsTime"),
                (title: "Multi-Zone (NYC 3p | LON 8p)", value: "multiZone"),
                (title: "Analog Clock Icon", value: "analogIcon"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "text" },
               set: { [weak self] in self?.config.displayMode = WorldClockConfig.DisplayMode(rawValue: $0) ?? .text }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (day/night tint)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "fixed" },
               set: { [weak self] in self?.config.colorMode = WorldClockConfig.ColorMode(rawValue: $0) ?? .fixed }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "cyan" },
               set: { [weak self] in self?.config.accentColor = WorldClockConfig.AccentPreset(rawValue: $0) ?? .cyan }),

            .picker(label: "Separator Style", key: "separatorStyle", options: [
                (title: "Pipe ( | )", value: "pipe"),
                (title: "Dot ( . )", value: "dot"),
                (title: "Dash ( - )", value: "dash"),
            ], get: { [weak self] in self?.config.separatorStyle.rawValue ?? "pipe" },
               set: { [weak self] in self?.config.separatorStyle = WorldClockConfig.SeparatorStyle(rawValue: $0) ?? .pipe }),

            .section(title: "Time Format"),
            .toggle(label: "24-Hour Format", key: "use24Hour",
                    get: { [weak self] in self?.config.use24Hour ?? false },
                    set: { [weak self] in self?.config.use24Hour = $0 }),
            .toggle(label: "Show Seconds", key: "showSeconds",
                    get: { [weak self] in self?.config.showSeconds ?? false },
                    set: { [weak self] in self?.config.showSeconds = $0 }),
            .toggle(label: "Show Date", key: "showDate",
                    get: { [weak self] in self?.config.showDate ?? false },
                    set: { [weak self] in self?.config.showDate = $0 }),

            .section(title: "Indicators"),
            .toggle(label: "Show Flags", key: "showFlags",
                    get: { [weak self] in self?.config.showFlags ?? true },
                    set: { [weak self] in self?.config.showFlags = $0 }),
            .toggle(label: "Day/Night Indicator", key: "showDayNight",
                    get: { [weak self] in self?.config.showDayNight ?? true },
                    set: { [weak self] in self?.config.showDayNight = $0 }),
            .toggle(label: "Show UTC Offset", key: "showUTCOffset",
                    get: { [weak self] in self?.config.showUTCOffset ?? true },
                    set: { [weak self] in self?.config.showUTCOffset = $0 }),
            .toggle(label: "Highlight Business Hours", key: "highlightBusinessHours",
                    get: { [weak self] in self?.config.highlightBusinessHours ?? true },
                    set: { [weak self] in self?.config.highlightBusinessHours = $0 }),
            .toggle(label: "Compact Menu Bar", key: "compactMode",
                    get: { [weak self] in self?.config.compactMode ?? false },
                    set: { [weak self] in self?.config.compactMode = $0 }),

            .section(title: "Timezones"),
            .text(label: "Zone 1", key: "tz0", placeholder: "America/New_York",
                  get: { [weak self] in self?.config.tzAt(0) ?? "" },
                  set: { [weak self] in self?.config.setTz(0, $0) }),
            .text(label: "Label 1", key: "label0", placeholder: "NYC",
                  get: { [weak self] in self?.config.labelAt(0) ?? "" },
                  set: { [weak self] in self?.config.setLabel(0, $0) }),
            .text(label: "Zone 2", key: "tz1", placeholder: "Europe/London",
                  get: { [weak self] in self?.config.tzAt(1) ?? "" },
                  set: { [weak self] in self?.config.setTz(1, $0) }),
            .text(label: "Label 2", key: "label1", placeholder: "LON",
                  get: { [weak self] in self?.config.labelAt(1) ?? "" },
                  set: { [weak self] in self?.config.setLabel(1, $0) }),
            .text(label: "Zone 3", key: "tz2", placeholder: "Asia/Tokyo",
                  get: { [weak self] in self?.config.tzAt(2) ?? "" },
                  set: { [weak self] in self?.config.setTz(2, $0) }),
            .text(label: "Label 3", key: "label2", placeholder: "TYO",
                  get: { [weak self] in self?.config.labelAt(2) ?? "" },
                  set: { [weak self] in self?.config.setLabel(2, $0) }),
            .text(label: "Zone 4", key: "tz3", placeholder: "Asia/Shanghai",
                  get: { [weak self] in self?.config.tzAt(3) ?? "" },
                  set: { [weak self] in self?.config.setTz(3, $0) }),
            .text(label: "Label 4", key: "label3", placeholder: "SHA",
                  get: { [weak self] in self?.config.labelAt(3) ?? "" },
                  set: { [weak self] in self?.config.setLabel(3, $0) }),
            .text(label: "Zone 5", key: "tz4", placeholder: "America/Los_Angeles",
                  get: { [weak self] in self?.config.tzAt(4) ?? "" },
                  set: { [weak self] in self?.config.setTz(4, $0) }),
            .text(label: "Label 5", key: "label4", placeholder: "LAX",
                  get: { [weak self] in self?.config.labelAt(4) ?? "" },
                  set: { [weak self] in self?.config.setLabel(4, $0) }),
            .text(label: "Zone 6", key: "tz5", placeholder: "Australia/Sydney",
                  get: { [weak self] in self?.config.tzAt(5) ?? "" },
                  set: { [weak self] in self?.config.setTz(5, $0) }),
            .text(label: "Label 6", key: "label5", placeholder: "SYD",
                  get: { [weak self] in self?.config.labelAt(5) ?? "" },
                  set: { [weak self] in self?.config.setLabel(5, $0) }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 60, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 1 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
        ]
    }
}
