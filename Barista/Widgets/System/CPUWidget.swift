import Cocoa

struct CPUConfig: Codable, Equatable {
    var showPercentage: Bool
    var showBar: Bool
    var alertThreshold: Double
    var refreshRate: TimeInterval

    static let `default` = CPUConfig(
        showPercentage: true,
        showBar: true,
        alertThreshold: 80,
        refreshRate: 3
    )
}

class CPUWidget: BaristaWidget {
    static let widgetID = "cpu-monitor"
    static let displayName = "CPU Monitor"
    static let subtitle = "Live CPU usage percentage"
    static let iconName = "cpu"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CPUConfig.default

    var config: CPUConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var cpuUsage: Double = 0
    private(set) var history: [Double] = []
    private let maxHistory = 20
    private var prevUser: Double = 0
    private var prevSystem: Double = 0
    private var prevIdle: Double = 0
    private var prevNice: Double = 0

    required init(config: CPUConfig) {
        self.config = config
    }

    func start() {
        updateCPU()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateCPU()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateCPU() {
        cpuUsage = getCPUUsage()
        history.append(cpuUsage)
        if history.count > maxHistory { history.removeFirst() }
        onDisplayUpdate?()
    }

    private func getCPUUsage() -> Double {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        let nice = Double(loadInfo.cpu_ticks.3)

        // Compute delta from previous reading for current usage
        let dUser = user - prevUser
        let dSystem = system - prevSystem
        let dIdle = idle - prevIdle
        let dNice = nice - prevNice
        let dTotal = dUser + dSystem + dIdle + dNice

        prevUser = user
        prevSystem = system
        prevIdle = idle
        prevNice = nice

        guard dTotal > 0 else { return 0 }
        return ((dUser + dSystem + dNice) / dTotal) * 100
    }

    func render() -> WidgetDisplayMode {
        let pct = Int(cpuUsage)
        var parts: [String] = ["CPU"]

        if config.showBar {
            let filled = Int(cpuUsage / 10)
            let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
            parts.append(bar)
        }

        if config.showPercentage {
            parts.append("\(pct)%")
        }

        let text = parts.joined(separator: " ")

        if cpuUsage >= config.alertThreshold {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            ])
            return .attributedText(attr)
        }

        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "CPU MONITOR", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let usageItem = NSMenuItem(title: String(format: "Usage: %.1f%%", cpuUsage), action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        menu.addItem(usageItem)

        let coreCount = ProcessInfo.processInfo.processorCount
        let activeCount = ProcessInfo.processInfo.activeProcessorCount
        let coresItem = NSMenuItem(title: "Cores: \(activeCount)/\(coreCount)", action: nil, keyEquivalent: "")
        coresItem.isEnabled = false
        menu.addItem(coresItem)

        if !history.isEmpty {
            let avg = history.reduce(0, +) / Double(history.count)
            let peak = history.max() ?? 0
            menu.addItem(NSMenuItem.separator())
            let avgItem = NSMenuItem(title: String(format: "Avg: %.1f%%", avg), action: nil, keyEquivalent: "")
            avgItem.isEnabled = false
            menu.addItem(avgItem)
            let peakItem = NSMenuItem(title: String(format: "Peak: %.1f%%", peak), action: nil, keyEquivalent: "")
            peakItem.isEnabled = false
            menu.addItem(peakItem)

            // Sparkline
            let sparkline = history.suffix(10).map { v -> String in
                let blocks = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
                let idx = min(Int(v / 100 * 7), 7)
                return blocks[idx]
            }.joined()
            let sparkItem = NSMenuItem(title: "History: \(sparkline)", action: nil, keyEquivalent: "")
            sparkItem.isEnabled = false
            menu.addItem(sparkItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
