import Cocoa
import Darwin
import IOKit.ps

struct SystemHealthConfig: Codable, Equatable {
    var refreshRate: TimeInterval = 1
    var historyLength: Int = 90
    var showNetwork: Bool = true
    var showBattery: Bool = true
    var compactMode: Bool = false

    static let `default` = SystemHealthConfig()
}

class SystemHealthWidget: BaristaWidget {
    static let widgetID = "system-health"
    static let displayName = "System Health"
    static let subtitle = "CPU, memory, battery, network and uptime in one terminal"
    static let iconName = "gauge.with.dots.needle.bottom.50percent"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = SystemHealthConfig.default

    var config: SystemHealthConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    private(set) var cpuUsage: Double = 0
    private(set) var ramUsage: Double = 0
    private(set) var usedGB: Double = 0
    private(set) var totalGB: Double = 0
    private(set) var batteryLevel: Int = -1
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var downloadSpeed: Double = 0
    private(set) var uploadSpeed: Double = 0
    private(set) var loadAvg: (Double, Double, Double) = (0, 0, 0)
    private(set) var healthScore: Int = 100
    private(set) var topProcess: String = "Collecting"

    private var cpuHistory: [Double] = []
    private var ramHistory: [Double] = []
    private var downHistory: [Double] = []
    private var upHistory: [Double] = []

    private var prevUser: Double = 0
    private var prevSystem: Double = 0
    private var prevIdle: Double = 0
    private var prevNice: Double = 0
    private var primedCPU = false

    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastNetworkTime: Date?
    private var processCounter = 0

    required init(config: SystemHealthConfig) {
        self.config = config
        self.totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    func start() {
        currentTimerInterval = config.refreshRate
        primeCPU()
        let bytes = Self.networkBytes()
        lastBytesIn = bytes.in
        lastBytesOut = bytes.out
        lastNetworkTime = Date()
        updateAll()
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
        updateAll()
    }

    private func updateAll() {
        updateCPU()
        updateMemory()
        updateBattery()
        updateNetwork()
        updateLoadAverage()
        computeHealthScore()

        processCounter += 1
        if processCounter >= 4 {
            processCounter = 0
            updateTopProcessAsync()
        }

        onDisplayUpdate?()
    }

    private func primeCPU() {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        prevUser = Double(loadInfo.cpu_ticks.0)
        prevSystem = Double(loadInfo.cpu_ticks.1)
        prevIdle = Double(loadInfo.cpu_ticks.2)
        prevNice = Double(loadInfo.cpu_ticks.3)
        primedCPU = true
    }

    private func updateCPU() {
        if !primedCPU { primeCPU() }
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        let nice = Double(loadInfo.cpu_ticks.3)
        let dUser = user - prevUser
        let dSystem = system - prevSystem
        let dIdle = idle - prevIdle
        let dNice = nice - prevNice
        let dTotal = dUser + dSystem + dIdle + dNice

        prevUser = user
        prevSystem = system
        prevIdle = idle
        prevNice = nice
        guard dTotal > 0 else { return }

        cpuUsage = min(((dUser + dSystem + dNice) / dTotal) * 100, 100)
        append(cpuUsage, to: &cpuHistory)
    }

    private func updateMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let speculative = Double(stats.speculative_count) * pageSize
        let used = max(active + wired + compressed - speculative, 0)
        usedGB = used / 1_073_741_824
        if totalGB > 0 {
            ramUsage = min((usedGB / totalGB) * 100, 100)
        }
        append(ramUsage, to: &ramHistory)
    }

    private func updateBattery() {
        batteryLevel = -1
        isCharging = false
        isPluggedIn = false

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let maxCapacity = desc[kIOPSMaxCapacityKey as String] as? Int ?? 0
        if maxCapacity > 0 {
            batteryLevel = min(max(Int(Double(current) / Double(maxCapacity) * 100), 0), 100)
        }
        isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
        isPluggedIn = powerState == kIOPSACPowerValue
    }

    private func updateNetwork() {
        let now = Date()
        let bytes = Self.networkBytes()
        defer {
            lastBytesIn = bytes.in
            lastBytesOut = bytes.out
            lastNetworkTime = now
        }

        guard let lastTime = lastNetworkTime else { return }
        let elapsed = max(now.timeIntervalSince(lastTime), 0.1)
        downloadSpeed = bytes.in >= lastBytesIn ? Double(bytes.in - lastBytesIn) / elapsed : 0
        uploadSpeed = bytes.out >= lastBytesOut ? Double(bytes.out - lastBytesOut) / elapsed : 0
        append(downloadSpeed, to: &downHistory)
        append(uploadSpeed, to: &upHistory)
    }

    private func updateLoadAverage() {
        var avg: [Double] = [0, 0, 0]
        getloadavg(&avg, 3)
        loadAvg = (avg[0], avg[1], avg[2])
    }

    private func computeHealthScore() {
        var score = 100.0
        score -= max(cpuUsage - 65, 0) * 0.35
        score -= max(ramUsage - 70, 0) * 0.45
        if batteryLevel >= 0 && !isPluggedIn {
            score -= max(Double(25 - batteryLevel), 0) * 0.7
        }
        healthScore = Int(max(min(score, 100), 0).rounded())
    }

    private func updateTopProcessAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-Arco", "pcpu,comm"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run(); proc.waitUntilExit() } catch { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }
            var best: (name: String, cpu: Double)?
            for line in output.components(separatedBy: "\n").dropFirst() {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let cpu = Double(parts[0]) else { continue }
                let name = String(parts[1])
                if name == "kernel_task" || cpu < 0.1 { continue }
                if best == nil || cpu > best!.cpu { best = (name, cpu) }
            }
            let label = best.map { "\($0.name) \(String(format: "%.0f%%", $0.cpu))" } ?? "No process spike"
            DispatchQueue.main.async { self?.topProcess = label }
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        while history.count > config.historyLength { history.removeFirst() }
    }

    private static func networkBytes() -> (in: UInt64, out: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }
            guard let sa = addr.pointee.ifa_addr, sa.pointee.sa_family == 18 else { continue }
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            if let data = addr.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self)
                bytesIn += UInt64(networkData.pointee.ifi_ibytes)
                bytesOut += UInt64(networkData.pointee.ifi_obytes)
            }
        }
        return (bytesIn, bytesOut)
    }

    func render() -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: config.compactMode ? "SYS " : "HEALTH ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.textMuted
        ]))
        str.append(NSAttributedString(string: "\(healthScore)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: scoreColor
        ]))
        if !config.compactMode {
            str.append(NSAttributedString(string: " C\(Int(cpuUsage)) R\(Int(ramUsage))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: Theme.textFaint
            ]))
        }
        return .attributedText(str)
    }

    private var scoreColor: NSColor {
        if healthScore >= 80 { return Theme.green }
        if healthScore >= 55 { return Theme.orange }
        return Theme.red
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "SYSTEM HEALTH", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

extension SystemHealthWidget: InteractiveDropdown {
    var dropdownSize: NSSize { NSSize(width: 360, height: 560) }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 360
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildScoreCard(in: container, y: y, pad: pad, cw: cw)
        y = buildHistory(in: container, y: y, pad: pad, cw: cw)
        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let title = NSTextField(labelWithString: "System Health")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 180, height: 20)
        container.addSubview(title)

        let badge = NSTextField(labelWithString: healthScore >= 80 ? "NORMAL" : healthScore >= 55 ? "BUSY" : "HOT")
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = scoreColor
        badge.alignment = .right
        badge.frame = NSRect(x: pad + cw - 90, y: y - 18, width: 90, height: 16)
        container.addSubview(badge)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildScoreCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 118
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let ring = SparklineRenderer.renderRing(percentage: Double(healthScore), size: 82, color: scoreColor, lineWidth: 7)
        let ringView = NSImageView(frame: NSRect(x: 14, y: 18, width: 82, height: 82))
        ringView.image = ring
        card.addSubview(ringView)

        let score = NSTextField(labelWithString: "\(healthScore)")
        score.font = .monospacedDigitSystemFont(ofSize: 24, weight: .heavy)
        score.textColor = scoreColor
        score.alignment = .center
        score.frame = NSRect(x: 14, y: 48, width: 82, height: 28)
        card.addSubview(score)

        let sx: CGFloat = 112
        let sw = cw - sx - 12
        let rows: [(String, Double, NSColor)] = [
            ("CPU", cpuUsage, CPUWidget.dynamicColor(cpuUsage, threshold: 80)),
            ("RAM", ramUsage, percentColor(ramUsage, warning: 70, danger: 88)),
            ("Battery", batteryLevel >= 0 ? Double(batteryLevel) : 100, batteryLevel >= 0 ? BatteryWidget.dynamicLevelColor(batteryLevel, alertBelow: 20) : Theme.textMuted),
            ("Load", min(loadAvg.0 * 15, 100), Theme.textSecondary)
        ]
        var sy = cardH - 20
        for (label, value, color) in rows {
            addMeter(in: card, label: label, value: value, color: color, x: sx, y: sy, w: sw)
            sy -= 24
        }

        y -= cardH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildHistory(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let header = Theme.sectionHeader("LIVE HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let chartH: CGFloat = 64
        let chart = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chart)

        if cpuHistory.count >= 2 {
            let img = SparklineRenderer.render(data: Array(cpuHistory.suffix(70)), width: cw, style: .init(
                lineColor: Theme.brandCyan,
                fillColor: Theme.brandCyan.withAlphaComponent(0.08),
                lineWidth: 1.5,
                height: chartH,
                pointRadius: 0
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img
            chart.addSubview(iv)
        }
        if ramHistory.count >= 2 {
            let img = SparklineRenderer.render(data: Array(ramHistory.suffix(70)), width: cw, style: .init(
                lineColor: Theme.orange.withAlphaComponent(0.75),
                fillColor: nil,
                lineWidth: 1.2,
                height: chartH,
                pointRadius: 0
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img
            chart.addSubview(iv)
        }

        y -= chartH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let batteryText = batteryLevel >= 0 ? "\(batteryLevel)%" : "N/A"
        let netText = "\(formatSpeed(downloadSpeed)) down / \(formatSpeed(uploadSpeed)) up"
        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            title: "SYSTEM TERMINAL",
            metrics: [
                SuperWidgetMetric(label: "Score", value: "\(healthScore)", color: scoreColor),
                SuperWidgetMetric(label: "CPU", value: "\(Int(cpuUsage))%", color: CPUWidget.dynamicColor(cpuUsage, threshold: 80)),
                SuperWidgetMetric(label: "RAM", value: "\(Int(ramUsage))%", color: percentColor(ramUsage, warning: 70, danger: 88)),
                SuperWidgetMetric(label: "Battery", value: batteryText, color: batteryLevel >= 0 ? BatteryWidget.dynamicLevelColor(batteryLevel, alertBelow: 20) : Theme.textMuted)
            ],
            insights: [
                "Top: \(topProcess)",
                String(format: "Memory %.1f/%.0f GB", usedGB, totalGB),
                netText
            ],
            actions: [
                "Load \(String(format: "%.2f", loadAvg.0))",
                "Uptime \(uptimeString)",
                "Refresh \(Int(config.refreshRate))s"
            ],
            accent: scoreColor
        )
    }

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let footer = NSTextField(labelWithString: "Unified replacement for niche hardware widgets")
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost
        footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 18, width: cw, height: 14)
        container.addSubview(footer)
        return y - 20
    }

    private var uptimeString: String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.1fMB/s", bytesPerSecond / 1_048_576) }
        if bytesPerSecond >= 1024 { return String(format: "%.0fKB/s", bytesPerSecond / 1024) }
        return String(format: "%.0fB/s", bytesPerSecond)
    }

    private func percentColor(_ pct: Double, warning: Double, danger: Double) -> NSColor {
        if pct >= danger { return Theme.red }
        if pct >= warning { return Theme.orange }
        return Theme.green
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

    private func addMeter(in parent: NSView, label: String, value: Double, color: NSColor, x: CGFloat, y: CGFloat, w: CGFloat) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 10, weight: .semibold)
        labelView.textColor = Theme.textMuted
        labelView.frame = NSRect(x: x, y: y - 12, width: 56, height: 12)
        parent.addSubview(labelView)

        let barX = x + 58
        let barW = w - 98
        let bg = NSView(frame: NSRect(x: barX, y: y - 9, width: barW, height: 6))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Theme.sunkenBg.cgColor
        bg.layer?.cornerRadius = 3
        parent.addSubview(bg)

        let fillW = barW * CGFloat(max(min(value, 100), 0) / 100)
        let fill = NSView(frame: NSRect(x: barX, y: y - 9, width: fillW, height: 6))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = 3
        parent.addSubview(fill)

        let val = NSTextField(labelWithString: "\(Int(value))%")
        val.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        val.textColor = color
        val.alignment = .right
        val.frame = NSRect(x: x + w - 36, y: y - 12, width: 36, height: 12)
        parent.addSubview(val)
    }
}

extension SystemHealthWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .toggle(label: "Compact Menu Bar", key: "compactMode",
                    get: { [weak self] in self?.config.compactMode ?? false },
                    set: { [weak self] in self?.config.compactMode = $0 }),
            .toggle(label: "Track Network", key: "showNetwork",
                    get: { [weak self] in self?.config.showNetwork ?? true },
                    set: { [weak self] in self?.config.showNetwork = $0 }),
            .toggle(label: "Track Battery", key: "showBattery",
                    get: { [weak self] in self?.config.showBattery ?? true },
                    set: { [weak self] in self?.config.showBattery = $0 }),
            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 10, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 1 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "History Length", key: "historyLength", min: 30, max: 180, step: 10,
                    get: { [weak self] in Double(self?.config.historyLength ?? 90) },
                    set: { [weak self] in self?.config.historyLength = Int($0) },
                    format: "%.0f pts")
        ]
    }
}
