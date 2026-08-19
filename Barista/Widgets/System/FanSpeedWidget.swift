import Cocoa

// MARK: - Config

struct FanSpeedConfig: Codable, Equatable {
    var displayMode: FanDisplayMode
    var showFanNumber: Bool
    var showAsPercentage: Bool
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var refreshRate: TimeInterval
    var historyLength: Int
    var warnRPM: Int
    var showTemperature: Bool
    var tempUnit: TempUnit
    var showAllFans: Bool
    var selectedFanIndex: Int
    var compactLabels: Bool
    var showMinMax: Bool
    var showFanCount: Bool
    var maxRPMOverride: Int

    static let `default` = FanSpeedConfig(
        displayMode: .rpm,
        showFanNumber: true,
        showAsPercentage: false,
        accentColor: .cyan,
        colorMode: .dynamic,
        refreshRate: 1,
        historyLength: 60,
        warnRPM: 4000,
        showTemperature: true,
        tempUnit: .celsius,
        showAllFans: true,
        selectedFanIndex: 0,
        compactLabels: false,
        showMinMax: true,
        showFanCount: false,
        maxRPMOverride: 6200
    )

    enum FanDisplayMode: String, Codable, Equatable {
        case rpm
        case compact
        case sparkline
        case multi
        case percentage
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
        case dynamic
        case fixed
    }
}

// MARK: - Fan Data

struct FanInfo {
    var rpm: Double = 0
    var minRPM: Double = 0
    var maxRPM: Double = 6200
    var history: [Double] = []
}

// MARK: - Widget

class FanSpeedWidget: BaristaWidget {
    static let widgetID = "fan-speed"
    static let displayName = "Fan Speed"
    static let subtitle = "Fan RPM, temperature & history"
    static let iconName = "fan"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = FanSpeedConfig.default

    var config: FanSpeedConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    private(set) var fans: [FanInfo] = []
    private(set) var numFans: Int = 0
    private(set) var cpuTemp: Double?

    required init(config: FanSpeedConfig) {
        self.config = config
    }

    func start() {
        currentTimerInterval = config.refreshRate
        updateAll()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateAll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Data Collection

    private func updateAll() {
        // Self-correcting timer
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.updateAll()
            }
        }

        let smc = SMCReader.shared
        numFans = smc.fanCount()

        // Grow or shrink fan array
        while fans.count < numFans { fans.append(FanInfo()) }
        if fans.count > numFans { fans = Array(fans.prefix(numFans)) }

        for i in 0..<numFans {
            let rpm = smc.fanSpeed(index: i) ?? 0
            fans[i].rpm = rpm

            // Try reading min/max RPM via standard SMC keys
            let minKey = String(format: "F%dMn", i)
            let maxKey = String(format: "F%dMx", i)
            if let minVal = smc.readValue(key: minKey), minVal > 0 {
                fans[i].minRPM = minVal
            }
            if let maxVal = smc.readValue(key: maxKey), maxVal > 0 {
                fans[i].maxRPM = maxVal
            } else {
                fans[i].maxRPM = Double(config.maxRPMOverride)
            }

            fans[i].history.append(rpm)
            while fans[i].history.count > config.historyLength {
                fans[i].history.removeFirst()
            }
        }

        cpuTemp = smc.cpuTemperature()
        onDisplayUpdate?()
    }

    // MARK: - Helpers

    private func primaryFanIndex() -> Int {
        if config.showAllFans || config.selectedFanIndex >= numFans {
            return 0
        }
        return config.selectedFanIndex
    }

    private func rpmPct(fan: FanInfo) -> Double {
        let maxRPM = fan.maxRPM > 0 ? fan.maxRPM : Double(config.maxRPMOverride)
        guard maxRPM > 0 else { return 0 }
        return min(fan.rpm / maxRPM * 100.0, 100.0)
    }

    func accentForRPM(_ rpm: Double) -> NSColor {
        switch config.colorMode {
        case .fixed:
            return config.accentColor.color
        case .dynamic:
            return Self.dynamicRPMColor(rpm, warnRPM: Double(config.warnRPM))
        }
    }

    static func dynamicRPMColor(_ rpm: Double, warnRPM: Double) -> NSColor {
        if rpm >= warnRPM {
            return NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1) // red
        }
        let t = min(rpm / max(warnRPM, 1), 1.0)
        if t < 0.25 {
            let f = CGFloat(t / 0.25)
            return NSColor(red: 0.20 + 0.10 * f, green: 0.70 + 0.15 * f, blue: 0.90 - 0.05 * f, alpha: 1)
        } else if t < 0.50 {
            let f = CGFloat((t - 0.25) / 0.25)
            return NSColor(red: 0.30 - 0.05 * f, green: 0.85, blue: 0.85 - 0.30 * f, alpha: 1)
        } else if t < 0.75 {
            let f = CGFloat((t - 0.50) / 0.25)
            return NSColor(red: 0.25 + 0.70 * f, green: 0.85 - 0.05 * f, blue: 0.55 - 0.25 * f, alpha: 1)
        } else {
            let f = CGFloat((t - 0.75) / 0.25)
            return NSColor(red: 0.95 + 0.05 * f, green: 0.80 - 0.58 * f, blue: 0.30 - 0.10 * f, alpha: 1)
        }
    }

    func formatTemp(_ celsius: Double) -> String {
        switch config.tempUnit {
        case .celsius: return "\(Int(celsius))\u{00B0}C"
        case .fahrenheit:
            let f = celsius * 9.0 / 5.0 + 32.0
            return "\(Int(f))\u{00B0}F"
        }
    }

    func formatTempShort(_ celsius: Double) -> String {
        switch config.tempUnit {
        case .celsius: return "\(Int(celsius))\u{00B0}"
        case .fahrenheit:
            let f = celsius * 9.0 / 5.0 + 32.0
            return "\(Int(f))\u{00B0}"
        }
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        guard numFans > 0, !fans.isEmpty else {
            return .text("No Fans")
        }

        let idx = primaryFanIndex()
        let fan = fans[idx]
        let rpm = Int(fan.rpm)
        let color = accentForRPM(fan.rpm)

        switch config.displayMode {
        case .rpm:
            return renderAttributed(rpm: rpm, color: color, showLabel: true, fanIndex: idx)

        case .compact:
            return renderAttributed(rpm: rpm, color: color, showLabel: false, fanIndex: nil)

        case .sparkline:
            let sparkData = Array(fan.history.suffix(20))
            guard sparkData.count >= 2 else {
                return renderAttributed(rpm: rpm, color: color, showLabel: true, fanIndex: idx)
            }
            var label = "\(rpm)"
            if config.showTemperature, let t = cpuTemp { label += " \(formatTempShort(t))" }
            return .sparkline(sparkData, label: label, width: 100)

        case .multi:
            return renderMulti()

        case .percentage:
            let pct = Int(rpmPct(fan: fan))
            return renderPercentage(pct: pct, color: color, fanIndex: idx)
        }
    }

    private func renderAttributed(rpm: Int, color: NSColor, showLabel: Bool, fanIndex: Int?) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        if showLabel {
            var labelText = "Fan"
            if let fi = fanIndex, config.showFanNumber, numFans > 1 {
                labelText = config.compactLabels ? "F\(fi + 1)" : "Fan \(fi + 1)"
            }
            str.append(NSAttributedString(string: "\(labelText): ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5)
            ]))
        }
        str.append(NSAttributedString(string: "\(rpm) RPM", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]))
        if config.showTemperature, let t = cpuTemp {
            str.append(NSAttributedString(string: " \(formatTempShort(t))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: CPUWidget.colorForTemp(t).withAlphaComponent(0.7)
            ]))
        }
        return .attributedText(str)
    }

    private func renderMulti() -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        let limit = min(numFans, fans.count)
        for i in 0..<limit {
            if i > 0 {
                str.append(NSAttributedString(string: " ", attributes: [
                    .font: NSFont.systemFont(ofSize: 9)
                ]))
            }
            let rpm = Int(fans[i].rpm)
            let color = accentForRPM(fans[i].rpm)
            let label = config.compactLabels ? "F\(i + 1):" : "F\(i + 1): "
            str.append(NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: Theme.textMuted
            ]))
            str.append(NSAttributedString(string: "\(rpm)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: color
            ]))
        }
        return .attributedText(str)
    }

    private func renderPercentage(pct: Int, color: NSColor, fanIndex: Int) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        if config.showFanNumber && numFans > 1 {
            let label = config.compactLabels ? "F\(fanIndex + 1) " : "Fan \(fanIndex + 1) "
            str.append(NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5)
            ]))
        }
        str.append(NSAttributedString(string: "\(pct)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]))
        if config.showTemperature, let t = cpuTemp {
            str.append(NSAttributedString(string: " \(formatTempShort(t))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: CPUWidget.colorForTemp(t).withAlphaComponent(0.7)
            ]))
        }
        return .attributedText(str)
    }

    // MARK: - Dropdown (fallback NSMenu)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "FAN SPEED", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())
        for i in 0..<min(numFans, fans.count) {
            let item = NSMenuItem(title: "Fan \(i + 1): \(Int(fans[i].rpm)) RPM", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

// MARK: - Interactive Dropdown

extension FanSpeedWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 200 // header + fan cards
        let fanCardCount = min(numFans, fans.count)
        h += CGFloat(fanCardCount) * 64 + 8
        h += 60  // history chart
        if config.showTemperature { h += 50 } // temp correlation
        h += SuperWidgetKit.panelHeight + 8
        h += 40  // footer
        return NSSize(width: 340, height: min(max(h, 300), 760))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = ddHeader(in: container, y: y, pad: pad, cw: cw)
        y = ddFanCards(in: container, y: y, pad: pad, cw: cw)
        y = ddHistory(in: container, y: y, pad: pad, cw: cw)
        if config.showTemperature {
            y = ddTempCorrelation(in: container, y: y, pad: pad, cw: cw)
        }
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        ddFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let idx = primaryFanIndex()
        let primary = idx < fans.count ? fans[idx] : nil
        let primaryRPM = primary.map { "\(Int($0.rpm))" } ?? "--"
        let primaryPct = primary.map { "\(Int(rpmPct(fan: $0)))%" } ?? "--"
        let maxRPM = fans.map { $0.rpm }.max() ?? 0
        let avgRPM = fans.isEmpty ? 0 : fans.map { $0.rpm }.reduce(0, +) / Double(fans.count)
        let tempText = cpuTemp.map { formatTemp($0) } ?? "N/A"
        let tempInsight = cpuTemp.map { "CPU temp \(formatTemp($0))" } ?? "CPU temp unavailable"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Primary", value: primaryRPM, color: primary.map { accentForRPM($0.rpm) } ?? Theme.textMuted),
                SuperWidgetMetric(label: "Load", value: primaryPct, color: primary.map { accentForRPM($0.rpm) } ?? Theme.textMuted),
                SuperWidgetMetric(label: "Peak", value: "\(Int(maxRPM))", color: accentForRPM(maxRPM)),
                SuperWidgetMetric(label: "Temp", value: tempText, color: cpuTemp.map(CPUWidget.colorForTemp) ?? Theme.textMuted)
            ],
            insights: [
                "\(numFans) fan\(numFans == 1 ? "" : "s") detected",
                String(format: "Average %.0f RPM", avgRPM),
                tempInsight
            ],
            actions: [
                "Warn \(Int(config.warnRPM)) RPM",
                "Refresh \(Int(config.refreshRate))s",
                "Primary F\(idx + 1)"
            ],
            accent: primary.map { accentForRPM($0.rpm) } ?? config.accentColor.color
        )
    }

    // MARK: - Header

    private func ddHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Fan Speed")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let countText = numFans == 1 ? "1 fan detected" : "\(numFans) fans detected"
        let sub = NSTextField(labelWithString: countText)
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = Theme.textMuted
        sub.frame = NSRect(x: pad, y: y - 36, width: cw, height: 14)
        container.addSubview(sub)

        y -= 44
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Per-Fan Cards

    private func ddFanCards(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("FAN STATUS")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let limit = min(numFans, fans.count)
        guard limit > 0 else {
            let lbl = NSTextField(labelWithString: "No fans detected")
            lbl.font = .systemFont(ofSize: 10, weight: .regular)
            lbl.textColor = Theme.textFaint
            lbl.frame = NSRect(x: pad, y: y - 14, width: 200, height: 14)
            container.addSubview(lbl)
            y -= 18
            return y
        }

        for i in 0..<limit {
            let fan = fans[i]
            let cardH: CGFloat = 56
            let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
            container.addSubview(card)

            let color = accentForRPM(fan.rpm)

            // Fan label
            let fanLabel = NSTextField(labelWithString: "Fan \(i + 1)")
            fanLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            fanLabel.textColor = Theme.textSecondary
            fanLabel.frame = NSRect(x: 12, y: cardH - 20, width: 60, height: 16)
            card.addSubview(fanLabel)

            // RPM value
            let rpmLabel = NSTextField(labelWithString: "\(Int(fan.rpm)) RPM")
            rpmLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .heavy)
            rpmLabel.textColor = color
            rpmLabel.frame = NSRect(x: 12, y: 6, width: 120, height: 22)
            card.addSubview(rpmLabel)

            // Percentage
            let pct = rpmPct(fan: fan)
            let pctLabel = NSTextField(labelWithString: "\(Int(pct))%")
            pctLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            pctLabel.textColor = color.withAlphaComponent(0.7)
            pctLabel.alignment = .right
            pctLabel.frame = NSRect(x: cw - 52, y: cardH - 20, width: 40, height: 16)
            card.addSubview(pctLabel)

            // RPM gauge bar
            let barX: CGFloat = 130
            let barW: CGFloat = cw - barX - 12
            let barH: CGFloat = 6

            let barBg = NSView(frame: NSRect(x: barX, y: 10, width: barW, height: barH))
            barBg.wantsLayer = true
            barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            barBg.layer?.cornerRadius = 3
            card.addSubview(barBg)

            let fillW = barW * CGFloat(min(pct / 100.0, 1.0))
            if fillW > 0 {
                let fill = NSView(frame: NSRect(x: barX, y: 10, width: fillW, height: barH))
                fill.wantsLayer = true
                fill.layer?.backgroundColor = color.withAlphaComponent(0.7).cgColor
                fill.layer?.cornerRadius = 3
                card.addSubview(fill)
            }

            // Min / Max labels
            if config.showMinMax {
                let minStr = "Min: \(Int(fan.minRPM))"
                let maxStr = "Max: \(Int(fan.maxRPM))"
                let minLabel = NSTextField(labelWithString: minStr)
                minLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
                minLabel.textColor = Theme.textFaint
                minLabel.frame = NSRect(x: barX, y: 20, width: 60, height: 10)
                card.addSubview(minLabel)

                let maxLabel = NSTextField(labelWithString: maxStr)
                maxLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
                maxLabel.textColor = Theme.textFaint
                maxLabel.alignment = .right
                maxLabel.frame = NSRect(x: barX + barW - 70, y: 20, width: 70, height: 10)
                card.addSubview(maxLabel)
            }

            // Mini sparkline in card
            let sparkData = Array(fan.history.suffix(20))
            if sparkData.count >= 2 {
                let sparkW: CGFloat = barW
                let sparkH: CGFloat = 18
                let img = SparklineRenderer.render(data: sparkData, width: sparkW, style: SparklineRenderer.Style(
                    lineColor: color.withAlphaComponent(0.4),
                    fillColor: color.withAlphaComponent(0.06),
                    lineWidth: 1, height: sparkH, pointRadius: 0
                ))
                let iv = NSImageView(frame: NSRect(x: barX, y: cardH - sparkH - 4, width: sparkW, height: sparkH))
                iv.image = img; iv.imageScaling = .scaleNone
                card.addSubview(iv)
            }

            y -= cardH + 4
        }

        y -= 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - RPM History Chart

    private func ddHistory(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("RPM HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)

        // Stats
        let idx = primaryFanIndex()
        if idx < fans.count && !fans[idx].history.isEmpty {
            let hist = fans[idx].history
            let avg = hist.reduce(0, +) / Double(hist.count)
            let peak = hist.max() ?? 0
            let low = hist.min() ?? 0
            let info = String(format: "avg %.0f  lo %.0f  hi %.0f RPM", avg, low, peak)
            let il = NSTextField(labelWithString: info)
            il.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            il.textColor = Theme.textFaint; il.alignment = .right
            il.frame = NSRect(x: pad + 120, y: y - 12, width: cw - 120, height: 12)
            container.addSubview(il)
        }
        y -= 18

        let chartH: CGFloat = 44
        let chartBg = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        // Warn threshold line
        if idx < fans.count {
            let fan = fans[idx]
            let maxRPM = fan.maxRPM > 0 ? fan.maxRPM : Double(config.maxRPMOverride)
            if maxRPM > 0 {
                let warnFrac = Double(config.warnRPM) / maxRPM
                let threshY = CGFloat(min(warnFrac, 1.0)) * (chartH - 4) + 2
                let threshLine = NSView(frame: NSRect(x: 0, y: threshY, width: cw, height: 1))
                threshLine.wantsLayer = true
                threshLine.layer?.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.25).cgColor
                chartBg.addSubview(threshLine)
            }
        }

        // Draw sparklines for all fans
        let limit = min(numFans, fans.count)
        let fanColors: [NSColor] = [
            NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1),
            NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1),
            NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1),
            NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1),
        ]

        for i in 0..<limit {
            let chartData = Array(fans[i].history.suffix(50))
            guard chartData.count >= 2 else { continue }
            let clr = i < fanColors.count ? fanColors[i] : config.accentColor.color
            let isPrimary = i == idx
            let img = SparklineRenderer.render(data: chartData, width: cw, style: SparklineRenderer.Style(
                lineColor: isPrimary ? clr : clr.withAlphaComponent(0.4),
                fillColor: isPrimary ? clr.withAlphaComponent(0.10) : nil,
                lineWidth: isPrimary ? 1.5 : 1, height: chartH, pointRadius: isPrimary ? 1.5 : 0
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        }

        y -= chartH + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - CPU Temp Correlation

    private func ddTempCorrelation(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("CPU TEMP CORRELATION")
        header.frame = NSRect(x: pad, y: y - 12, width: 200, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 36
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        if let temp = cpuTemp {
            // Temp value
            let tempLabel = NSTextField(labelWithString: formatTemp(temp))
            tempLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .heavy)
            tempLabel.textColor = CPUWidget.colorForTemp(temp)
            tempLabel.frame = NSRect(x: 12, y: 6, width: 80, height: 22)
            card.addSubview(tempLabel)

            let cpuLabel = NSTextField(labelWithString: "CPU Temp")
            cpuLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            cpuLabel.textColor = Theme.textFaint
            cpuLabel.frame = NSRect(x: 94, y: 12, width: 60, height: 12)
            card.addSubview(cpuLabel)

            // Primary fan RPM next to it
            let idx = primaryFanIndex()
            if idx < fans.count {
                let rpm = Int(fans[idx].rpm)
                let rpmVal = NSTextField(labelWithString: "\(rpm) RPM")
                rpmVal.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
                rpmVal.textColor = accentForRPM(fans[idx].rpm)
                rpmVal.alignment = .right
                rpmVal.frame = NSRect(x: cw - 110, y: 8, width: 98, height: 20)
                card.addSubview(rpmVal)
            }
        } else {
            let lbl = NSTextField(labelWithString: "Temperature unavailable")
            lbl.font = .systemFont(ofSize: 10, weight: .regular)
            lbl.textColor = Theme.textFaint
            lbl.frame = NSRect(x: 12, y: 10, width: 200, height: 14)
            card.addSubview(lbl)
        }

        y -= cardH + 4
        return y
    }

    // MARK: - Footer

    @discardableResult
    private func ddFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4

        var parts: [String] = []
        parts.append("\(numFans) fan\(numFans == 1 ? "" : "s")")
        if let t = cpuTemp { parts.append(formatTemp(t)) }
        let idx = primaryFanIndex()
        if idx < fans.count {
            parts.append("\(Int(fans[idx].rpm)) RPM")
        }

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
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
}

// MARK: - Declarative Config

extension FanSpeedWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "RPM (Fan: 2100 RPM)", value: "rpm"),
                (title: "Compact (2100)", value: "compact"),
                (title: "Sparkline + RPM", value: "sparkline"),
                (title: "Multi-fan (F1: 2100 F2: 1800)", value: "multi"),
                (title: "Percentage of Max", value: "percentage"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "rpm" },
               set: { [weak self] in self?.config.displayMode = FanSpeedConfig.FanDisplayMode(rawValue: $0) ?? .rpm }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (shifts with RPM)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = FanSpeedConfig.ColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "cyan" },
               set: { [weak self] in self?.config.accentColor = FanSpeedConfig.AccentPreset(rawValue: $0) ?? .cyan }),

            .section(title: "Fan Selection"),
            .toggle(label: "Show All Fans", key: "showAllFans",
                    get: { [weak self] in self?.config.showAllFans ?? true },
                    set: { [weak self] in self?.config.showAllFans = $0 }),
            .slider(label: "Selected Fan Index", key: "selectedFanIndex", min: 0, max: 3, step: 1,
                    get: { [weak self] in Double(self?.config.selectedFanIndex ?? 0) },
                    set: { [weak self] in self?.config.selectedFanIndex = Int($0) },
                    format: "Fan %.0f"),
            .toggle(label: "Show Fan Number", key: "showFanNumber",
                    get: { [weak self] in self?.config.showFanNumber ?? true },
                    set: { [weak self] in self?.config.showFanNumber = $0 }),
            .toggle(label: "Show as Percentage", key: "showAsPercentage",
                    get: { [weak self] in self?.config.showAsPercentage ?? false },
                    set: { [weak self] in self?.config.showAsPercentage = $0 }),

            .section(title: "Temperature"),
            .toggle(label: "Show CPU Temperature", key: "showTemperature",
                    get: { [weak self] in self?.config.showTemperature ?? true },
                    set: { [weak self] in self?.config.showTemperature = $0 }),
            .picker(label: "Temperature Unit", key: "tempUnit", options: [
                (title: "Celsius (\u{00B0}C)", value: "celsius"),
                (title: "Fahrenheit (\u{00B0}F)", value: "fahrenheit"),
            ], get: { [weak self] in self?.config.tempUnit.rawValue ?? "celsius" },
               set: { [weak self] in self?.config.tempUnit = FanSpeedConfig.TempUnit(rawValue: $0) ?? .celsius }),

            .section(title: "Alerts & Limits"),
            .slider(label: "Warn RPM Threshold", key: "warnRPM", min: 2000, max: 6000, step: 200,
                    get: { [weak self] in Double(self?.config.warnRPM ?? 4000) },
                    set: { [weak self] in self?.config.warnRPM = Int($0) },
                    format: "%.0f RPM"),
            .slider(label: "Max RPM Override", key: "maxRPMOverride", min: 3000, max: 8000, step: 200,
                    get: { [weak self] in Double(self?.config.maxRPMOverride ?? 6200) },
                    set: { [weak self] in self?.config.maxRPMOverride = Int($0) },
                    format: "%.0f RPM"),
            .toggle(label: "Show Min/Max in Dropdown", key: "showMinMax",
                    get: { [weak self] in self?.config.showMinMax ?? true },
                    set: { [weak self] in self?.config.showMinMax = $0 }),

            .section(title: "Labels"),
            .toggle(label: "Compact Labels", key: "compactLabels",
                    get: { [weak self] in self?.config.compactLabels ?? false },
                    set: { [weak self] in self?.config.compactLabels = $0 }),
            .toggle(label: "Show Fan Count", key: "showFanCount",
                    get: { [weak self] in self?.config.showFanCount ?? false },
                    set: { [weak self] in self?.config.showFanCount = $0 }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 15, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 3 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "History Length", key: "historyLength", min: 20, max: 120, step: 10,
                    get: { [weak self] in Double(self?.config.historyLength ?? 60) },
                    set: { [weak self] in self?.config.historyLength = Int($0) },
                    format: "%.0f pts"),
        ]
    }
}
