import Cocoa

struct RAMConfig: Codable, Equatable {
    var showAbsolute: Bool
    var showBar: Bool
    var alertThreshold: Double
    var refreshRate: TimeInterval

    static let `default` = RAMConfig(
        showAbsolute: false,
        showBar: false,
        alertThreshold: 85,
        refreshRate: 5
    )
}

class RAMWidget: BaristaWidget {
    static let widgetID = "ram-monitor"
    static let displayName = "RAM Monitor"
    static let subtitle = "Memory usage and pressure"
    static let iconName = "memorychip"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = RAMConfig.default

    var config: RAMConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var usedGB: Double = 0
    private(set) var totalGB: Double = 0
    private(set) var percentage: Double = 0

    required init(config: RAMConfig) {
        self.config = config
        totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    func start() {
        updateRAM()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateRAM()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateRAM() {
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

        let used = active + wired + compressed - speculative
        usedGB = used / 1_073_741_824
        percentage = (usedGB / totalGB) * 100
        onDisplayUpdate?()
    }

    func render() -> WidgetDisplayMode {
        if config.showAbsolute {
            let text = String(format: "RAM %.1f/%.0fGB", usedGB, totalGB)
            return coloredText(text)
        } else {
            var text = String(format: "RAM %d%%", Int(percentage))
            if config.showBar {
                let filled = Int(percentage / 10)
                let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
                text = "RAM \(bar) \(Int(percentage))%"
            }
            return coloredText(text)
        }
    }

    private func coloredText(_ text: String) -> WidgetDisplayMode {
        if percentage >= config.alertThreshold {
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

        let header = NSMenuItem(title: "MEMORY", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let items: [(String, String)] = [
            ("Used", String(format: "%.1f GB", usedGB)),
            ("Total", String(format: "%.0f GB", totalGB)),
            ("Free", String(format: "%.1f GB", totalGB - usedGB)),
            ("Usage", String(format: "%.1f%%", percentage)),
        ]

        for (label, value) in items {
            let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
