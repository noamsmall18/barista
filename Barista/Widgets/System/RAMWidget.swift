import Cocoa

// MARK: - Config

struct RAMConfig: Codable, Equatable {
    var displayMode: RAMDisplayMode
    var accentColor: RAMAccent
    var colorMode: RAMColorMode
    var alertThreshold: Double
    var showSwap: Bool
    var showPressure: Bool
    var showProcesses: Bool
    var processCount: Int
    var showBreakdownInDropdown: Bool
    var refreshRate: TimeInterval
    var historyLength: Int

    static let `default` = RAMConfig(
        displayMode: .text,
        accentColor: .green,
        colorMode: .dynamic,
        alertThreshold: 80,
        showSwap: true,
        showPressure: true,
        showProcesses: true,
        processCount: 5,
        showBreakdownInDropdown: true,
        refreshRate: 1,
        historyLength: 60
    )

    enum RAMDisplayMode: String, Codable, Equatable {
        case text         // "RAM 67%"
        case absolute     // "RAM 5.4/8GB"
        case sparkline    // sparkline + %
        case ring         // ring gauge + %
        case bar          // "RAM [|||||||...] 67%"
    }

    enum RAMAccent: String, Codable, Equatable, CaseIterable {
        case green, cyan, blue, amber, purple, red, white

        var color: NSColor {
            switch self {
            case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
            case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
            case .amber:  return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
            case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
            case .red:    return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
    }

    enum RAMColorMode: String, Codable, Equatable {
        case dynamic  // green -> yellow -> red with usage
        case fixed    // always uses accentColor
    }
}

// MARK: - Widget

class RAMWidget: BaristaWidget {
    static let widgetID = "ram-monitor"
    static let displayName = "RAM Monitor"
    static let subtitle = "Memory usage, pressure, swap & processes"
    static let iconName = "memorychip"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = RAMConfig.default

    var config: RAMConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    // Aggregate
    private(set) var totalGB: Double = 0
    private(set) var usedGB: Double = 0
    private(set) var percentage: Double = 0

    // Breakdown (bytes)
    private(set) var activeBytes: Double = 0
    private(set) var inactiveBytes: Double = 0
    private(set) var wiredBytes: Double = 0
    private(set) var compressedBytes: Double = 0
    private(set) var freeBytes: Double = 0
    private(set) var purgeableBytes: Double = 0

    // Swap
    private(set) var swapUsed: Double = 0
    private(set) var swapTotal: Double = 0

    // Pressure
    private(set) var pressureLevel: Int = 0 // 0=normal, 1=warn, 2=critical, 4=urgent
    private(set) var pageouts: UInt64 = 0
    private(set) var compressions: UInt64 = 0
    private(set) var decompressions: UInt64 = 0

    // History
    private(set) var usageHistory: [Double] = []
    private(set) var pressureHistory: [Int] = []

    // Top processes
    private(set) var topProcesses: [(name: String, pid: Int32, memMB: Double)] = []
    private var processCounter = 0

    // App memory
    private(set) var appMemoryMB: Double = 0

    required init(config: RAMConfig) {
        self.config = config
        totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    func start() {
        let rate = config.refreshRate
        currentTimerInterval = rate
        updateAll()
        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.updateAll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Data Collection

    private func updateAll() {
        // Self-correct timer
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.updateAll()
            }
        }

        updateVMStats()
        updateSwap()
        updatePressure()
        updateAppMemory()

        // Processes every 3rd tick
        processCounter += 1
        if processCounter >= 3 {
            processCounter = 0
            updateTopProcessesAsync()
        }
        onDisplayUpdate?()
    }

    private func updateVMStats() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let ps = Double(vm_kernel_page_size)
        activeBytes = Double(stats.active_count) * ps
        inactiveBytes = Double(stats.inactive_count) * ps
        wiredBytes = Double(stats.wire_count) * ps
        compressedBytes = Double(stats.compressor_page_count) * ps
        freeBytes = Double(stats.free_count) * ps
        purgeableBytes = Double(stats.purgeable_count) * ps

        let speculative = Double(stats.speculative_count) * ps
        let used = activeBytes + wiredBytes + compressedBytes - speculative
        usedGB = max(used / 1_073_741_824, 0)
        percentage = min((usedGB / totalGB) * 100, 100)

        pageouts = UInt64(stats.pageouts)
        compressions = UInt64(stats.compressions)
        decompressions = UInt64(stats.decompressions)

        // History
        usageHistory.append(percentage)
        while usageHistory.count > config.historyLength { usageHistory.removeFirst() }
    }

    private func updateSwap() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        swapUsed = Double(usage.xsu_used)
        swapTotal = Double(usage.xsu_total)
    }

    private func updatePressure() {
        var pressure: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &sz, nil, 0) == 0 {
            pressureLevel = Int(pressure)
            pressureHistory.append(pressureLevel)
            while pressureHistory.count > config.historyLength { pressureHistory.removeFirst() }
        }
    }

    private func updateAppMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            appMemoryMB = Double(info.resident_size) / 1_048_576
        }
    }

    private func updateTopProcessesAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let maxProcs = self.config.processCount
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-eo", "pid,rss,comm", "-r"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else { return }
                var results: [(String, Int32, Double)] = []
                for line in output.components(separatedBy: "\n").dropFirst() {
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    guard parts.count >= 3 else { continue }
                    guard let pid = Int32(parts[0]), let rssKB = Double(parts[1]) else { continue }
                    let name = parts[2...].joined(separator: " ")
                    let shortName = (name as NSString).lastPathComponent
                    results.append((shortName, pid, rssKB / 1024.0))
                    if results.count >= maxProcs { break }
                }
                DispatchQueue.main.async {
                    self.topProcesses = results
                }
            } catch {}
        }
    }

    // MARK: - Colors

    func colorForUsage(_ pct: Double) -> NSColor {
        switch config.colorMode {
        case .fixed: return config.accentColor.color
        case .dynamic:
            if pct < 50 { return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) }
            if pct < 70 { return NSColor(red: 0.60, green: 0.85, blue: 0.40, alpha: 1) }
            if pct < 85 { return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1) }
            if pct < 95 { return NSColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1) }
            return NSColor(red: 1.0, green: 0.30, blue: 0.25, alpha: 1)
        }
    }

    static func colorForPressure(_ level: Int) -> NSColor {
        switch level {
        case 0: return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
        case 1: return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1)
        case 2: return NSColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1)
        default: return NSColor(red: 1.0, green: 0.25, blue: 0.25, alpha: 1) // 4 = urgent
        }
    }

    static func pressureLabel(_ level: Int) -> String {
        switch level {
        case 0: return "Normal"
        case 1: return "Warning"
        case 2: return "Critical"
        case 4: return "Urgent"
        default: return "Unknown"
        }
    }

    // MARK: - Formatting

    private func formatGB(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 10 { return String(format: "%.0fGB", gb) }
        return String(format: "%.1fGB", gb)
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        let color = colorForUsage(percentage)

        switch config.displayMode {
        case .text:
            var label = String(format: "RAM %d%%", Int(percentage))
            if config.showSwap && swapUsed > 0 {
                label += String(format: " Sw%.0fG", swapUsed / 1_073_741_824)
            }
            if percentage >= config.alertThreshold {
                let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                let attr = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
                return .attributedText(attr)
            }
            return .text(label)

        case .absolute:
            let label = String(format: "RAM %.1f/%.0fGB", usedGB, totalGB)
            if percentage >= config.alertThreshold {
                let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                let attr = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
                return .attributedText(attr)
            }
            return .text(label)

        case .sparkline:
            let data = Array(usageHistory.suffix(30))
            guard data.count >= 2 else { return .text(String(format: "RAM %d%%", Int(percentage))) }
            let img = SparklineRenderer.render(data: data, width: 50, style: SparklineRenderer.Style(
                lineColor: color, fillColor: color.withAlphaComponent(0.15),
                lineWidth: 1.5, height: 16, pointRadius: 1.5
            ))
            return .iconAndText(img, String(format: "%d%%", Int(percentage)))

        case .ring:
            let img = SparklineRenderer.renderRing(percentage: percentage, size: 18, color: color, lineWidth: 3)
            return .iconAndText(img, String(format: "%d%%", Int(percentage)))

        case .bar:
            let filled = Int(percentage / 10)
            let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
            let label = "RAM \(bar) \(Int(percentage))%"
            if percentage >= config.alertThreshold {
                let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                let attr = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
                return .attributedText(attr)
            }
            return .text(label)
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "MEMORY", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}

// MARK: - Interactive Dropdown

extension RAMWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 200 // header + gauge card + info chips
        if config.showBreakdownInDropdown { h += 90 } // breakdown bars
        h += 68 // history chart
        if config.showProcesses {
            h += CGFloat(min(topProcesses.count, config.processCount)) * 22 + 30
        }
        h += SuperWidgetKit.panelHeight + 8
        h += 40 // footer
        return NSSize(width: 340, height: min(max(h, 300), 760))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildDDHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildGaugeCard(in: container, y: y, pad: pad, cw: cw)

        if config.showBreakdownInDropdown {
            y = buildBreakdown(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildHistoryChart(in: container, y: y, pad: pad, cw: cw)

        if config.showProcesses {
            y = buildProcesses(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildDDFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let freeGB = max(totalGB - usedGB, 0)
        let pressureText = Self.pressureLabel(pressureLevel)
        let pressureColor = Self.colorForPressure(pressureLevel)
        let swapText = swapTotal > 0 ? String(format: "%.1fG", swapUsed / 1e9) : "None"
        let topRSS = topProcesses.first.map { "\($0.name) \(formatMB($0.memMB))" } ?? "No heavy process"
        let trend = (usageHistory.last ?? percentage) >= (usageHistory.dropLast().last ?? percentage) ? "Memory rising" : "Memory easing"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Used", value: String(format: "%.1fG", usedGB), color: colorForUsage(percentage)),
                SuperWidgetMetric(label: "Free", value: String(format: "%.1fG", freeGB), color: Theme.green),
                SuperWidgetMetric(label: "Swap", value: swapText, color: swapUsed > 1e9 ? Theme.orange : Theme.textMuted),
                SuperWidgetMetric(label: "Pressure", value: pressureText, color: pressureColor)
            ],
            insights: [
                trend,
                "Compressed \(formatGB(compressedBytes))",
                "Top: \(topRSS)"
            ],
            actions: [
                "Refresh \(Int(config.refreshRate))s",
                "History \(usageHistory.count) pts",
                "Barista \(String(format: "%.0f MB", appMemoryMB))"
            ],
            accent: pressureColor
        )
    }

    // MARK: - Header

    private func buildDDHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let title = NSTextField(labelWithString: "RAM Monitor")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let sub = NSTextField(labelWithString: String(format: "%.0f GB Physical Memory", totalGB))
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = Theme.textMuted
        sub.frame = NSRect(x: pad, y: y - 36, width: cw, height: 14)
        container.addSubview(sub)

        y -= 44
        addDD(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Gauge Card

    private func buildGaugeCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 80
        let card = makeDD(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Ring gauge
        let ringSize: CGFloat = 58
        let ringColor = colorForUsage(percentage)
        let ringImg = SparklineRenderer.renderRing(percentage: percentage, size: ringSize, color: ringColor, lineWidth: 5)
        let ringView = NSImageView(frame: NSRect(x: 12, y: (cardH - ringSize) / 2, width: ringSize, height: ringSize))
        ringView.image = ringImg
        card.addSubview(ringView)

        // Percentage in ring center
        let pctLabel = NSTextField(labelWithString: "\(Int(percentage))%")
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        pctLabel.textColor = ringColor
        pctLabel.alignment = .center
        pctLabel.frame = NSRect(x: 12, y: (cardH - 22) / 2, width: ringSize, height: 22)
        card.addSubview(pctLabel)

        // Right side: stats
        let sx: CGFloat = ringSize + 24
        let sw = cw - sx - 8
        var sy = cardH - 14

        // Stacked bar: active, wired, compressed
        let barH: CGFloat = 6
        let barBg = NSView(frame: NSRect(x: sx, y: sy - barH + 2, width: sw, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 3
        card.addSubview(barBg)

        let totalBytes = totalGB * 1_073_741_824
        let activeW = sw * CGFloat(activeBytes / totalBytes)
        let wiredW = sw * CGFloat(wiredBytes / totalBytes)
        let compW = sw * CGFloat(compressedBytes / totalBytes)

        var bx = sx
        let segments: [(CGFloat, NSColor)] = [
            (activeW, NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 0.8)),
            (wiredW, NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 0.8)),
            (compW, NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 0.8)),
        ]
        for (w, color) in segments where w > 0 {
            let seg = NSView(frame: NSRect(x: bx, y: sy - barH + 2, width: min(w, sw - (bx - sx)), height: barH))
            seg.wantsLayer = true
            seg.layer?.backgroundColor = color.cgColor
            if bx == sx { seg.layer?.cornerRadius = 3 }
            card.addSubview(seg)
            bx += w
        }
        sy -= barH + 6

        let rows: [(String, String, NSColor)] = [
            ("Used", String(format: "%.1f GB", usedGB), ringColor),
            ("Free", String(format: "%.1f GB", totalGB - usedGB), Theme.textFaint),
            ("Swap", swapUsed > 0 ? String(format: "%.1f GB", swapUsed / 1e9) : "None", swapUsed > 1e9 ? NSColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1) : Theme.textFaint),
        ]
        for (label, value, color) in rows {
            addStatPair(in: card, label: label, value: value, color: color, x: sx, y: sy - 12, w: sw)
            sy -= 16
        }

        y -= cardH + 8

        // Info chips
        var chips: [(String, String, NSColor)] = []
        if config.showPressure {
            let pColor = Self.colorForPressure(pressureLevel)
            chips.append((Self.pressureLabel(pressureLevel), "Pressure", pColor))
        }
        chips.append((String(format: "%.1f GB", compressedBytes / 1e9), "Compressed", NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)))
        chips.append((String(format: "%.1f GB", wiredBytes / 1e9), "Wired", NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 1)))
        if config.showSwap && swapTotal > 0 {
            chips.append((String(format: "%.1f/%.0fG", swapUsed / 1e9, swapTotal / 1e9), "Swap", Theme.textSecondary))
        }

        if !chips.isEmpty {
            let chipW = (cw - CGFloat(chips.count - 1) * 6) / CGFloat(chips.count)
            for (i, (val, label, color)) in chips.enumerated() {
                let cx = pad + CGFloat(i) * (chipW + 6)
                let chip = makeDD(x: cx, y: y - 40, w: chipW, h: 40)
                container.addSubview(chip)

                let vl = NSTextField(labelWithString: val)
                vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
                vl.textColor = color; vl.alignment = .center
                vl.lineBreakMode = .byTruncatingTail
                vl.frame = NSRect(x: 2, y: 16, width: chipW - 4, height: 16)
                chip.addSubview(vl)

                let ll = NSTextField(labelWithString: label)
                ll.font = .systemFont(ofSize: 8, weight: .semibold)
                ll.textColor = Theme.textFaint; ll.alignment = .center
                ll.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
                chip.addSubview(ll)
            }
            y -= 48
        }

        addDD(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Breakdown Bars

    private func buildBreakdown(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let header = Theme.sectionHeader("MEMORY BREAKDOWN")
        header.frame = NSRect(x: pad, y: y - 12, width: 200, height: 12)
        container.addSubview(header)
        y -= 18

        let totalBytes = totalGB * 1_073_741_824
        let categories: [(String, Double, NSColor)] = [
            ("Active", activeBytes, NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)),
            ("Wired", wiredBytes, NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 1)),
            ("Compressed", compressedBytes, NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)),
            ("Inactive", inactiveBytes, NSColor(red: 0.50, green: 0.50, blue: 0.55, alpha: 1)),
            ("Free", freeBytes, NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.5)),
        ]

        for (name, bytes, color) in categories {
            let rowH: CGFloat = 14
            let pct = totalBytes > 0 ? bytes / totalBytes : 0

            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 9.5, weight: .medium)
            label.textColor = Theme.textSecondary
            label.frame = NSRect(x: pad, y: y - rowH, width: 70, height: rowH)
            container.addSubview(label)

            // Bar
            let barX = pad + 72
            let barW = cw - 72 - 56
            let barBg = NSView(frame: NSRect(x: barX, y: y - rowH + 3, width: barW, height: 6))
            barBg.wantsLayer = true
            barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            barBg.layer?.cornerRadius = 3
            container.addSubview(barBg)

            let fillW = max(barW * CGFloat(pct), 1)
            let fill = NSView(frame: NSRect(x: barX, y: y - rowH + 3, width: fillW, height: 6))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = color.withAlphaComponent(0.6).cgColor
            fill.layer?.cornerRadius = 3
            container.addSubview(fill)

            let valLabel = NSTextField(labelWithString: formatGB(bytes))
            valLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
            valLabel.textColor = color
            valLabel.alignment = .right
            valLabel.frame = NSRect(x: pad + cw - 54, y: y - rowH, width: 50, height: rowH)
            container.addSubview(valLabel)

            y -= rowH + 2
        }
        y -= 4
        addDD(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - History Chart

    private func buildHistoryChart(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let header = Theme.sectionHeader("HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 80, height: 12)
        container.addSubview(header)

        if !usageHistory.isEmpty {
            let avg = usageHistory.reduce(0, +) / Double(usageHistory.count)
            let peak = usageHistory.max() ?? 0
            let info = String(format: "avg %.0f%%  peak %.0f%%", avg, peak)
            let il = NSTextField(labelWithString: info)
            il.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            il.textColor = Theme.textFaint; il.alignment = .right
            il.frame = NSRect(x: pad + 80, y: y - 12, width: cw - 80, height: 12)
            container.addSubview(il)
        }
        y -= 18

        let chartH: CGFloat = 44
        let chartBg = makeDD(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        // Threshold line
        if config.alertThreshold < 100 {
            let threshY = CGFloat(config.alertThreshold / 100.0) * (chartH - 4) + 2
            let threshLine = NSView(frame: NSRect(x: 0, y: threshY, width: cw, height: 1))
            threshLine.wantsLayer = true
            threshLine.layer?.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.25).cgColor
            chartBg.addSubview(threshLine)
        }

        let chartData = Array(usageHistory.suffix(50))
        if chartData.count >= 2 {
            let lineColor = colorForUsage(percentage)
            let img = SparklineRenderer.render(data: chartData, width: cw, style: SparklineRenderer.Style(
                lineColor: lineColor,
                fillColor: lineColor.withAlphaComponent(0.10),
                lineWidth: 1.5, height: chartH, pointRadius: 1.5
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)
        }

        y -= chartH + 4
        addDD(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Top Processes

    private func buildProcesses(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let header = Theme.sectionHeader("TOP PROCESSES (RSS)")
        header.frame = NSRect(x: pad, y: y - 12, width: 180, height: 12)
        container.addSubview(header)
        y -= 18

        let procs = Array(topProcesses.prefix(config.processCount))
        if procs.isEmpty {
            let lbl = NSTextField(labelWithString: "Collecting...")
            lbl.font = .systemFont(ofSize: 10); lbl.textColor = Theme.textFaint
            lbl.frame = NSRect(x: pad, y: y - 14, width: 200, height: 14)
            container.addSubview(lbl)
            y -= 18
        } else {
            for (i, proc) in procs.enumerated() {
                let rowH: CGFloat = 20
                let rowBg = NSView(frame: NSRect(x: pad, y: y - rowH, width: cw, height: rowH))
                rowBg.wantsLayer = true
                rowBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.02 : 0.0).cgColor
                rowBg.layer?.cornerRadius = 4
                container.addSubview(rowBg)

                // Fill bar
                let pctOfTotal = proc.memMB / (totalGB * 1024) * 100
                let fillPct = min(pctOfTotal / 20.0, 1.0) // Scale: 20% = full bar
                let fillW = cw * CGFloat(fillPct)
                if fillW > 0 {
                    let fill = NSView(frame: NSRect(x: pad, y: y - rowH, width: fillW, height: rowH))
                    fill.wantsLayer = true
                    fill.layer?.backgroundColor = colorForUsage(pctOfTotal * 5).withAlphaComponent(0.08).cgColor
                    fill.layer?.cornerRadius = 4
                    container.addSubview(fill)
                }

                let rank = NSTextField(labelWithString: "\(i + 1)")
                rank.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
                rank.textColor = Theme.textFaint
                rank.frame = NSRect(x: pad + 6, y: y - rowH + 3, width: 14, height: 14)
                container.addSubview(rank)

                let maxLen = 24
                let displayName = proc.name.count > maxLen ? String(proc.name.prefix(maxLen - 2)) + ".." : proc.name
                let name = NSTextField(labelWithString: displayName)
                name.font = .systemFont(ofSize: 10.5, weight: .medium)
                name.textColor = Theme.textSecondary
                name.lineBreakMode = .byTruncatingTail
                name.frame = NSRect(x: pad + 22, y: y - rowH + 3, width: cw - 90, height: 14)
                container.addSubview(name)

                let memLabel = NSTextField(labelWithString: formatMB(proc.memMB))
                memLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
                memLabel.textColor = colorForUsage(pctOfTotal * 5)
                memLabel.alignment = .right
                memLabel.frame = NSRect(x: pad + cw - 62, y: y - rowH + 3, width: 56, height: 14)
                container.addSubview(memLabel)

                y -= rowH + 2
            }
        }
        return y
    }

    // MARK: - Footer

    @discardableResult
    private func buildDDFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        let pLabel = Self.pressureLabel(pressureLevel)
        let footer = NSTextField(labelWithString: "Pressure: \(pLabel)  \u{00B7}  Barista: \(String(format: "%.0f MB", appMemoryMB))")
        footer.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: - UI Helpers

    private func makeDD(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return v
    }

    private func addDD(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
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
        val.frame = NSRect(x: x + 48, y: y, width: w - 48, height: 14)
        parent.addSubview(val)
    }
}

// MARK: - Declarative Config

extension RAMWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Percentage (RAM 67%)", value: "text"),
                (title: "Absolute (RAM 5.4/8GB)", value: "absolute"),
                (title: "Sparkline + %", value: "sparkline"),
                (title: "Ring Gauge + %", value: "ring"),
                (title: "Bar + %", value: "bar"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "text" },
               set: { [weak self] in self?.config.displayMode = RAMConfig.RAMDisplayMode(rawValue: $0) ?? .text }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (green to red)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = RAMConfig.RAMColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Green", value: "green"),
                (title: "Cyan", value: "cyan"),
                (title: "Blue", value: "blue"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "green" },
               set: { [weak self] in self?.config.accentColor = RAMConfig.RAMAccent(rawValue: $0) ?? .green }),

            .section(title: "Menu Bar"),
            .toggle(label: "Show Swap in Menu Bar", key: "showSwap",
                    get: { [weak self] in self?.config.showSwap ?? true },
                    set: { [weak self] in self?.config.showSwap = $0 }),
            .slider(label: "Alert Threshold", key: "alertThreshold", min: 50, max: 100, step: 5,
                    get: { [weak self] in self?.config.alertThreshold ?? 80 },
                    set: { [weak self] in self?.config.alertThreshold = $0 },
                    format: "%.0f%%"),

            .section(title: "Dropdown"),
            .toggle(label: "Show Memory Breakdown", key: "showBreakdownInDropdown",
                    get: { [weak self] in self?.config.showBreakdownInDropdown ?? true },
                    set: { [weak self] in self?.config.showBreakdownInDropdown = $0 }),
            .toggle(label: "Show Pressure", key: "showPressure",
                    get: { [weak self] in self?.config.showPressure ?? true },
                    set: { [weak self] in self?.config.showPressure = $0 }),
            .toggle(label: "Show Top Processes", key: "showProcesses",
                    get: { [weak self] in self?.config.showProcesses ?? true },
                    set: { [weak self] in self?.config.showProcesses = $0 }),
            .slider(label: "Process Count", key: "processCount", min: 3, max: 8, step: 1,
                    get: { [weak self] in Double(self?.config.processCount ?? 5) },
                    set: { [weak self] in self?.config.processCount = Int($0) },
                    format: "%.0f"),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 30, step: 1,
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
