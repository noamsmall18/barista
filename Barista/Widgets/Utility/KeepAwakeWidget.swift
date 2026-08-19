import Cocoa
import IOKit.pwr_mgt

// MARK: - Config

struct KeepAwakeConfig: Codable, Equatable {
    var displayMode: KeepAwakeDisplayMode
    var preventDisplaySleep: Bool
    var preventIdleSleep: Bool
    var defaultDuration: Int          // minutes, 0 = indefinite
    var showCountdown: Bool
    var showActiveDuration: Bool
    var animateIcon: Bool
    var autoBatteryDisable: Bool
    var batteryThreshold: Int         // % below which to auto-disable
    var autoEnableOnPower: Bool
    var scheduleEnabled: Bool
    var scheduleStartHour: Int        // 0-23
    var scheduleEndHour: Int          // 0-23
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var refreshRate: TimeInterval

    static let `default` = KeepAwakeConfig(
        displayMode: .iconAndTime,
        preventDisplaySleep: true,
        preventIdleSleep: true,
        defaultDuration: 0,
        showCountdown: true,
        showActiveDuration: true,
        animateIcon: true,
        autoBatteryDisable: false,
        batteryThreshold: 20,
        autoEnableOnPower: false,
        scheduleEnabled: false,
        scheduleStartHour: 9,
        scheduleEndHour: 17,
        accentColor: .amber,
        colorMode: .fixed,
        refreshRate: 1
    )

    enum KeepAwakeDisplayMode: String, Codable, Equatable {
        case icon          // coffee cup icon, changes when active
        case text          // "Awake" / "Sleep OK"
        case iconAndTime   // "☕ 2h 14m"
        case compact       // just icon, green/gray dot
        case timer         // "45:00 left"
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
        case dynamic // green when active, gray when inactive
        case fixed   // always uses accentColor
    }
}

// MARK: - Widget

class KeepAwakeWidget: BaristaWidget {
    static let widgetID = "keep-awake"
    static let displayName = "Keep Awake"
    static let subtitle = "Prevent your Mac from sleeping"
    static let iconName = "cup.and.saucer.fill"
    static let category = WidgetCategory.utility
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = KeepAwakeConfig.default

    var config: KeepAwakeConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    // Power assertion state
    private var displayAssertionID: IOPMAssertionID = 0
    private var idleAssertionID: IOPMAssertionID = 0
    private(set) var isActive = false
    private(set) var endTime: Date?
    private(set) var activatedAt: Date?
    private var hasDisplayAssertion = false
    private var hasIdleAssertion = false

    // Timer
    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    // Icon animation
    private var animationFrame: Int = 0

    // Session tracking
    private(set) var sessionsToday: Int = 0
    private(set) var totalAwakeSecondsToday: Double = 0
    private var lastSessionDay: Int = -1

    // Battery monitoring
    private(set) var currentBatteryLevel: Int = 100
    private(set) var isPluggedIn: Bool = false
    private var wasPluggedIn: Bool = false

    required init(config: KeepAwakeConfig) {
        self.config = config
    }

    func start() {
        let rate = config.refreshRate
        currentTimerInterval = rate
        resetDayCounterIfNeeded()
        updateBatteryState()
        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deactivateAllAssertions()
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

        resetDayCounterIfNeeded()
        updateBatteryState()

        // Track active time
        if isActive {
            totalAwakeSecondsToday += config.refreshRate
        }

        // Check timer expiry
        if isActive, let end = endTime, Date() >= end {
            deactivateAllAssertions()
        }

        // Auto-disable on low battery
        if isActive && config.autoBatteryDisable && currentBatteryLevel < config.batteryThreshold && !isPluggedIn {
            deactivateAllAssertions()
        }

        // Auto-enable on power connect
        if config.autoEnableOnPower && isPluggedIn && !wasPluggedIn && !isActive {
            activateAssertions(minutes: config.defaultDuration)
        }
        wasPluggedIn = isPluggedIn

        // Schedule check
        if config.scheduleEnabled {
            let hour = Calendar.current.component(.hour, from: Date())
            let inSchedule: Bool
            if config.scheduleStartHour <= config.scheduleEndHour {
                inSchedule = hour >= config.scheduleStartHour && hour < config.scheduleEndHour
            } else {
                inSchedule = hour >= config.scheduleStartHour || hour < config.scheduleEndHour
            }
            if inSchedule && !isActive {
                activateAssertions(minutes: 0) // indefinite during schedule
            } else if !inSchedule && isActive && endTime == nil {
                // Only auto-deactivate schedule-started sessions (indefinite)
                deactivateAllAssertions()
            }
        }

        // Animate icon
        if isActive && config.animateIcon {
            animationFrame = (animationFrame + 1) % 4
        }

        onDisplayUpdate?()
    }

    // MARK: - Battery State

    private func updateBatteryState() {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let snapshot = snapshot,
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else { return }

        currentBatteryLevel = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        let sourceState = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        isPluggedIn = sourceState == kIOPSACPowerValue
    }

    // MARK: - Day Counter

    private func resetDayCounterIfNeeded() {
        let today = Calendar.current.component(.day, from: Date())
        if today != lastSessionDay {
            lastSessionDay = today
            sessionsToday = 0
            totalAwakeSecondsToday = 0
        }
    }

    // MARK: - Power Assertions

    private func activateAssertions(minutes: Int) {
        deactivateAllAssertions()

        let reason = "Barista Keep Awake" as CFString

        if config.preventDisplaySleep {
            var aid: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason, &aid
            )
            if r == kIOReturnSuccess {
                displayAssertionID = aid
                hasDisplayAssertion = true
            }
        }

        if config.preventIdleSleep {
            var aid: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason, &aid
            )
            if r == kIOReturnSuccess {
                idleAssertionID = aid
                hasIdleAssertion = true
            }
        }

        if hasDisplayAssertion || hasIdleAssertion {
            isActive = true
            activatedAt = Date()
            endTime = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
            sessionsToday += 1
        }
    }

    private func deactivateAllAssertions() {
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertionID)
            hasDisplayAssertion = false
            displayAssertionID = 0
        }
        if hasIdleAssertion {
            IOPMAssertionRelease(idleAssertionID)
            hasIdleAssertion = false
            idleAssertionID = 0
        }
        isActive = false
        endTime = nil
        activatedAt = nil
        animationFrame = 0
    }

    func toggle(minutes: Int = 0) {
        if isActive {
            deactivateAllAssertions()
        } else {
            activateAssertions(minutes: minutes > 0 ? minutes : config.defaultDuration)
        }
        onDisplayUpdate?()
    }

    // MARK: - Computed Properties

    var activeColor: NSColor {
        switch config.colorMode {
        case .fixed: return config.accentColor.color
        case .dynamic: return isActive ? Theme.green : Theme.textFaint
        }
    }

    var inactiveColor: NSColor {
        Theme.textMuted
    }

    var activeDurationFormatted: String {
        guard let start = activatedAt else { return "0m" }
        let elapsed = Int(Date().timeIntervalSince(start))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var remainingFormatted: String {
        guard let end = endTime else { return "Indefinite" }
        let remaining = max(Int(end.timeIntervalSince(Date())), 0)
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        let s = remaining % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var totalAwakeTodayFormatted: String {
        let secs = Int(totalAwakeSecondsToday)
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var coffeeIcon: String {
        if !isActive { return "\u{2615}" }
        // Animate between states when active
        if config.animateIcon {
            switch animationFrame {
            case 0: return "\u{2615}"    // ☕
            case 1: return "\u{2615}\u{FE0E}"
            case 2: return "\u{2615}"
            default: return "\u{2615}\u{FE0E}"
            }
        }
        return "\u{2615}"
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        let color = isActive ? activeColor : inactiveColor

        switch config.displayMode {
        case .icon:
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: coffeeIcon, attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: color
            ]))
            return .attributedText(str)

        case .text:
            let label = isActive ? "Awake" : "Sleep OK"
            let str = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color
            ])
            return .attributedText(str)

        case .iconAndTime:
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "\(coffeeIcon) ", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color
            ]))
            if isActive {
                let timeStr: String
                if let _ = endTime, config.showCountdown {
                    timeStr = remainingFormatted
                } else if config.showActiveDuration {
                    timeStr = activeDurationFormatted
                } else {
                    timeStr = "Awake"
                }
                str.append(NSAttributedString(string: timeStr, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: color
                ]))
            } else {
                str.append(NSAttributedString(string: "Off", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: inactiveColor
                ]))
            }
            return .attributedText(str)

        case .compact:
            let dot = isActive ? "\u{25CF}" : "\u{25CB}" // ● or ○
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "\(coffeeIcon)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color
            ]))
            str.append(NSAttributedString(string: dot, attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: isActive ? Theme.green : Theme.textFaint
            ]))
            return .attributedText(str)

        case .timer:
            if isActive, let _ = endTime {
                let str = NSAttributedString(string: "\(remainingFormatted) left", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: color
                ])
                return .attributedText(str)
            } else if isActive {
                let str = NSAttributedString(string: "\u{221E} Awake", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: color
                ])
                return .attributedText(str)
            } else {
                return .text("\u{2615} Sleep OK")
            }
        }
    }

    // MARK: - Dropdown Menu (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "KEEP AWAKE", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())

        if isActive {
            let statusItem = NSMenuItem(title: "\u{2615} Active - Mac will not sleep", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            if let _ = endTime {
                let timeItem = NSMenuItem(title: "  \(remainingFormatted) remaining", action: nil, keyEquivalent: "")
                timeItem.isEnabled = false
                menu.addItem(timeItem)
            } else {
                let indef = NSMenuItem(title: "  Indefinite (until disabled)", action: nil, keyEquivalent: "")
                indef.isEnabled = false
                menu.addItem(indef)
            }

            menu.addItem(NSMenuItem.separator())
            let stopItem = NSMenuItem(title: "Disable Keep Awake", action: #selector(toggleAwake), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let statusItem = NSMenuItem(title: "Mac can sleep normally", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())

            let durations = [
                (0, "Indefinitely"),
                (30, "30 minutes"),
                (60, "1 hour"),
                (120, "2 hours"),
                (240, "4 hours"),
                (480, "8 hours"),
            ]
            for (mins, label) in durations {
                let item = NSMenuItem(title: "Keep Awake \(label)", action: #selector(activateWithDuration(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mins
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func toggleAwake() {
        toggle()
    }

    @objc private func activateWithDuration(_ sender: NSMenuItem) {
        activateAssertions(minutes: sender.tag)
        onDisplayUpdate?()
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

// MARK: - Interactive Dropdown

extension KeepAwakeWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 260 // header + hero card + toggle button + dividers
        h += 80  // duration presets
        h += 60  // assertion info
        h += 60  // session stats
        if config.autoBatteryDisable || config.scheduleEnabled { h += 50 }
        h += SuperWidgetKit.panelHeight + 8
        h += 40  // footer
        return NSSize(width: 340, height: min(max(h, 380), 760))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildPopoverHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildHeroCard(in: container, y: y, pad: pad, cw: cw)
        y = buildToggleButton(in: container, y: y, pad: pad, cw: cw)

        if !isActive {
            y = buildDurationPresets(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildAssertionInfo(in: container, y: y, pad: pad, cw: cw)
        y = buildSessionStats(in: container, y: y, pad: pad, cw: cw)

        if config.autoBatteryDisable || config.scheduleEnabled {
            y = buildAutomationInfo(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildPopoverFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let stateText = isActive ? "Active" : "Idle"
        let remainingText: String
        if isActive, endTime != nil {
            remainingText = remainingFormatted
        } else if isActive {
            remainingText = "Indef"
        } else {
            remainingText = "Ready"
        }
        let displayText = hasDisplayAssertion ? "Display blocked" : "Display ready"
        let idleText = hasIdleAssertion ? "Idle blocked" : "Idle ready"
        let automationText = config.scheduleEnabled
            ? String(format: "Schedule %02d:00-%02d:00", config.scheduleStartHour, config.scheduleEndHour)
            : "No schedule"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "State", value: stateText, color: isActive ? activeColor : Theme.textMuted),
                SuperWidgetMetric(label: "Remaining", value: remainingText, color: activeColor),
                SuperWidgetMetric(label: "Sessions", value: "\(sessionsToday)", color: Theme.textSecondary),
                SuperWidgetMetric(label: "Battery", value: "\(currentBatteryLevel)%", color: currentBatteryLevel <= config.batteryThreshold ? Theme.red : Theme.green)
            ],
            insights: [
                isActive ? "Running for \(activeDurationFormatted)" : "Mac can sleep normally",
                displayText,
                idleText
            ],
            actions: [
                isPluggedIn ? "Plugged in" : "On battery",
                config.autoBatteryDisable ? "Auto off \(config.batteryThreshold)%" : "Battery guard off",
                automationText
            ],
            accent: isActive ? activeColor : inactiveColor
        )
    }

    // MARK: - Popover Header

    private func buildPopoverHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Keep Awake")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let badge = NSTextField(labelWithString: isActive ? "ACTIVE" : "INACTIVE")
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = isActive ? Theme.green : Theme.textFaint
        badge.alignment = .right
        badge.frame = NSRect(x: pad + cw - 80, y: y - 18, width: 80, height: 16)
        container.addSubview(badge)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Hero Status Card

    private func buildHeroCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 80
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Large coffee icon
        let iconSize: CGFloat = 44
        let iconLabel = NSTextField(labelWithString: "\u{2615}")
        iconLabel.font = .systemFont(ofSize: 36)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 12, y: (cardH - iconSize) / 2, width: iconSize, height: iconSize)
        card.addSubview(iconLabel)

        // Status text
        let sx: CGFloat = iconSize + 24
        let sw = cw - sx - 8

        let statusLabel = NSTextField(labelWithString: isActive ? "AWAKE" : "SLEEPING")
        statusLabel.font = .systemFont(ofSize: 20, weight: .heavy)
        statusLabel.textColor = isActive ? activeColor : Theme.textFaint
        statusLabel.frame = NSRect(x: sx, y: cardH - 34, width: sw, height: 26)
        card.addSubview(statusLabel)

        // Sub-info
        let subText: String
        if isActive {
            if let _ = endTime {
                subText = "\(remainingFormatted) remaining"
            } else {
                subText = "Running for \(activeDurationFormatted)"
            }
        } else {
            subText = "Mac can sleep normally"
        }
        let subLabel = NSTextField(labelWithString: subText)
        subLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        subLabel.textColor = Theme.textMuted
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.frame = NSRect(x: sx, y: cardH - 54, width: sw, height: 16)
        card.addSubview(subLabel)

        // Active duration if timed
        if isActive, let _ = endTime, config.showActiveDuration {
            let dur = NSTextField(labelWithString: "Active for \(activeDurationFormatted)")
            dur.font = .systemFont(ofSize: 9, weight: .regular)
            dur.textColor = Theme.textFaint
            dur.frame = NSRect(x: sx, y: 8, width: sw, height: 12)
            card.addSubview(dur)
        }

        y -= cardH + 8
        return y
    }

    // MARK: - Toggle Button

    private func buildToggleButton(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let btnH: CGFloat = 34

        let btn = NSButton(frame: NSRect(x: pad, y: y - btnH, width: cw, height: btnH))
        btn.title = isActive ? "Disable Keep Awake" : "Enable Keep Awake"
        btn.bezelStyle = .rounded
        btn.target = self
        btn.action = #selector(toggleAwake)
        btn.font = .systemFont(ofSize: 13, weight: .semibold)
        btn.wantsLayer = true
        container.addSubview(btn)

        y -= btnH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Duration Presets

    private func buildDurationPresets(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("QUICK START")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let presets: [(Int, String)] = [
            (30, "30m"), (60, "1h"), (120, "2h"), (240, "4h"), (0, "\u{221E}")
        ]

        let gap: CGFloat = 6
        let btnW = (cw - gap * CGFloat(presets.count - 1)) / CGFloat(presets.count)
        let btnH: CGFloat = 30

        for (i, (mins, label)) in presets.enumerated() {
            let bx = pad + CGFloat(i) * (btnW + gap)
            let btn = NSButton(frame: NSRect(x: bx, y: y - btnH, width: btnW, height: btnH))
            btn.title = label
            btn.bezelStyle = .rounded
            btn.target = self
            btn.action = #selector(activateWithDuration(_:))
            btn.tag = mins
            btn.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            container.addSubview(btn)
        }

        y -= btnH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Assertion Info

    private func buildAssertionInfo(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("POWER ASSERTIONS")
        header.frame = NSRect(x: pad, y: y - 12, width: 200, height: 12)
        container.addSubview(header)
        y -= 18

        let chipCount = 2
        let gap: CGFloat = 6
        let chipW = (cw - gap * CGFloat(chipCount - 1)) / CGFloat(chipCount)
        let chipH: CGFloat = 40

        // Display sleep chip
        let displayChip = makeCard(x: pad, y: y - chipH, w: chipW, h: chipH)
        container.addSubview(displayChip)

        let displayActive = isActive && hasDisplayAssertion
        let dv = NSTextField(labelWithString: displayActive ? "Blocked" : (config.preventDisplaySleep ? "Ready" : "Off"))
        dv.font = .systemFont(ofSize: 12, weight: .bold)
        dv.textColor = displayActive ? Theme.green : (config.preventDisplaySleep ? Theme.textMuted : Theme.textFaint)
        dv.alignment = .center
        dv.frame = NSRect(x: 2, y: 18, width: chipW - 4, height: 16)
        displayChip.addSubview(dv)

        let dl = NSTextField(labelWithString: "Display Sleep")
        dl.font = .systemFont(ofSize: 8, weight: .semibold)
        dl.textColor = Theme.textFaint; dl.alignment = .center
        dl.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
        displayChip.addSubview(dl)

        // Idle sleep chip
        let idleChip = makeCard(x: pad + chipW + gap, y: y - chipH, w: chipW, h: chipH)
        container.addSubview(idleChip)

        let idleActive = isActive && hasIdleAssertion
        let iv = NSTextField(labelWithString: idleActive ? "Blocked" : (config.preventIdleSleep ? "Ready" : "Off"))
        iv.font = .systemFont(ofSize: 12, weight: .bold)
        iv.textColor = idleActive ? Theme.green : (config.preventIdleSleep ? Theme.textMuted : Theme.textFaint)
        iv.alignment = .center
        iv.frame = NSRect(x: 2, y: 18, width: chipW - 4, height: 16)
        idleChip.addSubview(iv)

        let il = NSTextField(labelWithString: "Idle Sleep")
        il.font = .systemFont(ofSize: 8, weight: .semibold)
        il.textColor = Theme.textFaint; il.alignment = .center
        il.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
        idleChip.addSubview(il)

        y -= chipH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Session Stats

    private func buildSessionStats(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("TODAY'S SESSION")
        header.frame = NSRect(x: pad, y: y - 12, width: 150, height: 12)
        container.addSubview(header)
        y -= 18

        let chipCount = 3
        let gap: CGFloat = 6
        let chipW = (cw - gap * CGFloat(chipCount - 1)) / CGFloat(chipCount)
        let chipH: CGFloat = 40

        let stats: [(String, String, NSColor)] = [
            ("\(sessionsToday)", "Sessions", Theme.textSecondary),
            (totalAwakeTodayFormatted, "Awake Time", activeColor),
            ("\(currentBatteryLevel)%", "Battery", currentBatteryLevel <= config.batteryThreshold ? Theme.red : Theme.green),
        ]

        for (i, (val, label, color)) in stats.enumerated() {
            let cx = pad + CGFloat(i) * (chipW + gap)
            let chip = makeCard(x: cx, y: y - chipH, w: chipW, h: chipH)
            container.addSubview(chip)

            let vl = NSTextField(labelWithString: val)
            vl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
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

        y -= chipH + 4
        return y
    }

    // MARK: - Automation Info

    private func buildAutomationInfo(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        addDivider(in: container, y: &y, pad: pad, cw: cw)

        let header = Theme.sectionHeader("AUTOMATION")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        if config.autoBatteryDisable {
            let label = NSTextField(labelWithString: "Auto-disable below \(config.batteryThreshold)% battery")
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = Theme.textMuted
            label.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
            container.addSubview(label)
            y -= 18
        }

        if config.scheduleEnabled {
            let startStr = String(format: "%d:00", config.scheduleStartHour)
            let endStr = String(format: "%d:00", config.scheduleEndHour)
            let label = NSTextField(labelWithString: "Schedule: \(startStr) - \(endStr)")
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = Theme.textMuted
            label.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
            container.addSubview(label)
            y -= 18
        }

        if config.autoEnableOnPower {
            let label = NSTextField(labelWithString: "Auto-enable when plugged in")
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = Theme.textMuted
            label.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
            container.addSubview(label)
            y -= 18
        }

        return y
    }

    // MARK: - Popover Footer

    @discardableResult
    private func buildPopoverFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4

        var parts: [String] = []
        if isPluggedIn { parts.append("Plugged In") }
        else { parts.append("On Battery") }
        parts.append("Battery \(currentBatteryLevel)%")

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
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
}

// MARK: - Declarative Config

extension KeepAwakeWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Icon Only", value: "icon"),
                (title: "Text (Awake / Sleep OK)", value: "text"),
                (title: "Icon + Time", value: "iconAndTime"),
                (title: "Compact (icon + dot)", value: "compact"),
                (title: "Timer Countdown", value: "timer"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "iconAndTime" },
               set: { [weak self] in self?.config.displayMode = KeepAwakeConfig.KeepAwakeDisplayMode(rawValue: $0) ?? .iconAndTime }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (green/gray)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "fixed" },
               set: { [weak self] in self?.config.colorMode = KeepAwakeConfig.ColorMode(rawValue: $0) ?? .fixed }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "amber" },
               set: { [weak self] in self?.config.accentColor = KeepAwakeConfig.AccentPreset(rawValue: $0) ?? .amber }),

            .toggle(label: "Animate Icon When Active", key: "animateIcon",
                    get: { [weak self] in self?.config.animateIcon ?? true },
                    set: { [weak self] in self?.config.animateIcon = $0 }),

            .section(title: "Sleep Prevention"),
            .toggle(label: "Prevent Display Sleep", key: "preventDisplaySleep",
                    get: { [weak self] in self?.config.preventDisplaySleep ?? true },
                    set: { [weak self] in self?.config.preventDisplaySleep = $0 }),
            .toggle(label: "Prevent Idle Sleep", key: "preventIdleSleep",
                    get: { [weak self] in self?.config.preventIdleSleep ?? true },
                    set: { [weak self] in self?.config.preventIdleSleep = $0 }),
            .picker(label: "Default Duration", key: "defaultDuration", options: [
                (title: "Indefinite", value: "0"),
                (title: "30 minutes", value: "30"),
                (title: "1 hour", value: "60"),
                (title: "2 hours", value: "120"),
                (title: "4 hours", value: "240"),
                (title: "8 hours", value: "480"),
            ], get: { [weak self] in String(self?.config.defaultDuration ?? 0) },
               set: { [weak self] in self?.config.defaultDuration = Int($0) ?? 0 }),

            .section(title: "Timer Display"),
            .toggle(label: "Show Countdown", key: "showCountdown",
                    get: { [weak self] in self?.config.showCountdown ?? true },
                    set: { [weak self] in self?.config.showCountdown = $0 }),
            .toggle(label: "Show Active Duration", key: "showActiveDuration",
                    get: { [weak self] in self?.config.showActiveDuration ?? true },
                    set: { [weak self] in self?.config.showActiveDuration = $0 }),

            .section(title: "Automation"),
            .toggle(label: "Auto-Disable on Low Battery", key: "autoBatteryDisable",
                    get: { [weak self] in self?.config.autoBatteryDisable ?? false },
                    set: { [weak self] in self?.config.autoBatteryDisable = $0 }),
            .slider(label: "Battery Threshold", key: "batteryThreshold", min: 5, max: 50, step: 5,
                    get: { [weak self] in Double(self?.config.batteryThreshold ?? 20) },
                    set: { [weak self] in self?.config.batteryThreshold = Int($0) },
                    format: "%.0f%%"),
            .toggle(label: "Auto-Enable on Power Connect", key: "autoEnableOnPower",
                    get: { [weak self] in self?.config.autoEnableOnPower ?? false },
                    set: { [weak self] in self?.config.autoEnableOnPower = $0 }),
            .toggle(label: "Schedule (Auto-Enable During Hours)", key: "scheduleEnabled",
                    get: { [weak self] in self?.config.scheduleEnabled ?? false },
                    set: { [weak self] in self?.config.scheduleEnabled = $0 }),
            .slider(label: "Schedule Start Hour", key: "scheduleStartHour", min: 0, max: 23, step: 1,
                    get: { [weak self] in Double(self?.config.scheduleStartHour ?? 9) },
                    set: { [weak self] in self?.config.scheduleStartHour = Int($0) },
                    format: "%.0f:00"),
            .slider(label: "Schedule End Hour", key: "scheduleEndHour", min: 0, max: 23, step: 1,
                    get: { [weak self] in Double(self?.config.scheduleEndHour ?? 17) },
                    set: { [weak self] in self?.config.scheduleEndHour = Int($0) },
                    format: "%.0f:00"),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 10, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 1 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
        ]
    }
}
