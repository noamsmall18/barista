import Cocoa

// MARK: - Config

struct CPUConfig: Codable, Equatable {
    var displayMode: CPUDisplayMode
    var showTemperature: Bool
    var showLoadAvg: Bool
    var showGPUTemp: Bool
    var tempUnit: TempUnit
    var alertThreshold: Double
    var refreshRate: TimeInterval
    var historyLength: Int
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var showCoresInDropdown: Bool
    var showProcesses: Bool
    var processCount: Int

    static let `default` = CPUConfig(
        displayMode: .sparkline,
        showTemperature: true,
        showLoadAvg: false,
        showGPUTemp: false,
        tempUnit: .celsius,
        alertThreshold: 80,
        refreshRate: 1,
        historyLength: 60,
        accentColor: .blue,
        colorMode: .dynamic,
        showCoresInDropdown: true,
        showProcesses: true,
        processCount: 5
    )

    enum CPUDisplayMode: String, Codable, Equatable {
        case text
        case sparkline
        case ring
        case compact
        case barGraph
    }

    enum TempUnit: String, Codable, Equatable {
        case celsius
        case fahrenheit
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
        case dynamic // color shifts blue->green->orange->red with usage
        case fixed   // always uses accentColor
    }
}

// MARK: - Widget

class CPUWidget: BaristaWidget {
    static let widgetID = "cpu-monitor"
    static let displayName = "CPU Monitor"
    static let subtitle = "Live CPU, temp, cores & processes"
    static let iconName = "cpu"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CPUConfig.default

    var config: CPUConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    // Aggregate
    private var timer: Timer?
    private(set) var cpuUsage: Double = 0
    private(set) var userUsage: Double = 0
    private(set) var systemUsage: Double = 0
    private(set) var idleUsage: Double = 0
    private(set) var history: [Double] = []
    private(set) var userHistory: [Double] = []
    private(set) var sysHistory: [Double] = []

    // Per-core
    private(set) var coreUsages: [Double] = []
    private var prevCoreTicks: [(user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)] = []

    // Temps & system
    private(set) var cpuTemp: Double?
    private(set) var gpuTemp: Double?
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var loadAvg: (Double, Double, Double) = (0, 0, 0)

    // Processes
    private(set) var topProcesses: [(name: String, pid: Int32, cpu: Double)] = []
    private var processCounter = 0

    // Aggregate ticks
    private var prevUser: Double = 0
    private var prevSystem: Double = 0
    private var prevIdle: Double = 0
    private var prevNice: Double = 0
    private var hasPrimedAggregate = false
    private var hasPrimedCores = false
    private var currentTimerInterval: TimeInterval = 0

    // Chip info (cached)
    private lazy var chipName: String = Self.readChipName()
    private lazy var coreCountStr: String = {
        let total = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount
        return total == active ? "\(total) cores" : "\(active)/\(total) cores"
    }()

    required init(config: CPUConfig) {
        self.config = config
    }

    func start() {
        let rate = config.refreshRate
        currentTimerInterval = rate

        if hasPrimedAggregate {
            // Already primed (e.g. restart from config change) - start immediately
            updateAll()
            timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
                self?.updateAll()
            }
        } else {
            // First launch: prime readings, wait briefly, then start
            primeAggregateCPU()
            primePerCoreCPU()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.updateAll()
                self.timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
                    self?.updateAll()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Priming (accurate first read)

    /// Take an initial snapshot of aggregate ticks so the first real delta is accurate.
    private func primeAggregateCPU() {
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
        hasPrimedAggregate = true
    }

    /// Take an initial snapshot of per-core ticks.
    private func primePerCoreCPU() {
        var cpuInfoPtr: processor_info_array_t?
        var numCPUsOut: natural_t = 0
        var numCPUInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsOut, &cpuInfoPtr, &numCPUInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfoPtr else { return }
        let numCPUs = Int(numCPUsOut)

        var ticks: [(user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)] = []
        for i in 0..<numCPUs {
            let base = Int(CPU_STATE_MAX) * i
            ticks.append((
                UInt64(cpuInfo[base + Int(CPU_STATE_USER)]),
                UInt64(cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                UInt64(cpuInfo[base + Int(CPU_STATE_IDLE)]),
                UInt64(cpuInfo[base + Int(CPU_STATE_NICE)])
            ))
        }
        prevCoreTicks = ticks
        coreUsages = Array(repeating: 0, count: numCPUs)
        hasPrimedCores = true

        let size = Int(numCPUInfo) * MemoryLayout<integer_t>.stride
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(size))
    }

    // MARK: - Data Collection

    private func updateAll() {
        // Self-correct timer if refresh rate was changed via config slider
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.updateAll()
            }
        }

        updateAggregateCPU()
        updatePerCoreCPU()
        updateTemps()
        updateLoadAvg()
        thermalState = ProcessInfo.processInfo.thermalState

        // Always fetch processes (user might toggle showProcesses on at any time)
        processCounter += 1
        if processCounter >= 3 {
            processCounter = 0
            updateTopProcessesAsync()
        }
        onDisplayUpdate?()
    }

    private func updateAggregateCPU() {
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

        prevUser = user; prevSystem = system; prevIdle = idle; prevNice = nice
        guard dTotal > 0 else { return }

        userUsage = ((dUser + dNice) / dTotal) * 100
        systemUsage = (dSystem / dTotal) * 100
        idleUsage = (dIdle / dTotal) * 100
        cpuUsage = min(userUsage + systemUsage, 100)

        history.append(cpuUsage)
        userHistory.append(userUsage)
        sysHistory.append(systemUsage)
        while history.count > config.historyLength { history.removeFirst() }
        while userHistory.count > config.historyLength { userHistory.removeFirst() }
        while sysHistory.count > config.historyLength { sysHistory.removeFirst() }
    }

    private func updatePerCoreCPU() {
        var cpuInfoPtr: processor_info_array_t?
        var numCPUsOut: natural_t = 0
        var numCPUInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsOut, &cpuInfoPtr, &numCPUInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfoPtr else { return }
        let numCPUs = Int(numCPUsOut)

        var newUsages: [Double] = []
        var newTicks: [(user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)] = []

        for i in 0..<numCPUs {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(cpuInfo[base + Int(CPU_STATE_USER)])
            let sys = UInt64(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(cpuInfo[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(cpuInfo[base + Int(CPU_STATE_NICE)])
            newTicks.append((user, sys, idle, nice))

            if i < prevCoreTicks.count {
                let prev = prevCoreTicks[i]
                let du = user &- prev.user
                let ds = sys &- prev.sys
                let di = idle &- prev.idle
                let dn = nice &- prev.nice
                let total = du + ds + di + dn
                let usage = total > 0 ? min(Double(du + ds + dn) / Double(total) * 100, 100) : 0
                newUsages.append(usage)
            } else {
                newUsages.append(0)
            }
        }
        prevCoreTicks = newTicks
        coreUsages = newUsages

        let size = Int(numCPUInfo) * MemoryLayout<integer_t>.stride
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(size))
    }

    private func updateTemps() {
        cpuTemp = SMCReader.shared.cpuTemperature()
        gpuTemp = SMCReader.shared.gpuTemperature()
    }

    private func updateLoadAvg() {
        var avg: [Double] = [0, 0, 0]
        getloadavg(&avg, 3)
        loadAvg = (avg[0], avg[1], avg[2])
    }

    /// Run ps asynchronously to avoid blocking the main thread.
    private func updateTopProcessesAsync() {
        let maxProcs = config.processCount
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-Arco", "pid,pcpu,comm"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run(); proc.waitUntilExit() } catch { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            var results: [(name: String, pid: Int32, cpu: Double)] = []
            for line in output.components(separatedBy: "\n").dropFirst().prefix(maxProcs + 5) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.split(separator: " ", maxSplits: 2)
                guard parts.count >= 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { continue }
                let name = String(parts[2])
                if name == "kernel_task" || name == "idle" || cpu < 0.1 { continue }
                results.append((name: name, pid: pid, cpu: cpu))
            }
            let top = Array(results.prefix(maxProcs))
            DispatchQueue.main.async { [weak self] in
                self?.topProcesses = top
            }
        }
    }

    // MARK: - Temperature Formatting

    func formatTemp(_ celsius: Double) -> String {
        switch config.tempUnit {
        case .celsius:
            return "\(Int(celsius))\u{00B0}C"
        case .fahrenheit:
            let f = celsius * 9.0 / 5.0 + 32.0
            return "\(Int(f))\u{00B0}F"
        }
    }

    func formatTempShort(_ celsius: Double) -> String {
        switch config.tempUnit {
        case .celsius:
            return "\(Int(celsius))\u{00B0}"
        case .fahrenheit:
            let f = celsius * 9.0 / 5.0 + 32.0
            return "\(Int(f))\u{00B0}"
        }
    }

    // MARK: - Color for current state

    /// Returns the accent color based on current config and usage.
    func accentForUsage(_ pct: Double) -> NSColor {
        switch config.colorMode {
        case .fixed:
            return config.accentColor.color
        case .dynamic:
            return Self.dynamicColor(pct, threshold: config.alertThreshold)
        }
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        let pct = Int(cpuUsage)
        let color = accentForUsage(cpuUsage)

        switch config.displayMode {
        case .compact:
            return renderAttributed(pct: pct, color: color, showLabel: false)

        case .text:
            return renderAttributed(pct: pct, color: color, showLabel: true)

        case .sparkline:
            let sparkData = Array(history.suffix(20))
            guard sparkData.count >= 2 else { return renderAttributed(pct: pct, color: color, showLabel: true) }
            var label = "\(pct)%"
            if config.showTemperature, let t = cpuTemp { label += " \(formatTempShort(t))" }
            if config.showLoadAvg { label += " \(String(format: "%.1f", loadAvg.0))" }
            return .sparkline(sparkData, label: label, width: 100)

        case .ring:
            let ringImg = renderGradientRing(pct: cpuUsage, size: 18, lineWidth: 2.5)
            var label = "\(pct)%"
            if config.showTemperature, let t = cpuTemp { label += " \(formatTempShort(t))" }
            return .iconAndText(ringImg, label)

        case .barGraph:
            let barImg = renderMenuBarCores(width: 36, height: 16)
            var label = " \(pct)%"
            if config.showTemperature, let t = cpuTemp { label += " \(formatTempShort(t))" }
            return .iconAndText(barImg, label)
        }
    }

    private func renderAttributed(pct: Int, color: NSColor, showLabel: Bool) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        if showLabel {
            str.append(NSAttributedString(string: "CPU ", attributes: [
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
                .foregroundColor: Self.colorForTemp(t).withAlphaComponent(0.7)
            ]))
        }
        if config.showLoadAvg {
            str.append(NSAttributedString(string: String(format: " %.1f", loadAvg.0), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
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

        let startAngle: CGFloat = 90
        let sweep = CGFloat(min(pct, 100) / 100.0 * 360.0)
        let endAngle = startAngle - sweep
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        accentForUsage(pct).setStroke()
        arc.stroke()

        img.unlockFocus()
        return img
    }

    private func renderMenuBarCores(width: CGFloat, height: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        guard !coreUsages.isEmpty else { return img }
        img.lockFocus()

        let count = coreUsages.count
        let gap: CGFloat = 1
        let barW = max((width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
        let pad: CGFloat = 1

        for (i, usage) in coreUsages.enumerated() {
            let x = CGFloat(i) * (barW + gap)
            let norm = min(usage / 100.0, 1.0)
            let barH = max(pad + CGFloat(norm) * (height - pad * 2), 1)
            let rect = NSRect(x: x, y: 0, width: barW, height: barH)
            accentForUsage(usage).withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barW / 3, yRadius: barW / 3).fill()
        }

        img.unlockFocus()
        return img
    }

    // MARK: - Dropdown (fallback NSMenu)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "CPU MONITOR", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())
        let u = NSMenuItem(title: String(format: "Usage: %.1f%%", cpuUsage), action: nil, keyEquivalent: "")
        u.isEnabled = false; menu.addItem(u)
        if let t = cpuTemp {
            let ti = NSMenuItem(title: "Temp: \(formatTemp(t))", action: nil, keyEquivalent: "")
            ti.isEnabled = false; menu.addItem(ti)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }

    // MARK: - Color Helpers

    /// Dynamic color: smooth gradient from blue(idle) -> green -> yellow -> orange -> red(alert)
    static func dynamicColor(_ pct: Double, threshold: Double) -> NSColor {
        let t = min(pct / 100.0, 1.0)
        if pct >= threshold {
            return NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1)
        } else if t < 0.15 {
            let f = CGFloat(t / 0.15)
            return NSColor(red: 0.20 + 0.10 * f, green: 0.65 + 0.20 * f, blue: 0.95 - 0.10 * f, alpha: 1)
        } else if t < 0.30 {
            let f = CGFloat((t - 0.15) / 0.15)
            return NSColor(red: 0.30 - 0.05 * f, green: 0.85, blue: 0.85 - 0.30 * f, alpha: 1)
        } else if t < 0.55 {
            let f = CGFloat((t - 0.30) / 0.25)
            return NSColor(red: 0.25 + 0.70 * f, green: 0.85 - 0.03 * f, blue: 0.55 - 0.25 * f, alpha: 1)
        } else if t < 0.70 {
            let f = CGFloat((t - 0.55) / 0.15)
            return NSColor(red: 0.95 + 0.05 * f, green: 0.82 - 0.22 * f, blue: 0.30 - 0.10 * f, alpha: 1)
        } else {
            let f = CGFloat((t - 0.70) / 0.30)
            return NSColor(red: 1.0, green: 0.60 - 0.38 * f, blue: 0.20 - 0.02 * f, alpha: 1)
        }
    }

    static func colorForTemp(_ temp: Double) -> NSColor {
        if temp >= 95 { return NSColor(red: 1.0, green: 0.20, blue: 0.20, alpha: 1) }
        if temp >= 80 { return NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1) }
        if temp >= 65 { return NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1) }
        if temp >= 45 { return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) }
        return NSColor(red: 0.30, green: 0.70, blue: 0.95, alpha: 1)
    }

    static func readChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
            let s = String(cString: buf)
            if !s.isEmpty { return s }
        }
        return "Apple Silicon"
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> (String, NSColor) {
        switch state {
        case .nominal:  return ("Normal", NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1))
        case .fair:     return ("Fair", NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1))
        case .serious:  return ("Serious", NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1))
        case .critical: return ("Critical", NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1))
        @unknown default: return ("Unknown", Theme.textMuted)
        }
    }
}

// MARK: - Interactive Dropdown

extension CPUWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 200 // header + gauge + info chips + footer
        if config.showCoresInDropdown && !coreUsages.isEmpty {
            let rows = coreUsages.count <= 8 ? 1 : 2
            h += CGFloat(rows) * 28 + 30
        }
        h += 62 // history chart
        if config.showProcesses {
            h += CGFloat(min(topProcesses.count, config.processCount)) * 22 + 30
        }
        h += SuperWidgetKit.panelHeight + 8
        h += 40 // footer + padding
        return NSSize(width: 340, height: min(max(h, 300), 760))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildGaugeCard(in: container, y: y, pad: pad, cw: cw)

        if config.showCoresInDropdown {
            y = buildCoreBars(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildHistory(in: container, y: y, pad: pad, cw: cw)

        if config.showProcesses {
            y = buildProcesses(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let tempText = cpuTemp.map { formatTemp($0) } ?? "N/A"
        let hottestCore = coreUsages.max() ?? cpuUsage
        let topProcess = topProcesses.first.map { "\($0.name) \(String(format: "%.0f%%", $0.cpu))" } ?? "No process spike"
        let trend = (history.last ?? cpuUsage) >= (history.dropLast().last ?? cpuUsage) ? "Load rising" : "Load easing"
        let (thermalText, thermalColor) = Self.thermalLabel(thermalState)

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Total", value: String(format: "%.1f%%", cpuUsage), color: accentForUsage(cpuUsage)),
                SuperWidgetMetric(label: "Hottest", value: String(format: "%.0f%%", hottestCore), color: accentForUsage(hottestCore)),
                SuperWidgetMetric(label: "Temp", value: tempText, color: cpuTemp.map(Self.colorForTemp) ?? Theme.textMuted),
                SuperWidgetMetric(label: "Load", value: String(format: "%.2f", loadAvg.0), color: Theme.brandCyan)
            ],
            insights: [
                trend,
                "Thermal \(thermalText)",
                "Top: \(topProcess)"
            ],
            actions: [
                "\(coreUsages.count) cores",
                "Refresh \(Int(config.refreshRate))s",
                "Threshold \(Int(config.alertThreshold))%"
            ],
            accent: thermalColor
        )
    }

    // MARK: - Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "CPU Monitor")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let sub = NSTextField(labelWithString: "\(chipName)  \u{00B7}  \(coreCountStr)")
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = Theme.textMuted
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: pad, y: y - 36, width: cw, height: 14)
        container.addSubview(sub)

        y -= 44
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Gauge Card

    private func buildGaugeCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 80
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Large gradient ring
        let ringSize: CGFloat = 58
        let ringImg = renderGradientRing(pct: cpuUsage, size: ringSize, lineWidth: 5)
        let ringView = NSImageView(frame: NSRect(x: 12, y: (cardH - ringSize) / 2, width: ringSize, height: ringSize))
        ringView.image = ringImg
        card.addSubview(ringView)

        // Percentage centered in ring
        let pctLabel = NSTextField(labelWithString: "\(Int(cpuUsage))%")
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .heavy)
        pctLabel.textColor = accentForUsage(cpuUsage)
        pctLabel.alignment = .center
        pctLabel.frame = NSRect(x: 12, y: (cardH - 22) / 2, width: ringSize, height: 22)
        card.addSubview(pctLabel)

        // Right side: stacked bar + stats
        let sx: CGFloat = ringSize + 24
        let sw = cw - sx - 8
        var sy = cardH - 14

        // User / System stacked bar
        let barH: CGFloat = 6
        let barBg = NSView(frame: NSRect(x: sx, y: sy - barH + 2, width: sw, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        barBg.layer?.cornerRadius = 3
        card.addSubview(barBg)

        let userW = sw * CGFloat(userUsage / 100.0)
        let sysW = sw * CGFloat(systemUsage / 100.0)

        if userW > 0 {
            let bar = NSView(frame: NSRect(x: sx, y: sy - barH + 2, width: userW, height: barH))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 0.8).cgColor
            bar.layer?.cornerRadius = 3
            card.addSubview(bar)
        }
        if sysW > 0 {
            let bar = NSView(frame: NSRect(x: sx + userW, y: sy - barH + 2, width: sysW, height: barH))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 0.8).cgColor
            card.addSubview(bar)
        }
        sy -= barH + 6

        let rows: [(String, String, NSColor)] = [
            ("User", String(format: "%.1f%%", userUsage), NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)),
            ("System", String(format: "%.1f%%", systemUsage), NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 1)),
            ("Idle", String(format: "%.1f%%", idleUsage), Theme.textFaint),
        ]
        for (label, value, color) in rows {
            addStatPair(in: card, label: label, value: value, color: color, x: sx, y: sy - 12, w: sw)
            sy -= 16
        }

        y -= cardH + 8

        // Info chips row: temps, thermal, load
        var infoCards: [(String, String, NSColor)] = []
        if let t = cpuTemp {
            infoCards.append((formatTemp(t), "CPU", Self.colorForTemp(t)))
        }
        if config.showGPUTemp, let t = gpuTemp {
            infoCards.append((formatTemp(t), "GPU", Self.colorForTemp(t)))
        }
        let (tLabel, tColor) = Self.thermalLabel(thermalState)
        infoCards.append((tLabel, "Thermal", tColor))
        infoCards.append((String(format: "%.2f", loadAvg.0), "Load 1m", Theme.textSecondary))

        let chipW = (cw - CGFloat(infoCards.count - 1) * 6) / CGFloat(infoCards.count)
        for (i, (val, label, color)) in infoCards.enumerated() {
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

    // MARK: - Per-Core Bars

    private func buildCoreBars(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard !coreUsages.isEmpty else { return y }
        var y = y

        let header = Theme.sectionHeader("PER-CORE UTILIZATION")
        header.frame = NSRect(x: pad, y: y - 12, width: 200, height: 12)
        container.addSubview(header)
        y -= 18

        let count = coreUsages.count
        let cols = count <= 8 ? count : (count + 1) / 2
        let rows = count <= 8 ? 1 : 2
        let gap: CGFloat = 3
        let barW = (cw - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let barH: CGFloat = 24

        for row in 0..<rows {
            let colsInRow = row == 0 ? cols : count - cols
            for col in 0..<colsInRow {
                let idx = row * cols + col
                guard idx < count else { break }
                let usage = coreUsages[idx]
                let x = pad + CGFloat(col) * (barW + gap)
                let by = y - barH - CGFloat(row) * (barH + 4)

                let bg = NSView(frame: NSRect(x: x, y: by, width: barW, height: barH))
                bg.wantsLayer = true
                bg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
                bg.layer?.cornerRadius = 4
                container.addSubview(bg)

                let fillH = max(CGFloat(min(usage / 100.0, 1.0)) * barH, 1)
                let fill = NSView(frame: NSRect(x: x, y: by, width: barW, height: fillH))
                fill.wantsLayer = true
                fill.layer?.backgroundColor = accentForUsage(usage).withAlphaComponent(0.45).cgColor
                fill.layer?.cornerRadius = 4
                container.addSubview(fill)

                let label = NSTextField(labelWithString: "\(idx)")
                label.font = .monospacedDigitSystemFont(ofSize: 7, weight: .medium)
                label.textColor = usage > 50 ? NSColor.white.withAlphaComponent(0.8) : Theme.textFaint
                label.alignment = .center
                label.frame = NSRect(x: x, y: by + 1, width: barW, height: 10)
                container.addSubview(label)
            }
        }

        y -= (barH + 4) * CGFloat(rows) + 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - History Chart

    private func buildHistory(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("HISTORY")
        header.frame = NSRect(x: pad, y: y - 12, width: 80, height: 12)
        container.addSubview(header)

        if !history.isEmpty {
            let avg = history.reduce(0, +) / Double(history.count)
            let peak = history.max() ?? 0
            let low = history.min() ?? 0
            let info = String(format: "avg %.0f%%  lo %.0f%%  hi %.0f%%", avg, low, peak)
            let il = NSTextField(labelWithString: info)
            il.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            il.textColor = Theme.textFaint; il.alignment = .right
            il.frame = NSRect(x: pad + 80, y: y - 12, width: cw - 80, height: 12)
            container.addSubview(il)
        }
        y -= 18

        let chartH: CGFloat = 44
        let chartData = Array(history.suffix(50))
        let chartBg = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        // Threshold line
        if config.alertThreshold < 100 {
            let threshY = CGFloat(config.alertThreshold / 100.0) * (chartH - 4) + 2
            let threshLine = NSView(frame: NSRect(x: 0, y: threshY, width: cw, height: 1))
            threshLine.wantsLayer = true
            threshLine.layer?.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 0.25).cgColor
            chartBg.addSubview(threshLine)
        }

        if chartData.count >= 2 {
            // System usage layer (orange)
            let sysData = Array(sysHistory.suffix(50))
            if sysData.count >= 2 {
                let sysImg = SparklineRenderer.render(data: sysData, width: cw, style: SparklineRenderer.Style(
                    lineColor: NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 0.5),
                    fillColor: NSColor(red: 1.0, green: 0.60, blue: 0.18, alpha: 0.08),
                    lineWidth: 1, height: chartH, pointRadius: 0
                ))
                let sv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
                sv.image = sysImg; sv.imageScaling = .scaleNone
                chartBg.addSubview(sv)
            }

            // Total usage line (accent color)
            let lineColor = accentForUsage(cpuUsage)
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
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Processes

    private func buildProcesses(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("TOP PROCESSES")
        header.frame = NSRect(x: pad, y: y - 12, width: 150, height: 12)
        container.addSubview(header)
        y -= 18

        let procs = Array(topProcesses.prefix(config.processCount))
        if procs.isEmpty {
            let lbl = NSTextField(labelWithString: "Collecting...")
            lbl.font = .systemFont(ofSize: 10, weight: .regular)
            lbl.textColor = Theme.textFaint
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

                let fillPct = min(proc.cpu / 100.0, 1.0)
                let fillW = cw * CGFloat(fillPct)
                if fillW > 0 {
                    let fill = NSView(frame: NSRect(x: pad, y: y - rowH, width: fillW, height: rowH))
                    fill.wantsLayer = true
                    fill.layer?.backgroundColor = accentForUsage(proc.cpu).withAlphaComponent(0.10).cgColor
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
                name.frame = NSRect(x: pad + 22, y: y - rowH + 3, width: cw - 80, height: 14)
                container.addSubview(name)

                let cpuLabel = NSTextField(labelWithString: String(format: "%.1f%%", proc.cpu))
                cpuLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
                cpuLabel.textColor = accentForUsage(proc.cpu)
                cpuLabel.alignment = .right
                cpuLabel.frame = NSRect(x: pad + cw - 52, y: y - rowH + 3, width: 46, height: 14)
                container.addSubview(cpuLabel)

                y -= rowH + 2
            }
        }
        return y
    }

    // MARK: - Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let mins = (Int(uptime) % 3600) / 60
        let uptimeStr = days > 0 ? "\(days)d \(hours)h \(mins)m" : hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"

        let loadStr = String(format: "%.2f / %.2f / %.2f", loadAvg.0, loadAvg.1, loadAvg.2)
        let footer = NSTextField(labelWithString: "Up \(uptimeStr)  \u{00B7}  Load \(loadStr)")
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

extension CPUWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Sparkline + %", value: "sparkline"),
                (title: "Ring Gauge + %", value: "ring"),
                (title: "Per-Core Bars", value: "barGraph"),
                (title: "CPU Text + %", value: "text"),
                (title: "Compact %", value: "compact"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "sparkline" },
               set: { [weak self] in self?.config.displayMode = CPUConfig.CPUDisplayMode(rawValue: $0) ?? .sparkline }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (shifts with usage)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = CPUConfig.ColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "blue" },
               set: { [weak self] in self?.config.accentColor = CPUConfig.AccentPreset(rawValue: $0) ?? .blue }),

            .section(title: "Temperature"),
            .toggle(label: "Show CPU Temperature", key: "showTemperature",
                    get: { [weak self] in self?.config.showTemperature ?? true },
                    set: { [weak self] in self?.config.showTemperature = $0 }),
            .toggle(label: "Show GPU Temperature", key: "showGPUTemp",
                    get: { [weak self] in self?.config.showGPUTemp ?? false },
                    set: { [weak self] in self?.config.showGPUTemp = $0 }),
            .picker(label: "Temperature Unit", key: "tempUnit", options: [
                (title: "Celsius (\u{00B0}C)", value: "celsius"),
                (title: "Fahrenheit (\u{00B0}F)", value: "fahrenheit"),
            ], get: { [weak self] in self?.config.tempUnit.rawValue ?? "celsius" },
               set: { [weak self] in self?.config.tempUnit = CPUConfig.TempUnit(rawValue: $0) ?? .celsius }),

            .section(title: "Menu Bar"),
            .toggle(label: "Show Load Average", key: "showLoadAvg",
                    get: { [weak self] in self?.config.showLoadAvg ?? false },
                    set: { [weak self] in self?.config.showLoadAvg = $0 }),
            .slider(label: "Alert Threshold", key: "alertThreshold", min: 50, max: 100, step: 5,
                    get: { [weak self] in self?.config.alertThreshold ?? 80 },
                    set: { [weak self] in self?.config.alertThreshold = $0 },
                    format: "%.0f%%"),

            .section(title: "Dropdown"),
            .toggle(label: "Show Per-Core Bars", key: "showCoresInDropdown",
                    get: { [weak self] in self?.config.showCoresInDropdown ?? true },
                    set: { [weak self] in self?.config.showCoresInDropdown = $0 }),
            .toggle(label: "Show Top Processes", key: "showProcesses",
                    get: { [weak self] in self?.config.showProcesses ?? true },
                    set: { [weak self] in self?.config.showProcesses = $0 }),
            .slider(label: "Process Count", key: "processCount", min: 3, max: 8, step: 1,
                    get: { [weak self] in Double(self?.config.processCount ?? 5) },
                    set: { [weak self] in self?.config.processCount = Int($0) },
                    format: "%.0f"),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 10, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 2 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "History Length", key: "historyLength", min: 20, max: 120, step: 10,
                    get: { [weak self] in Double(self?.config.historyLength ?? 60) },
                    set: { [weak self] in self?.config.historyLength = Int($0) },
                    format: "%.0f pts"),
        ]
    }
}
