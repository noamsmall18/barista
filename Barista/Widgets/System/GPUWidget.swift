import Cocoa
import IOKit

struct GPUConfig: Codable, Equatable {
    var showPercentage: Bool
    var showTemperature: Bool
    var showMemory: Bool
    var alertThreshold: Double
    var refreshRate: TimeInterval

    static let `default` = GPUConfig(
        showPercentage: true,
        showTemperature: false,
        showMemory: false,
        alertThreshold: 90,
        refreshRate: 3
    )
}

class GPUWidget: BaristaWidget, InteractiveDropdown {
    static let widgetID = "gpu-monitor"
    static let displayName = "GPU Monitor"
    static let subtitle = "GPU utilization, temperature & VRAM"
    static let iconName = "gpu"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = GPUConfig.default

    var config: GPUConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var gpuUsage: Double = 0
    private(set) var gpuTemp: Double = 0
    private(set) var gpuName: String = "GPU"
    private(set) var vramUsed: Double = 0  // GB
    private(set) var vramTotal: Double = 0  // GB
    private(set) var history: [Double] = []
    private let maxHistory = 60

    required init(config: GPUConfig) {
        self.config = config
        detectGPUName()
    }

    func start() {
        updateGPU()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateGPU()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - GPU Data Collection

    private func detectGPUName() {
        // Use IOKit to find GPU name
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = getProperties(service) {
                if let model = props["model"] as? Data {
                    gpuName = String(data: model, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "GPU"
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        // Simplify common names
        if gpuName.contains("Apple") {
            // "Apple M1 Pro" -> "M1 Pro GPU"
            let parts = gpuName.replacingOccurrences(of: "Apple ", with: "")
            gpuName = "\(parts) GPU"
        }
    }

    private func getProperties(_ service: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    private func updateGPU() {
        // Read GPU utilization from IOKit IOAccelerator
        gpuUsage = readGPUUtilization()
        gpuTemp = SMCReader.shared.gpuTemperature() ?? 0
        readVRAM()

        history.append(gpuUsage)
        if history.count > maxHistory { history.removeFirst() }

        onDisplayUpdate?()
    }

    private func readGPUUtilization() -> Double {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return 0 }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = getProperties(service) {
                // Apple Silicon uses "Device Utilization %" or "GPU Activity(%)"
                if let utilization = props["Device Utilization %"] as? NSNumber {
                    IOObjectRelease(service)
                    return utilization.doubleValue
                }
                if let stats = props["PerformanceStatistics"] as? [String: Any] {
                    if let util = stats["Device Utilization %"] as? NSNumber {
                        IOObjectRelease(service)
                        return util.doubleValue
                    }
                    if let util = stats["GPU Activity(%)"] as? NSNumber {
                        IOObjectRelease(service)
                        return util.doubleValue
                    }
                    // Try calculating from busy/idle
                    if let busy = stats["GPU Core Utilization"] as? NSNumber {
                        IOObjectRelease(service)
                        return busy.doubleValue
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return 0
    }

    private func readVRAM() {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = getProperties(service) {
                if let stats = props["PerformanceStatistics"] as? [String: Any] {
                    if let used = stats["vramUsedBytes"] as? NSNumber {
                        vramUsed = used.doubleValue / 1_073_741_824
                    }
                    if let total = stats["vramFreeBytes"] as? NSNumber {
                        vramTotal = vramUsed + total.doubleValue / 1_073_741_824
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        // Apple Silicon shares system memory - estimate from total
        if vramTotal == 0 {
            vramTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        var parts: [String] = ["GPU"]

        if config.showPercentage {
            parts.append("\(Int(gpuUsage))%")
        }

        if config.showTemperature && gpuTemp > 0 {
            parts.append(String(format: "%.0f\u{00B0}", gpuTemp))
        }

        if config.showMemory && vramUsed > 0 {
            parts.append(String(format: "%.1fGB", vramUsed))
        }

        let text = parts.joined(separator: " ")

        if gpuUsage >= config.alertThreshold {
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            ])
            return .attributedText(attr)
        }

        return .text(text)
    }

    // MARK: - Dropdown Menu

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "GPU MONITOR", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let nameItem = NSMenuItem(title: gpuName, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        let usageItem = NSMenuItem(title: String(format: "Utilization: %.0f%%", gpuUsage), action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        menu.addItem(usageItem)

        if gpuTemp > 0 {
            let tempItem = NSMenuItem(title: String(format: "Temperature: %.0f\u{00B0}C", gpuTemp), action: nil, keyEquivalent: "")
            tempItem.isEnabled = false
            menu.addItem(tempItem)
        }

        if vramUsed > 0 {
            let vramItem = NSMenuItem(title: String(format: "VRAM: %.1f / %.0f GB", vramUsed, vramTotal), action: nil, keyEquivalent: "")
            vramItem.isEnabled = false
            menu.addItem(vramItem)
        }

        if history.count >= 2 {
            menu.addItem(NSMenuItem.separator())
            let avg = history.reduce(0, +) / Double(history.count)
            let peak = history.max() ?? 0
            let avgItem = NSMenuItem(title: String(format: "Avg: %.0f%%", avg), action: nil, keyEquivalent: "")
            avgItem.isEnabled = false
            menu.addItem(avgItem)
            let peakItem = NSMenuItem(title: String(format: "Peak: %.0f%%", peak), action: nil, keyEquivalent: "")
            peakItem.isEnabled = false
            menu.addItem(peakItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Interactive Dropdown (Sparkline)

    func buildDropdownPopover() -> NSView {
        let width: CGFloat = 320
        let height: CGFloat = 200
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        let padding: CGFloat = 16
        var y = height - padding

        // Title
        let title = NSTextField(labelWithString: gpuName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: padding, y: y - 18, width: width - padding * 2, height: 18)
        container.addSubview(title)
        y -= 30

        // Stats row
        let statsText = String(format: "Utilization: %.0f%%", gpuUsage)
            + (gpuTemp > 0 ? String(format: "  |  Temp: %.0f\u{00B0}C", gpuTemp) : "")
        let stats = NSTextField(labelWithString: statsText)
        stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stats.textColor = Theme.textSecondary
        stats.frame = NSRect(x: padding, y: y - 16, width: width - padding * 2, height: 16)
        container.addSubview(stats)
        y -= 28

        // Sparkline
        if history.count >= 2 {
            let sparkWidth = width - padding * 2
            let sparkHeight: CGFloat = 80
            let sparkImg = SparklineRenderer.render(
                data: history,
                width: sparkWidth,
                style: SparklineRenderer.Style(
                    lineColor: Theme.brandCyan,
                    fillColor: Theme.brandCyan.withAlphaComponent(0.1),
                    lineWidth: 1.5,
                    height: sparkHeight,
                    pointRadius: 2.5
                )
            )
            let imgView = NSImageView(frame: NSRect(x: padding, y: y - sparkHeight, width: sparkWidth, height: sparkHeight))
            imgView.image = sparkImg
            imgView.imageScaling = .scaleNone
            container.addSubview(imgView)
            y -= sparkHeight + 8

            // Min/Max labels
            let minMax = String(format: "Min: %.0f%%  Max: %.0f%%  Avg: %.0f%%",
                                history.min() ?? 0, history.max() ?? 0,
                                history.reduce(0, +) / Double(history.count))
            let mmLabel = NSTextField(labelWithString: minMax)
            mmLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            mmLabel.textColor = Theme.textMuted
            mmLabel.frame = NSRect(x: padding, y: y - 14, width: width - padding * 2, height: 14)
            container.addSubview(mmLabel)
        }

        return container
    }

    var dropdownSize: NSSize { NSSize(width: 320, height: 200) }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
