import Cocoa

// MARK: - Config

struct PomodoroConfig: Codable, Equatable {
    var displayMode: PomodoroDisplayMode
    var workMinutes: Int
    var shortBreakMinutes: Int
    var longBreakMinutes: Int
    var cyclesBeforeLong: Int
    var autoStartBreak: Bool
    var autoStartWork: Bool
    var showEmoji: Bool
    var showSessionCount: Bool
    var soundEnabled: Bool
    var targetDaily: Int
    var refreshRate: TimeInterval
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var sessionLabel: String

    static let `default` = PomodoroConfig(
        displayMode: .text,
        workMinutes: 25,
        shortBreakMinutes: 5,
        longBreakMinutes: 15,
        cyclesBeforeLong: 4,
        autoStartBreak: true,
        autoStartWork: false,
        showEmoji: true,
        showSessionCount: true,
        soundEnabled: true,
        targetDaily: 8,
        refreshRate: 1,
        accentColor: .red,
        colorMode: .dynamic,
        sessionLabel: "Focus"
    )

    enum PomodoroDisplayMode: String, Codable, Equatable {
        case text       // "Work 12:34"
        case compact    // "12:34"
        case ring       // ring gauge
        case progressBar // thin bar + time
        case emojiTime  // emoji + time
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
        case dynamic // shifts based on timer progress
        case fixed   // always uses accentColor
    }
}

// MARK: - State

enum PomodoroState: String, Codable {
    case idle
    case working
    case shortBreak
    case longBreak
}

// MARK: - Widget

class PomodoroWidget: BaristaWidget {
    static let widgetID = "pomodoro"
    static let displayName = "Focus Timer"
    static let subtitle = "Pomodoro focus timer with stats & history"
    static let iconName = "timer"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = PomodoroConfig.default

    var config: PomodoroConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { nil }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    // Timer state - Date-based for accuracy
    private(set) var state: PomodoroState = .idle
    private(set) var secondsRemaining: Int = 0
    private var phaseEndDate: Date?
    private var phaseDuration: Int = 0

    // Session tracking
    private(set) var completedCycles: Int = 0
    private(set) var totalFocusToday: Int = 0 // seconds
    private(set) var dailyCompleted: Int = 0
    private(set) var currentStreak: Int = 0
    private(set) var bestStreak: Int = 0

    // History
    private(set) var sessionDurations: [Double] = [] // minutes per completed session
    private(set) var dailyHistory: [Double] = [] // sessions per day (last 7 days)

    required init(config: PomodoroConfig) {
        self.config = config
        restoreState()
    }

    func start() {
        let rate = config.refreshRate
        currentTimerInterval = rate
        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.tick()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

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

        guard state != .idle else { return }

        // Date-based remaining time for accuracy
        if let endDate = phaseEndDate {
            let remaining = endDate.timeIntervalSinceNow
            secondsRemaining = max(Int(ceil(remaining)), 0)
        }

        if state == .working {
            totalFocusToday += Int(config.refreshRate)
            saveFocusTime()
        }

        if secondsRemaining <= 0 {
            handlePhaseComplete()
        }

        onDisplayUpdate?()
    }

    // MARK: - Phase Management

    private func handlePhaseComplete() {
        if config.soundEnabled {
            NSSound.beep()
        }

        switch state {
        case .working:
            completedCycles += 1
            dailyCompleted += 1
            currentStreak += 1
            if currentStreak > bestStreak { bestStreak = currentStreak }
            sessionDurations.append(Double(config.workMinutes))
            while sessionDurations.count > 50 { sessionDurations.removeFirst() }
            saveState()

            if completedCycles % config.cyclesBeforeLong == 0 {
                if config.autoStartBreak {
                    startPhase(.longBreak)
                } else {
                    state = .idle
                    phaseEndDate = nil
                }
            } else {
                if config.autoStartBreak {
                    startPhase(.shortBreak)
                } else {
                    state = .idle
                    phaseEndDate = nil
                }
            }
        case .shortBreak, .longBreak:
            if config.autoStartWork {
                startPhase(.working)
            } else {
                state = .idle
                phaseEndDate = nil
            }
        case .idle:
            break
        }
    }

    func startWork() {
        startPhase(.working)
        onDisplayUpdate?()
    }

    func pauseResume() {
        if state == .idle {
            startWork()
        } else {
            state = .idle
            phaseEndDate = nil
            onDisplayUpdate?()
        }
    }

    func skipPhase() {
        handlePhaseComplete()
        onDisplayUpdate?()
    }

    func resetTimer() {
        state = .idle
        secondsRemaining = 0
        phaseEndDate = nil
        completedCycles = 0
        currentStreak = 0
        onDisplayUpdate?()
    }

    private func startPhase(_ phase: PomodoroState) {
        state = phase
        switch phase {
        case .working:
            phaseDuration = config.workMinutes * 60
        case .shortBreak:
            phaseDuration = config.shortBreakMinutes * 60
        case .longBreak:
            phaseDuration = config.longBreakMinutes * 60
        case .idle:
            phaseDuration = 0
        }
        secondsRemaining = phaseDuration
        phaseEndDate = Date().addingTimeInterval(TimeInterval(phaseDuration))
    }

    // MARK: - Progress

    var progress: Double {
        guard phaseDuration > 0, state != .idle else { return 0 }
        return 1.0 - (Double(secondsRemaining) / Double(phaseDuration))
    }

    var dailyProgress: Double {
        guard config.targetDaily > 0 else { return 0 }
        return min(Double(dailyCompleted) / Double(config.targetDaily), 1.0)
    }

    // MARK: - Color

    func accentColor() -> NSColor {
        switch config.colorMode {
        case .fixed:
            return config.accentColor.color
        case .dynamic:
            return dynamicColor()
        }
    }

    private func dynamicColor() -> NSColor {
        switch state {
        case .idle:
            return Theme.textMuted
        case .working:
            let t = progress
            if t < 0.5 {
                return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) // green
            } else if t < 0.8 {
                return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1) // amber
            } else {
                return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1) // red
            }
        case .shortBreak:
            return NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1) // blue
        case .longBreak:
            return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1) // purple
        }
    }

    private func stateLabel() -> String {
        switch state {
        case .idle: return "Ready"
        case .working: return config.sessionLabel
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }

    private func stateEmoji() -> String {
        switch state {
        case .idle: return "\u{1F345}"
        case .working: return "\u{1F345}"
        case .shortBreak: return "\u{2615}"
        case .longBreak: return "\u{1F3D6}"
        }
    }

    private func timeString() -> String {
        let min = secondsRemaining / 60
        let sec = secondsRemaining % 60
        return String(format: "%d:%02d", min, sec)
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        let color = accentColor()

        switch config.displayMode {
        case .text:
            return renderText(color: color)
        case .compact:
            return renderCompact(color: color)
        case .ring:
            return renderRingMode(color: color)
        case .progressBar:
            return renderProgressBarMode(color: color)
        case .emojiTime:
            return renderEmojiTime(color: color)
        }
    }

    private func renderText(color: NSColor) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        let label = state == .idle ? "Ready" : stateLabel()
        str.append(NSAttributedString(string: "\(label) ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5)
        ]))
        if state != .idle {
            str.append(NSAttributedString(string: timeString(), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: color
            ]))
        }
        if config.showSessionCount && completedCycles > 0 {
            str.append(NSAttributedString(string: " x\(completedCycles)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]))
        }
        return .attributedText(str)
    }

    private func renderCompact(color: NSColor) -> WidgetDisplayMode {
        if state == .idle {
            let str = NSMutableAttributedString()
            if config.showEmoji {
                str.append(NSAttributedString(string: "\u{1F345} ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11)
                ]))
            }
            if completedCycles > 0 {
                str.append(NSAttributedString(string: "x\(completedCycles)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: Theme.textMuted
                ]))
            } else {
                str.append(NSAttributedString(string: "Ready", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Theme.textMuted
                ]))
            }
            return .attributedText(str)
        }

        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: timeString(), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]))
        return .attributedText(str)
    }

    private func renderRingMode(color: NSColor) -> WidgetDisplayMode {
        let ringImg = renderGradientRing(pct: progress * 100, size: 18, lineWidth: 2.5)
        var label = state == .idle ? "Ready" : timeString()
        if config.showSessionCount && completedCycles > 0 {
            label += " x\(completedCycles)"
        }
        return .iconAndText(ringImg, label)
    }

    private func renderProgressBarMode(color: NSColor) -> WidgetDisplayMode {
        let barImg = renderMenuBarStrip(width: 32, height: 10)
        var label = state == .idle ? " Ready" : " \(timeString())"
        if config.showSessionCount && completedCycles > 0 {
            label += " x\(completedCycles)"
        }
        return .iconAndText(barImg, label)
    }

    private func renderEmojiTime(color: NSColor) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: "\(stateEmoji()) ", attributes: [
            .font: NSFont.systemFont(ofSize: 11)
        ]))
        if state == .idle {
            if completedCycles > 0 {
                str.append(NSAttributedString(string: "x\(completedCycles)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: Theme.textMuted
                ]))
            } else {
                str.append(NSAttributedString(string: "Ready", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Theme.textMuted
                ]))
            }
        } else {
            str.append(NSAttributedString(string: timeString(), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: color
            ]))
        }
        return .attributedText(str)
    }

    // MARK: - Custom Renders

    private func renderGradientRing(pct: Double, size: CGFloat, lineWidth: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.08).setStroke()
        track.stroke()

        let sweep = CGFloat(min(pct, 100) / 100.0 * 360.0)
        let endAngle: CGFloat = 90 - sweep
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: endAngle, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        accentColor().setStroke()
        arc.stroke()

        img.unlockFocus()
        return img
    }

    private func renderMenuBarStrip(width: CGFloat, height: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()

        let bgRect = NSRect(x: 0, y: 1, width: width, height: height - 2)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.08).setFill()
        bg.fill()

        let fillW = max(CGFloat(progress) * (width - 2), 1)
        let fillRect = NSRect(x: 1, y: 2, width: fillW, height: height - 4)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        accentColor().withAlphaComponent(0.8).setFill()
        fill.fill()

        img.unlockFocus()
        return img
    }

    // MARK: - Dropdown (fallback NSMenu)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "POMODORO", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())

        let stateStr = stateLabel()
        let statusItem = NSMenuItem(title: "Status: \(stateStr)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if state != .idle {
            let timeItem = NSMenuItem(title: "Time left: \(timeString())", action: nil, keyEquivalent: "")
            timeItem.isEnabled = false
            menu.addItem(timeItem)
        }

        let cycleItem = NSMenuItem(title: "Completed: \(completedCycles) sessions", action: nil, keyEquivalent: "")
        cycleItem.isEnabled = false
        menu.addItem(cycleItem)

        let focusMin = totalFocusToday / 60
        let focusItem = NSMenuItem(title: "Focus today: \(focusMin)m", action: nil, keyEquivalent: "")
        focusItem.isEnabled = false
        menu.addItem(focusItem)

        menu.addItem(NSMenuItem.separator())

        if state == .idle {
            menu.addItem(NSMenuItem(title: "Start Focus", action: #selector(AppDelegate.pomodoroStart), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Stop", action: #selector(AppDelegate.pomodoroStop), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Skip Phase", action: #selector(AppDelegate.pomodoroSkip), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(AppDelegate.pomodoroReset), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }

    // MARK: - Persistence

    private func dateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func saveFocusTime() {
        UserDefaults.standard.set(totalFocusToday, forKey: "barista.pomodoro.focusToday")
        UserDefaults.standard.set(dateString(), forKey: "barista.pomodoro.focusDate")
    }

    private func saveState() {
        UserDefaults.standard.set(dailyCompleted, forKey: "barista.pomodoro.dailyCompleted")
        UserDefaults.standard.set(currentStreak, forKey: "barista.pomodoro.currentStreak")
        UserDefaults.standard.set(bestStreak, forKey: "barista.pomodoro.bestStreak")
        UserDefaults.standard.set(completedCycles, forKey: "barista.pomodoro.completedCycles")

        if let data = try? JSONEncoder().encode(sessionDurations) {
            UserDefaults.standard.set(data, forKey: "barista.pomodoro.sessionDurations")
        }
        if let data = try? JSONEncoder().encode(dailyHistory) {
            UserDefaults.standard.set(data, forKey: "barista.pomodoro.dailyHistory")
        }
    }

    private func restoreState() {
        let savedDate = UserDefaults.standard.string(forKey: "barista.pomodoro.focusDate") ?? ""
        let today = dateString()
        if savedDate == today {
            totalFocusToday = UserDefaults.standard.integer(forKey: "barista.pomodoro.focusToday")
            dailyCompleted = UserDefaults.standard.integer(forKey: "barista.pomodoro.dailyCompleted")
        } else {
            // New day - push yesterday's count to daily history
            let yesterdayCount = UserDefaults.standard.integer(forKey: "barista.pomodoro.dailyCompleted")
            if yesterdayCount > 0 {
                dailyHistory.append(Double(yesterdayCount))
                while dailyHistory.count > 7 { dailyHistory.removeFirst() }
            }
        }
        currentStreak = UserDefaults.standard.integer(forKey: "barista.pomodoro.currentStreak")
        bestStreak = UserDefaults.standard.integer(forKey: "barista.pomodoro.bestStreak")
        completedCycles = UserDefaults.standard.integer(forKey: "barista.pomodoro.completedCycles")

        if let data = UserDefaults.standard.data(forKey: "barista.pomodoro.sessionDurations"),
           let durations = try? JSONDecoder().decode([Double].self, from: data) {
            sessionDurations = durations
        }
        if let data = UserDefaults.standard.data(forKey: "barista.pomodoro.dailyHistory"),
           let history = try? JSONDecoder().decode([Double].self, from: data) {
            dailyHistory = history
        }
    }
}

// MARK: - Interactive Dropdown

extension PomodoroWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 200 // header + timer card
        h += 56  // stat chips
        h += 70  // controls
        h += 70  // session history chart
        h += 56  // daily progress
        h += SuperWidgetKit.panelHeight + 8
        h += 40  // footer
        return NSSize(width: 340, height: min(max(h, 380), 720))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildTimerCard(in: container, y: y, pad: pad, cw: cw)
        y = buildStatChips(in: container, y: y, pad: pad, cw: cw)
        y = buildControls(in: container, y: y, pad: pad, cw: cw)
        y = buildSessionHistory(in: container, y: y, pad: pad, cw: cw)
        y = buildDailyProgress(in: container, y: y, pad: pad, cw: cw)
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let focusMin = totalFocusToday / 60
        let timeText = state == .idle ? "\(config.workMinutes):00" : timeString()
        let untilLong = config.cyclesBeforeLong - (completedCycles % config.cyclesBeforeLong)
        let avgSession = sessionDurations.isEmpty ? 0 : sessionDurations.reduce(0, +) / Double(sessionDurations.count)
        let nextPhase = state == .working ? "Next break \(config.shortBreakMinutes)m" : "Next focus \(config.workMinutes)m"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Phase", value: stateLabel(), color: accentColor()),
                SuperWidgetMetric(label: "Timer", value: timeText, color: accentColor()),
                SuperWidgetMetric(label: "Today", value: "\(focusMin)m", color: Theme.textSecondary),
                SuperWidgetMetric(label: "Streak", value: "x\(currentStreak)", color: currentStreak > 0 ? Theme.orange : Theme.textMuted)
            ],
            insights: [
                "Daily goal \(dailyCompleted)/\(config.targetDaily)",
                String(format: "Avg session %.0fm", avgSession),
                nextPhase
            ],
            actions: [
                "\(config.workMinutes)m work",
                "\(untilLong) to long break",
                config.soundEnabled ? "Sound on" : "Sound off"
            ],
            accent: accentColor()
        )
    }

    // MARK: - Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Focus Timer")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let badge = NSTextField(labelWithString: stateLabel())
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = accentColor()
        badge.alignment = .right
        badge.frame = NSRect(x: pad + cw - 120, y: y - 18, width: 120, height: 16)
        container.addSubview(badge)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Timer Card

    private func buildTimerCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 90
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Large ring gauge
        let ringSize: CGFloat = 68
        let ringImg = renderGradientRing(pct: progress * 100, size: ringSize, lineWidth: 5)
        let ringView = NSImageView(frame: NSRect(x: 12, y: (cardH - ringSize) / 2, width: ringSize, height: ringSize))
        ringView.image = ringImg
        card.addSubview(ringView)

        // Time centered in ring
        let timeLabel: String
        if state == .idle {
            timeLabel = String(format: "%d:00", config.workMinutes)
        } else {
            timeLabel = timeString()
        }
        let timeLbl = NSTextField(labelWithString: timeLabel)
        timeLbl.font = .monospacedDigitSystemFont(ofSize: 16, weight: .heavy)
        timeLbl.textColor = accentColor()
        timeLbl.alignment = .center
        timeLbl.frame = NSRect(x: 12, y: (cardH - 20) / 2, width: ringSize, height: 20)
        card.addSubview(timeLbl)

        // Right side: session info
        let sx: CGFloat = ringSize + 28
        let sw = cw - sx - 8
        var sy = cardH - 16

        // Phase label
        let phaseLbl = NSTextField(labelWithString: state == .idle ? "Ready to focus" : stateLabel())
        phaseLbl.font = .systemFont(ofSize: 13, weight: .semibold)
        phaseLbl.textColor = Theme.textPrimary
        phaseLbl.frame = NSRect(x: sx, y: sy - 16, width: sw, height: 16)
        card.addSubview(phaseLbl)
        sy -= 22

        // Session progress bar
        let barH: CGFloat = 6
        let barBg = NSView(frame: NSRect(x: sx, y: sy - barH, width: sw, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 3
        card.addSubview(barBg)

        let fillW = sw * CGFloat(progress)
        if fillW > 0 {
            let fill = NSView(frame: NSRect(x: sx, y: sy - barH, width: fillW, height: barH))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = accentColor().withAlphaComponent(0.8).cgColor
            fill.layer?.cornerRadius = 3
            card.addSubview(fill)
        }
        sy -= barH + 8

        // Stats rows
        let rows: [(String, String, NSColor)] = [
            ("Session", "\(completedCycles) of \(config.cyclesBeforeLong)", Theme.textSecondary),
            ("Until long", "\(config.cyclesBeforeLong - (completedCycles % config.cyclesBeforeLong))", Theme.textMuted),
        ]
        for (label, value, color) in rows {
            addStatPair(in: card, label: label, value: value, color: color, x: sx, y: sy - 12, w: sw)
            sy -= 16
        }

        y -= cardH + 8
        return y
    }

    // MARK: - Stat Chips

    private func buildStatChips(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let focusMin = totalFocusToday / 60
        let chips: [(String, String, NSColor)] = [
            ("\(dailyCompleted)", "Today", accentColor()),
            ("\(focusMin)m", "Focus", Theme.textSecondary),
            ("x\(currentStreak)", "Streak", currentStreak > 0 ? NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1) : Theme.textMuted),
            ("x\(bestStreak)", "Best", bestStreak > 0 ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) : Theme.textMuted),
        ]

        let chipW = (cw - CGFloat(chips.count - 1) * 6) / CGFloat(chips.count)
        for (i, (val, label, color)) in chips.enumerated() {
            let cx = pad + CGFloat(i) * (chipW + 6)
            let chip = makeCard(x: cx, y: y - 40, w: chipW, h: 40)
            container.addSubview(chip)

            let vl = NSTextField(labelWithString: val)
            vl.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            vl.textColor = color; vl.alignment = .center
            vl.lineBreakMode = .byTruncatingTail
            vl.frame = NSRect(x: 2, y: 16, width: chipW - 4, height: 18)
            chip.addSubview(vl)

            let ll = NSTextField(labelWithString: label)
            ll.font = .systemFont(ofSize: 8, weight: .semibold)
            ll.textColor = Theme.textFaint; ll.alignment = .center
            ll.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
            chip.addSubview(ll)
        }

        y -= 48
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Controls

    private func buildControls(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("CONTROLS")
        header.frame = NSRect(x: pad, y: y - 12, width: 100, height: 12)
        container.addSubview(header)
        y -= 20

        let btnH: CGFloat = 28
        let gap: CGFloat = 8
        let btnCount: CGFloat = 3
        let btnW = (cw - gap * (btnCount - 1)) / btnCount

        // Start/Pause button
        let startBtn = NSButton(frame: NSRect(x: pad, y: y - btnH, width: btnW, height: btnH))
        startBtn.bezelStyle = .rounded
        startBtn.isBordered = true
        if state == .idle {
            startBtn.title = "Start"
            startBtn.action = #selector(AppDelegate.pomodoroStart)
        } else {
            startBtn.title = "Pause"
            startBtn.action = #selector(AppDelegate.pomodoroStop)
        }
        startBtn.target = NSApp.delegate
        startBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        container.addSubview(startBtn)

        // Skip button
        let skipBtn = NSButton(frame: NSRect(x: pad + btnW + gap, y: y - btnH, width: btnW, height: btnH))
        skipBtn.bezelStyle = .rounded
        skipBtn.isBordered = true
        skipBtn.title = "Skip"
        skipBtn.action = #selector(AppDelegate.pomodoroSkip)
        skipBtn.target = NSApp.delegate
        skipBtn.font = .systemFont(ofSize: 11, weight: .medium)
        skipBtn.isEnabled = state != .idle
        container.addSubview(skipBtn)

        // Reset button
        let resetBtn = NSButton(frame: NSRect(x: pad + (btnW + gap) * 2, y: y - btnH, width: btnW, height: btnH))
        resetBtn.bezelStyle = .rounded
        resetBtn.isBordered = true
        resetBtn.title = "Reset"
        resetBtn.action = #selector(AppDelegate.pomodoroReset)
        resetBtn.target = NSApp.delegate
        resetBtn.font = .systemFont(ofSize: 11, weight: .medium)
        container.addSubview(resetBtn)

        y -= btnH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Session History

    private func buildSessionHistory(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("SESSION HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)

        if !sessionDurations.isEmpty {
            let avg = sessionDurations.reduce(0, +) / Double(sessionDurations.count)
            let info = String(format: "avg %.0f min  |  %d total", avg, sessionDurations.count)
            let il = NSTextField(labelWithString: info)
            il.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            il.textColor = Theme.textFaint; il.alignment = .right
            il.frame = NSRect(x: pad + 120, y: y - 12, width: cw - 120, height: 12)
            container.addSubview(il)
        }
        y -= 18

        let chartH: CGFloat = 40
        let chartBg = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        let chartData = Array(sessionDurations.suffix(30))
        if chartData.count >= 2 {
            let color = accentColor()
            let img = SparklineRenderer.renderBars(data: chartData, width: cw - 8, style: SparklineRenderer.Style(
                lineColor: color,
                fillColor: color.withAlphaComponent(0.15),
                lineWidth: 1.5, height: chartH - 4, pointRadius: 0
            ))
            let iv = NSImageView(frame: NSRect(x: 4, y: 2, width: cw - 8, height: chartH - 4))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        } else {
            let lbl = NSTextField(labelWithString: "Complete sessions to see history")
            lbl.font = .systemFont(ofSize: 10, weight: .regular)
            lbl.textColor = Theme.textFaint
            lbl.alignment = .center
            lbl.frame = NSRect(x: 4, y: (chartH - 14) / 2, width: cw - 8, height: 14)
            chartBg.addSubview(lbl)
        }

        y -= chartH + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Daily Progress

    private func buildDailyProgress(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("DAILY GOAL")
        header.frame = NSRect(x: pad, y: y - 12, width: 100, height: 12)
        container.addSubview(header)

        let progressText = "\(dailyCompleted)/\(config.targetDaily)"
        let pl = NSTextField(labelWithString: progressText)
        pl.font = .monospacedDigitSystemFont(ofSize: 8, weight: .bold)
        pl.textColor = dailyProgress >= 1.0 ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) : Theme.textMuted
        pl.alignment = .right
        pl.frame = NSRect(x: pad + 100, y: y - 12, width: cw - 100, height: 12)
        container.addSubview(pl)
        y -= 18

        let barH: CGFloat = 10
        let barBg = makeCard(x: pad, y: y - barH - 4, w: cw, h: barH + 4)
        container.addSubview(barBg)

        let fillW = (cw - 8) * CGFloat(dailyProgress)
        if fillW > 0 {
            let fill = NSView(frame: NSRect(x: 4, y: 2, width: fillW, height: barH))
            fill.wantsLayer = true
            let fillColor = dailyProgress >= 1.0
                ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.7)
                : accentColor().withAlphaComponent(0.6)
            fill.layer?.backgroundColor = fillColor.cgColor
            fill.layer?.cornerRadius = 4
            barBg.addSubview(fill)
        }

        // Target markers
        if config.targetDaily > 0 {
            let segW = (cw - 8) / CGFloat(config.targetDaily)
            for i in 1..<config.targetDaily {
                let markerX = 4 + segW * CGFloat(i)
                let marker = NSView(frame: NSRect(x: markerX, y: 2, width: 1, height: barH))
                marker.wantsLayer = true
                marker.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
                barBg.addSubview(marker)
            }
        }

        y -= barH + 12
        return y
    }

    // MARK: - Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        var parts: [String] = ["\(config.workMinutes)m work"]
        parts.append("\(config.shortBreakMinutes)m short")
        parts.append("\(config.longBreakMinutes)m long")

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
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

    private func addStatPair(in parent: NSView, label: String, value: String, color: NSColor, x: CGFloat, y: CGFloat, w: CGFloat) {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 10, weight: .regular)
        lbl.textColor = Theme.textMuted
        lbl.frame = NSRect(x: x, y: y, width: 60, height: 14)
        parent.addSubview(lbl)

        let val = NSTextField(labelWithString: value)
        val.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        val.textColor = color
        val.frame = NSRect(x: x + 60, y: y, width: w - 60, height: 14)
        parent.addSubview(val)
    }
}

// MARK: - Declarative Config

extension PomodoroWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Text (Work 12:34)", value: "text"),
                (title: "Compact (12:34)", value: "compact"),
                (title: "Ring Gauge", value: "ring"),
                (title: "Progress Bar + Time", value: "progressBar"),
                (title: "Emoji + Time", value: "emojiTime"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "text" },
               set: { [weak self] in self?.config.displayMode = PomodoroConfig.PomodoroDisplayMode(rawValue: $0) ?? .text }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (shifts with phase)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = PomodoroConfig.ColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "red" },
               set: { [weak self] in self?.config.accentColor = PomodoroConfig.AccentPreset(rawValue: $0) ?? .red }),

            .toggle(label: "Show Emoji", key: "showEmoji",
                    get: { [weak self] in self?.config.showEmoji ?? true },
                    set: { [weak self] in self?.config.showEmoji = $0 }),

            .toggle(label: "Show Session Count", key: "showSessionCount",
                    get: { [weak self] in self?.config.showSessionCount ?? true },
                    set: { [weak self] in self?.config.showSessionCount = $0 }),

            .section(title: "Timer"),
            .slider(label: "Work Duration", key: "workMinutes", min: 5, max: 60, step: 5,
                    get: { [weak self] in Double(self?.config.workMinutes ?? 25) },
                    set: { [weak self] in self?.config.workMinutes = Int($0) },
                    format: "%.0f min"),
            .slider(label: "Short Break", key: "shortBreakMinutes", min: 1, max: 15, step: 1,
                    get: { [weak self] in Double(self?.config.shortBreakMinutes ?? 5) },
                    set: { [weak self] in self?.config.shortBreakMinutes = Int($0) },
                    format: "%.0f min"),
            .slider(label: "Long Break", key: "longBreakMinutes", min: 5, max: 30, step: 5,
                    get: { [weak self] in Double(self?.config.longBreakMinutes ?? 15) },
                    set: { [weak self] in self?.config.longBreakMinutes = Int($0) },
                    format: "%.0f min"),
            .slider(label: "Sessions Before Long Break", key: "cyclesBeforeLong", min: 2, max: 8, step: 1,
                    get: { [weak self] in Double(self?.config.cyclesBeforeLong ?? 4) },
                    set: { [weak self] in self?.config.cyclesBeforeLong = Int($0) },
                    format: "%.0f"),

            .section(title: "Automation"),
            .toggle(label: "Auto-Start Break", key: "autoStartBreak",
                    get: { [weak self] in self?.config.autoStartBreak ?? true },
                    set: { [weak self] in self?.config.autoStartBreak = $0 }),
            .toggle(label: "Auto-Start Work", key: "autoStartWork",
                    get: { [weak self] in self?.config.autoStartWork ?? false },
                    set: { [weak self] in self?.config.autoStartWork = $0 }),
            .toggle(label: "Sound Notification", key: "soundEnabled",
                    get: { [weak self] in self?.config.soundEnabled ?? true },
                    set: { [weak self] in self?.config.soundEnabled = $0 }),

            .section(title: "Goals"),
            .slider(label: "Daily Target", key: "targetDaily", min: 1, max: 16, step: 1,
                    get: { [weak self] in Double(self?.config.targetDaily ?? 8) },
                    set: { [weak self] in self?.config.targetDaily = Int($0) },
                    format: "%.0f sessions"),
            .text(label: "Session Label", key: "sessionLabel", placeholder: "Focus",
                  get: { [weak self] in self?.config.sessionLabel ?? "Focus" },
                  set: { [weak self] in self?.config.sessionLabel = $0 }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 0.5, max: 5, step: 0.5,
                    get: { [weak self] in self?.config.refreshRate ?? 1 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.1f s"),
        ]
    }
}
