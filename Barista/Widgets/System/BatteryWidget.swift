import Cocoa
import IOKit.ps

// MARK: - Config

struct BatteryConfig: Codable, Equatable {
    var displayMode: BatteryDisplayMode = .text
    var showTimeRemaining: Bool = true
    var showHealth: Bool = true
    var showCycles: Bool = false
    var showWattage: Bool = true
    var showCondition: Bool = true
    var showTemperature: Bool = false
    var tempUnit: TempUnit = .celsius
    var alertBelow: Int = 20
    var healthWarnBelow: Int = 80
    var refreshRate: TimeInterval = 5
    var accentColor: AccentPreset = .green
    var colorMode: ColorMode = .dynamic
    var historyLength: Int = 60
    var showCapacityMah: Bool = false
    var compactLabels: Bool = false

    static let `default` = BatteryConfig()

    enum BatteryDisplayMode: String, Codable, Equatable {
        case text       // "🔋 85% 2:14"
        case compact    // "85%"
        case ring       // ring gauge + %
        case sparkline  // charge history sparkline + %
        case icon       // SF battery icon + %
        case bar        // thin progress bar + %
    }

    enum TempUnit: String, Codable, Equatable {
        case celsius, fahrenheit
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
        case dynamic // green->yellow->orange->red based on level
        case fixed   // always uses accentColor
    }
}

// MARK: - Widget

class BatteryWidget: BaristaWidget {
    static let widgetID = "battery-health"
    static let displayName = "Battery Health"
    static let subtitle = "Battery level, health, power & cycles"
    static let iconName = "battery.100"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = BatteryConfig.default

    var config: BatteryConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    // Battery state
    private(set) var level: Int = 0
    private(set) var isCharging: Bool = false
    private(set) var isPluggedIn: Bool = false
    private(set) var timeRemaining: Int = -1 // minutes, -1 = unknown
    private(set) var isPresent: Bool = false

    // IOKit deep data
    private(set) var cycleCount: Int = 0
    private(set) var health: Int = 100
    private(set) var maxCapacity: Int = 0    // mAh current max
    private(set) var designCapacity: Int = 0 // mAh original design
    private(set) var currentCharge: Int = 0  // mAh current charge
    private(set) var amperage: Int = 0       // mA (negative = discharging)
    private(set) var voltage: Int = 0        // mV
    private(set) var temperature: Double = 0 // Celsius
    private(set) var isFullyCharged: Bool = false
    private(set) var condition: String = "Unknown"
    private(set) var adapterWatts: Int = 0
    private(set) var adapterName: String = ""

    // History
    private(set) var chargeHistory: [Double] = []

    required init(config: BatteryConfig) {
        self.config = config
    }

    func start() {
        currentTimerInterval = config.refreshRate
        updateBattery()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Data Collection

    private func updateBattery() {
        // Self-correcting timer
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.updateBattery()
            }
        }

        updateFromIOPS()
        readIOKitBatteryInfo()

        chargeHistory.append(Double(level))
        while chargeHistory.count > config.historyLength {
            chargeHistory.removeFirst()
        }

        onDisplayUpdate?()
    }

    private func updateFromIOPS() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else {
            isPresent = false
            return
        }

        isPresent = true
        level = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false

        // Check power source type for plugged-in state
        let sourceState = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        isPluggedIn = sourceState == kIOPSACPowerValue

        if let time = desc[kIOPSTimeToEmptyKey] as? Int, time >= 0 {
            timeRemaining = time
        } else if let time = desc[kIOPSTimeToFullChargeKey] as? Int, time >= 0 {
            timeRemaining = time
        } else {
            timeRemaining = -1
        }
    }

    private func readIOKitBatteryInfo() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        func intVal(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? Int
        }
        func boolVal(_ key: String) -> Bool? {
            IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? Bool
        }
        func strVal(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? String
        }

        cycleCount = intVal("CycleCount") ?? cycleCount
        maxCapacity = intVal("MaxCapacity") ?? maxCapacity
        designCapacity = intVal("DesignCapacity") ?? designCapacity
        currentCharge = intVal("CurrentCapacity") ?? currentCharge
        amperage = intVal("Amperage") ?? amperage
        voltage = intVal("Voltage") ?? voltage
        isFullyCharged = boolVal("FullyCharged") ?? isFullyCharged

        // Temperature: reported in centidegrees Celsius (value / 100)
        if let rawTemp = intVal("Temperature") {
            temperature = Double(rawTemp) / 100.0
        }

        // Health percentage from capacity ratio
        if designCapacity > 0 {
            health = Int(Double(maxCapacity) / Double(designCapacity) * 100)
        }

        // Battery condition
        if let cond = strVal("BatteryCondition") {
            condition = cond
        } else {
            // Derive condition from health
            if health >= 80 {
                condition = "Normal"
            } else if health >= 60 {
                condition = "Service Recommended"
            } else {
                condition = "Service Battery"
            }
        }

        // Adapter info
        if let adapterDetails = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] {
            adapterWatts = adapterDetails["Watts"] as? Int ?? 0
            adapterName = adapterDetails["Name"] as? String ?? adapterDetails["Description"] as? String ?? ""
        }
    }

    // MARK: - Computed Properties

    var wattage: Double {
        let v = Double(voltage) / 1000.0  // mV -> V
        let a = Double(abs(amperage)) / 1000.0  // mA -> A
        return v * a
    }

    var timeRemainingFormatted: String {
        guard timeRemaining > 0 else { return "Calculating..." }
        let h = timeRemaining / 60
        let m = timeRemaining % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var statusText: String {
        if isFullyCharged { return "Fully Charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged In (Not Charging)" }
        return "On Battery"
    }

    // MARK: - Color Helpers

    func accentForLevel(_ pct: Int) -> NSColor {
        switch config.colorMode {
        case .fixed: return config.accentColor.color
        case .dynamic: return Self.dynamicLevelColor(pct, alertBelow: config.alertBelow)
        }
    }

    static func dynamicLevelColor(_ pct: Int, alertBelow: Int) -> NSColor {
        if pct <= alertBelow {
            return NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1) // red
        }
        let t = Double(pct) / 100.0
        if t < 0.25 {
            let f = CGFloat(t / 0.25)
            return NSColor(red: 1.0 - 0.04 * f, green: 0.35 + 0.31 * f, blue: 0.22, alpha: 1)
        } else if t < 0.50 {
            let f = CGFloat((t - 0.25) / 0.25)
            return NSColor(red: 0.96 - 0.06 * f, green: 0.66 + 0.14 * f, blue: 0.22 + 0.08 * f, alpha: 1)
        } else if t < 0.75 {
            let f = CGFloat((t - 0.50) / 0.25)
            return NSColor(red: 0.90 - 0.60 * f, green: 0.80 + 0.05 * f, blue: 0.30 + 0.25 * f, alpha: 1)
        } else {
            return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) // green
        }
    }

    static func healthColor(_ h: Int) -> NSColor {
        if h >= 90 { return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) }
        if h >= 80 { return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1) }
        if h >= 60 { return NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1) }
        return NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1)
    }

    static func tempColor(_ t: Double) -> NSColor {
        if t >= 40 { return NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1) }
        if t >= 35 { return NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1) }
        if t >= 30 { return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1) }
        return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
    }

    func formatTemp(_ celsius: Double) -> String {
        switch config.tempUnit {
        case .celsius: return "\(Int(celsius))\u{00B0}C"
        case .fahrenheit: return "\(Int(celsius * 9.0 / 5.0 + 32.0))\u{00B0}F"
        }
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        if !isPresent { return .text("No Battery") }

        let color = accentForLevel(level)
        let chargingPrefix = isCharging ? "\u{26A1}" : ""

        switch config.displayMode {
        case .text:
            return renderAttributedText(color: color, showLabel: true)

        case .compact:
            return renderAttributedText(color: color, showLabel: false)

        case .ring:
            let ringImg = renderRing(size: 18, lineWidth: 2.5)
            var label = "\(level)%"
            if config.showTimeRemaining && timeRemaining > 0 {
                label += " \(timeRemainingFormatted)"
            }
            if !chargingPrefix.isEmpty { label = chargingPrefix + label }
            return .iconAndText(ringImg, label)

        case .sparkline:
            let data = Array(chargeHistory.suffix(20))
            guard data.count >= 2 else { return renderAttributedText(color: color, showLabel: true) }
            var label = "\(chargingPrefix)\(level)%"
            if config.showTimeRemaining && timeRemaining > 0 {
                label += " \(timeRemainingFormatted)"
            }
            return .sparkline(data, label: label, width: 100)

        case .icon:
            let sfName = batteryIconName()
            let img = NSImage(systemSymbolName: sfName, accessibilityDescription: "Battery")
                ?? NSImage(size: NSSize(width: 20, height: 12))
            var label = "\(level)%"
            if config.showTimeRemaining && timeRemaining > 0 {
                label += " \(timeRemainingFormatted)"
            }
            return .iconAndText(img, label)

        case .bar:
            let barImg = renderMenuBarStrip(width: 32, height: 10)
            var label = " \(level)%"
            if config.showWattage && wattage > 0.5 {
                label += String(format: " %.0fW", wattage)
            }
            return .iconAndText(barImg, label)
        }
    }

    private func renderAttributedText(color: NSColor, showLabel: Bool) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()

        if isCharging {
            str.append(NSAttributedString(string: "\u{26A1}", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
            ]))
        }

        if showLabel {
            str.append(NSAttributedString(string: "BAT ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5)
            ]))
        }

        str.append(NSAttributedString(string: "\(level)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]))

        if config.showTimeRemaining && timeRemaining > 0 {
            str.append(NSAttributedString(string: " \(timeRemainingFormatted)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Theme.textMuted
            ]))
        }

        if config.showWattage && wattage > 0.5 {
            str.append(NSAttributedString(string: String(format: " %.0fW", wattage), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]))
        }

        if config.showHealth {
            str.append(NSAttributedString(string: " H:\(health)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Self.healthColor(health).withAlphaComponent(0.7)
            ]))
        }

        if config.showTemperature && temperature > 0 {
            str.append(NSAttributedString(string: " \(formatTemp(temperature))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Self.tempColor(temperature).withAlphaComponent(0.7)
            ]))
        }

        return .attributedText(str)
    }

    private func batteryIconName() -> String {
        if isCharging {
            if level >= 75 { return "battery.100.bolt" }
            if level >= 50 { return "battery.75.bolt" }
            if level >= 25 { return "battery.50.bolt" }
            return "battery.25.bolt"
        }
        if level >= 90 { return "battery.100" }
        if level >= 65 { return "battery.75" }
        if level >= 40 { return "battery.50" }
        if level >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func renderRing(size: CGFloat, lineWidth: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.08).setStroke()
        track.stroke()

        let sweep = CGFloat(min(Double(level), 100) / 100.0 * 360.0)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        accentForLevel(level).setStroke()
        arc.stroke()

        img.unlockFocus()
        return img
    }

    private func renderMenuBarStrip(width: CGFloat, height: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()

        // Background capsule
        let bgRect = NSRect(x: 0, y: 1, width: width, height: height - 2)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.08).setFill()
        bg.fill()

        // Fill
        let fillW = max(CGFloat(Double(level) / 100.0) * (width - 2), 1)
        let fillRect = NSRect(x: 1, y: 2, width: fillW, height: height - 4)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        accentForLevel(level).withAlphaComponent(0.8).setFill()
        fill.fill()

        img.unlockFocus()
        return img
    }

    // MARK: - Dropdown (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "BATTERY", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())
        let u = NSMenuItem(title: "\(level)% - \(statusText)", action: nil, keyEquivalent: "")
        u.isEnabled = false; menu.addItem(u)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

// MARK: - Interactive Dropdown

extension BatteryWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 240 // header + gauge + power chips
        h += 60  // health card
        h += 60  // history chart
        if config.showCapacityMah { h += 50 }
        h += SuperWidgetKit.panelHeight + 8
        h += 40  // footer
        return NSSize(width: 340, height: min(max(h, 320), 720))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        if !isPresent {
            let lbl = NSTextField(labelWithString: "No battery detected (desktop Mac?)")
            lbl.font = .systemFont(ofSize: 13, weight: .medium)
            lbl.textColor = Theme.textMuted
            lbl.frame = NSRect(x: pad, y: y - 20, width: cw, height: 20)
            container.addSubview(lbl)
            return container
        }

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildGaugeCard(in: container, y: y, pad: pad, cw: cw)
        y = buildPowerChips(in: container, y: y, pad: pad, cw: cw)
        y = buildHealthCard(in: container, y: y, pad: pad, cw: cw)
        y = buildHistoryChart(in: container, y: y, pad: pad, cw: cw)
        if config.showCapacityMah {
            y = buildCapacityCard(in: container, y: y, pad: pad, cw: cw)
        }
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let timeText: String
        if timeRemaining > 0 {
            timeText = "\(timeRemainingFormatted) \(isCharging ? "to full" : "left")"
        } else if isFullyCharged {
            timeText = "Fully charged"
        } else {
            timeText = "Calculating"
        }
        let powerText = wattage > 0.5 ? String(format: "%@%.1fW", amperage < 0 ? "-" : "+", wattage) : "Idle"
        let tempText = temperature > 0 ? formatTemp(temperature) : "N/A"
        let adapterText = adapterWatts > 0 ? "\(adapterWatts)W adapter" : (isPluggedIn ? "Adapter connected" : "On battery")

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Charge", value: "\(level)%", color: accentForLevel(level)),
                SuperWidgetMetric(label: "Health", value: "\(health)%", color: Self.healthColor(health)),
                SuperWidgetMetric(label: "Cycles", value: "\(cycleCount)", color: Theme.textSecondary),
                SuperWidgetMetric(label: "Power", value: powerText, color: amperage > 0 ? Theme.green : Theme.textMuted)
            ],
            insights: [
                statusText,
                "Condition \(condition)",
                timeText
            ],
            actions: [
                adapterText,
                "Temp \(tempText)",
                "Refresh \(Int(config.refreshRate))s"
            ],
            accent: accentForLevel(level)
        )
    }

    // MARK: Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Battery Health")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        // Status badge
        let badge = NSTextField(labelWithString: statusText)
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = isCharging ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) :
            (isFullyCharged ? NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1) : Theme.textMuted)
        badge.alignment = .right
        badge.frame = NSRect(x: pad + cw - 120, y: y - 18, width: 120, height: 16)
        container.addSubview(badge)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Gauge Card

    private func buildGaugeCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 80
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Large ring gauge
        let ringSize: CGFloat = 58
        let ringImg = renderRing(size: ringSize, lineWidth: 5)
        let ringView = NSImageView(frame: NSRect(x: 12, y: (cardH - ringSize) / 2, width: ringSize, height: ringSize))
        ringView.image = ringImg
        card.addSubview(ringView)

        // Percentage centered in ring
        let pctLabel = NSTextField(labelWithString: "\(level)%")
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        pctLabel.textColor = accentForLevel(level)
        pctLabel.alignment = .center
        pctLabel.frame = NSRect(x: 12, y: (cardH - 22) / 2, width: ringSize, height: 22)
        card.addSubview(pctLabel)

        // Right side: progress bar + stats
        let sx: CGFloat = ringSize + 24
        let sw = cw - sx - 8
        var sy = cardH - 14

        // Full-width charge bar
        let barH: CGFloat = 6
        let barBg = NSView(frame: NSRect(x: sx, y: sy - barH + 2, width: sw, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 3
        card.addSubview(barBg)

        let fillW = sw * CGFloat(Double(level) / 100.0)
        if fillW > 0 {
            let fill = NSView(frame: NSRect(x: sx, y: sy - barH + 2, width: fillW, height: barH))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = accentForLevel(level).withAlphaComponent(0.8).cgColor
            fill.layer?.cornerRadius = 3
            card.addSubview(fill)
        }
        sy -= barH + 6

        // Stats rows
        var rows: [(String, String, NSColor)] = [
            ("Time", timeRemaining > 0 ? "\(timeRemainingFormatted) \(isCharging ? "to full" : "left")" : (isFullyCharged ? "Fully Charged" : "Calculating..."), Theme.textSecondary),
        ]
        if wattage > 0.5 {
            let sign = amperage < 0 ? "-" : "+"
            rows.append(("Power", String(format: "%@%.1f W", sign, wattage), amperage > 0 ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) : Theme.textSecondary))
        }
        if temperature > 0 {
            rows.append(("Temp", formatTemp(temperature), Self.tempColor(temperature)))
        }

        for (label, value, color) in rows {
            addStatPair(in: card, label: label, value: value, color: color, x: sx, y: sy - 12, w: sw)
            sy -= 16
        }

        y -= cardH + 8
        return y
    }

    // MARK: Power Chips

    private func buildPowerChips(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        var chips: [(String, String, NSColor)] = []

        if voltage > 0 {
            chips.append((String(format: "%.2f V", Double(voltage) / 1000.0), "Voltage", Theme.textSecondary))
        }
        if amperage != 0 {
            chips.append((String(format: "%d mA", amperage), "Current", amperage > 0 ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) : Theme.textSecondary))
        }
        if adapterWatts > 0 {
            chips.append(("\(adapterWatts)W", "Adapter", NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)))
        } else if isPluggedIn {
            chips.append(("Connected", "Adapter", NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)))
        }

        guard !chips.isEmpty else { return y }

        let chipW = (cw - CGFloat(chips.count - 1) * 6) / CGFloat(max(chips.count, 1))
        for (i, (val, label, color)) in chips.enumerated() {
            let cx = pad + CGFloat(i) * (chipW + 6)
            let chip = makeCard(x: cx, y: y - 40, w: chipW, h: 40)
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

        y -= 48
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Health Card

    private func buildHealthCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("BATTERY HEALTH")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 44
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Health percentage (large)
        let healthLabel = NSTextField(labelWithString: "\(health)%")
        healthLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .heavy)
        healthLabel.textColor = Self.healthColor(health)
        healthLabel.frame = NSRect(x: 12, y: 8, width: 70, height: 28)
        card.addSubview(healthLabel)

        // Condition text
        let condLabel = NSTextField(labelWithString: condition)
        condLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        condLabel.textColor = condition == "Normal" ? NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) :
            (condition.contains("Service") ? NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1) : Theme.textMuted)
        condLabel.frame = NSRect(x: 84, y: 22, width: 120, height: 16)
        card.addSubview(condLabel)

        // Cycles
        let cycleLabel = NSTextField(labelWithString: "\(cycleCount) cycles")
        cycleLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        cycleLabel.textColor = Theme.textMuted
        cycleLabel.frame = NSRect(x: 84, y: 8, width: 80, height: 14)
        card.addSubview(cycleLabel)

        // Health bar on right
        let barX: CGFloat = cw - 82
        let barW: CGFloat = 70
        let barBg = NSView(frame: NSRect(x: barX, y: 18, width: barW, height: 8))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 4
        card.addSubview(barBg)

        let hFill = barW * CGFloat(min(health, 100)) / 100.0
        let hBar = NSView(frame: NSRect(x: barX, y: 18, width: hFill, height: 8))
        hBar.wantsLayer = true
        hBar.layer?.backgroundColor = Self.healthColor(health).withAlphaComponent(0.7).cgColor
        hBar.layer?.cornerRadius = 4
        card.addSubview(hBar)

        y -= cardH + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: History Chart

    private func buildHistoryChart(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("CHARGE HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)

        if chargeHistory.count >= 2 {
            let avg = chargeHistory.reduce(0, +) / Double(chargeHistory.count)
            let info = String(format: "avg %.0f%%", avg)
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

        // Alert threshold line
        let threshY = CGFloat(Double(config.alertBelow) / 100.0) * (chartH - 4) + 2
        let threshLine = NSView(frame: NSRect(x: 0, y: threshY, width: cw, height: 1))
        threshLine.wantsLayer = true
        threshLine.layer?.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.25).cgColor
        chartBg.addSubview(threshLine)

        let chartData = Array(chargeHistory.suffix(50))
        if chartData.count >= 2 {
            let color = accentForLevel(level)
            let img = SparklineRenderer.render(data: chartData, width: cw, style: SparklineRenderer.Style(
                lineColor: color,
                fillColor: color.withAlphaComponent(0.10),
                lineWidth: 1.5, height: chartH, pointRadius: 1.5
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        }

        y -= chartH + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Capacity Card

    private func buildCapacityCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("CAPACITY (mAh)")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 28
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let items: [(String, String)] = [
            ("Now", "\(currentCharge)"),
            ("Max", "\(maxCapacity)"),
            ("Design", "\(designCapacity)"),
        ]
        let colW = (cw - 16) / 3.0
        for (i, (label, val)) in items.enumerated() {
            let x = 8 + CGFloat(i) * colW
            let ll = NSTextField(labelWithString: label)
            ll.font = .systemFont(ofSize: 8, weight: .semibold)
            ll.textColor = Theme.textFaint
            ll.frame = NSRect(x: x, y: 14, width: colW, height: 10)
            card.addSubview(ll)

            let vl = NSTextField(labelWithString: val)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            vl.textColor = Theme.textSecondary
            vl.frame = NSRect(x: x, y: 2, width: colW, height: 14)
            card.addSubview(vl)
        }

        y -= cardH + 4
        return y
    }

    // MARK: Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        var parts: [String] = []

        if cycleCount > 0 { parts.append("\(cycleCount) cycles") }
        if !adapterName.isEmpty { parts.append(adapterName) }
        if adapterWatts > 0 && adapterName.isEmpty { parts.append("\(adapterWatts)W adapter") }
        if parts.isEmpty { parts.append("Battery") }

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: UI Helpers

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
        lbl.frame = NSRect(x: x, y: y, width: 48, height: 14)
        parent.addSubview(lbl)

        let val = NSTextField(labelWithString: value)
        val.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        val.textColor = color
        val.lineBreakMode = .byTruncatingTail
        val.frame = NSRect(x: x + 48, y: y, width: w - 48, height: 14)
        parent.addSubview(val)
    }
}

// MARK: - Declarative Config

extension BatteryWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Text (BAT 85% 2:14)", value: "text"),
                (title: "Compact (85%)", value: "compact"),
                (title: "Ring Gauge + %", value: "ring"),
                (title: "Sparkline + %", value: "sparkline"),
                (title: "SF Battery Icon", value: "icon"),
                (title: "Progress Bar + %", value: "bar"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "text" },
               set: { [weak self] in self?.config.displayMode = BatteryConfig.BatteryDisplayMode(rawValue: $0) ?? .text }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (shifts with level)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = BatteryConfig.ColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "green" },
               set: { [weak self] in self?.config.accentColor = BatteryConfig.AccentPreset(rawValue: $0) ?? .green }),

            .section(title: "Menu Bar Info"),
            .toggle(label: "Show Time Remaining", key: "showTimeRemaining",
                    get: { [weak self] in self?.config.showTimeRemaining ?? true },
                    set: { [weak self] in self?.config.showTimeRemaining = $0 }),
            .toggle(label: "Show Health %", key: "showHealth",
                    get: { [weak self] in self?.config.showHealth ?? true },
                    set: { [weak self] in self?.config.showHealth = $0 }),
            .toggle(label: "Show Cycle Count", key: "showCycles",
                    get: { [weak self] in self?.config.showCycles ?? false },
                    set: { [weak self] in self?.config.showCycles = $0 }),
            .toggle(label: "Show Wattage", key: "showWattage",
                    get: { [weak self] in self?.config.showWattage ?? true },
                    set: { [weak self] in self?.config.showWattage = $0 }),
            .toggle(label: "Show Temperature", key: "showTemperature",
                    get: { [weak self] in self?.config.showTemperature ?? false },
                    set: { [weak self] in self?.config.showTemperature = $0 }),
            .picker(label: "Temperature Unit", key: "tempUnit", options: [
                (title: "Celsius", value: "celsius"),
                (title: "Fahrenheit", value: "fahrenheit"),
            ], get: { [weak self] in self?.config.tempUnit.rawValue ?? "celsius" },
               set: { [weak self] in self?.config.tempUnit = BatteryConfig.TempUnit(rawValue: $0) ?? .celsius }),

            .section(title: "Alerts"),
            .slider(label: "Low Battery Alert", key: "alertBelow", min: 5, max: 50, step: 5,
                    get: { [weak self] in Double(self?.config.alertBelow ?? 20) },
                    set: { [weak self] in self?.config.alertBelow = Int($0) },
                    format: "%.0f%%"),
            .slider(label: "Health Warn Below", key: "healthWarnBelow", min: 50, max: 95, step: 5,
                    get: { [weak self] in Double(self?.config.healthWarnBelow ?? 80) },
                    set: { [weak self] in self?.config.healthWarnBelow = Int($0) },
                    format: "%.0f%%"),

            .section(title: "Dropdown"),
            .toggle(label: "Show Capacity (mAh)", key: "showCapacityMah",
                    get: { [weak self] in self?.config.showCapacityMah ?? false },
                    set: { [weak self] in self?.config.showCapacityMah = $0 }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 5, max: 60, step: 5,
                    get: { [weak self] in self?.config.refreshRate ?? 5 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "History Length", key: "historyLength", min: 20, max: 120, step: 10,
                    get: { [weak self] in Double(self?.config.historyLength ?? 60) },
                    set: { [weak self] in self?.config.historyLength = Int($0) },
                    format: "%.0f pts"),
        ]
    }
}
