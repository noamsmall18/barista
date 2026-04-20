import Cocoa
import IOKit.ps

struct BatteryConfig: Codable, Equatable {
    var showTimeRemaining: Bool
    var showHealth: Bool
    var showCycles: Bool
    var alertBelow: Int

    static let `default` = BatteryConfig(
        showTimeRemaining: true,
        showHealth: false,
        showCycles: false,
        alertBelow: 20
    )
}

class BatteryWidget: BaristaWidget {
    static let widgetID = "battery-health"
    static let displayName = "Battery Health"
    static let subtitle = "Battery level, health, and cycle count"
    static let iconName = "battery.100"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = BatteryConfig.default

    var config: BatteryConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 30 }

    private var timer: Timer?
    private(set) var level: Int = 0
    private(set) var isCharging: Bool = false
    private(set) var timeRemaining: Int = -1 // minutes, -1 = unknown
    private(set) var cycleCount: Int = 0
    private(set) var health: Int = 100
    private(set) var isPresent: Bool = false

    required init(config: BatteryConfig) {
        self.config = config
    }

    func start() {
        updateBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else {
            isPresent = false
            onDisplayUpdate?()
            return
        }

        isPresent = true
        level = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false

        if let time = desc[kIOPSTimeToEmptyKey] as? Int, time >= 0 {
            timeRemaining = time
        } else if let time = desc[kIOPSTimeToFullChargeKey] as? Int, time >= 0 {
            timeRemaining = time
        } else {
            timeRemaining = -1
        }

        // Try to get cycle count and health from IOKit
        readSMCBatteryInfo()

        onDisplayUpdate?()
    }

    private func readSMCBatteryInfo() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        if let cycleVal = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, nil, 0)?.takeRetainedValue() as? Int {
            cycleCount = cycleVal
        }
        if let maxCap = IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, nil, 0)?.takeRetainedValue() as? Int,
           let designCap = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, nil, 0)?.takeRetainedValue() as? Int,
           designCap > 0 {
            health = Int(Double(maxCap) / Double(designCap) * 100)
        }
    }

    func render() -> WidgetDisplayMode {
        if !isPresent {
            return .text("No Battery")
        }

        var parts: [String] = []

        let icon: String
        if isCharging {
            icon = "\u{26A1}"
        } else if level <= 10 {
            icon = "\u{1FAAB}"
        } else {
            icon = "\u{1F50B}"
        }

        parts.append("\(icon) \(level)%")

        if config.showTimeRemaining && timeRemaining > 0 {
            let h = timeRemaining / 60
            let m = timeRemaining % 60
            if h > 0 {
                parts.append("\(h):\(String(format: "%02d", m))")
            } else {
                parts.append("\(m)m")
            }
        }

        if config.showHealth {
            parts.append("H:\(health)%")
        }

        if config.showCycles {
            parts.append("C:\(cycleCount)")
        }

        let text = parts.joined(separator: " ")

        if level <= config.alertBelow && !isCharging {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
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

        let header = NSMenuItem(title: "BATTERY", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if !isPresent {
            let item = NSMenuItem(title: "No battery detected (desktop Mac?)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let items: [(String, String)] = [
                ("Level", "\(level)%"),
                ("Status", isCharging ? "Charging" : "On Battery"),
                ("Time", timeRemaining > 0 ? "\(timeRemaining / 60)h \(timeRemaining % 60)m \(isCharging ? "to full" : "remaining")" : "Calculating..."),
                ("Health", "\(health)%"),
                ("Cycles", "\(cycleCount)"),
            ]

            for (label, value) in items {
                let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            // Visual bar
            menu.addItem(NSMenuItem.separator())
            let filled = level / 10
            let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
            let barItem = NSMenuItem(title: "[\(bar)] \(level)%", action: nil, keyEquivalent: "")
            barItem.isEnabled = false
            menu.addItem(barItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
