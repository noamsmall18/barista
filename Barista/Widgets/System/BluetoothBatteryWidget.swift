import Cocoa
import IOKit

struct BluetoothBatteryConfig: Codable, Equatable {
    var showAllDevices: Bool
    var lowBatteryThreshold: Int
    var refreshRate: TimeInterval

    static let `default` = BluetoothBatteryConfig(
        showAllDevices: false,
        lowBatteryThreshold: 20,
        refreshRate: 60
    )
}

struct BTDevice {
    let name: String
    let batteryLevel: Int  // 0-100, -1 = unknown
    let isConnected: Bool
    let deviceType: BTDeviceType
}

enum BTDeviceType: String {
    case airpods = "AirPods"
    case mouse = "Mouse"
    case keyboard = "Keyboard"
    case trackpad = "Trackpad"
    case gamepad = "Gamepad"
    case headphones = "Headphones"
    case other = "Device"

    var icon: String {
        switch self {
        case .airpods: return "\u{1F3A7}"
        case .mouse: return "\u{1F5B1}"
        case .keyboard: return "\u{2328}\u{FE0F}"
        case .trackpad: return "\u{1F5B1}"
        case .gamepad: return "\u{1F3AE}"
        case .headphones: return "\u{1F3A7}"
        case .other: return "\u{1F517}"
        }
    }
}

class BluetoothBatteryWidget: BaristaWidget, Cycleable {
    static let widgetID = "bluetooth-battery"
    static let displayName = "Bluetooth Batteries"
    static let subtitle = "AirPods, mouse & keyboard battery levels"
    static let iconName = "battery.100.bolt"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = BluetoothBatteryConfig.default

    var config: BluetoothBatteryConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var devices: [BTDevice] = []
    private(set) var _currentIndex: Int = 0

    required init(config: BluetoothBatteryConfig) {
        self.config = config
    }

    func start() {
        updateDevices()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateDevices()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Cycleable

    var itemCount: Int { max(devices.count, 1) }
    var currentIndex: Int { _currentIndex }
    var cycleInterval: TimeInterval { 8 }

    func cycleNext() {
        guard !devices.isEmpty else { return }
        _currentIndex = (_currentIndex + 1) % devices.count
    }

    // MARK: - Device Detection

    private func updateDevices() {
        devices = scanBluetoothDevices()
        if _currentIndex >= devices.count { _currentIndex = 0 }
        onDisplayUpdate?()
    }

    private func scanBluetoothDevices() -> [BTDevice] {
        var result: [BTDevice] = []

        // Use IOKit to find Bluetooth HID devices with battery info
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return scanViaSystemProfiler()
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            // Look for battery percentage
            guard let battery = dict["BatteryPercent"] as? Int else { continue }

            let product = dict["Product"] as? String ?? "Unknown Device"
            let transport = dict["Transport"] as? String ?? ""

            // Only include Bluetooth devices
            guard transport.lowercased().contains("bluetooth") || transport.isEmpty else { continue }

            let deviceType = classifyDevice(name: product)
            result.append(BTDevice(
                name: product,
                batteryLevel: battery,
                isConnected: true,
                deviceType: deviceType
            ))
        }

        if result.isEmpty {
            return scanViaSystemProfiler()
        }

        return result.sorted { $0.name < $1.name }
    }

    /// Fallback: parse system_profiler for Bluetooth battery info
    private func scanViaSystemProfiler() -> [BTDevice] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btData = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var result: [BTDevice] = []

        for controller in btData {
            // Look for connected devices
            if let connectedDevices = controller["device_connected"] as? [[String: Any]] {
                for deviceDict in connectedDevices {
                    for (name, info) in deviceDict {
                        guard let infoDict = info as? [String: Any] else { continue }

                        var batteryLevel = -1

                        // Try various battery keys
                        if let battery = infoDict["device_batteryLevelMain"] as? String,
                           let pct = Int(battery.replacingOccurrences(of: "%", with: "")) {
                            batteryLevel = pct
                        } else if let battery = infoDict["device_batteryLevel"] as? String,
                                  let pct = Int(battery.replacingOccurrences(of: "%", with: "")) {
                            batteryLevel = pct
                        } else if let battery = infoDict["device_batteryPercent"] as? String,
                                  let pct = Int(battery.replacingOccurrences(of: "%", with: "")) {
                            batteryLevel = pct
                        }

                        guard batteryLevel >= 0 else { continue }

                        let deviceType = classifyDevice(name: name)
                        result.append(BTDevice(
                            name: name,
                            batteryLevel: batteryLevel,
                            isConnected: true,
                            deviceType: deviceType
                        ))
                    }
                }
            }
        }

        return result.sorted { $0.name < $1.name }
    }

    private func classifyDevice(name: String) -> BTDeviceType {
        let lower = name.lowercased()
        if lower.contains("airpod") { return .airpods }
        if lower.contains("mouse") || lower.contains("magic mouse") { return .mouse }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("gamepad") || lower.contains("controller") || lower.contains("dualsense") || lower.contains("xbox") { return .gamepad }
        if lower.contains("headphone") || lower.contains("beats") || lower.contains("bose") || lower.contains("sony wh") || lower.contains("sony wf") { return .headphones }
        return .other
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        guard !devices.isEmpty else {
            return .text("BT: No devices")
        }

        if config.showAllDevices && devices.count > 1 {
            // Show all as compact: "KB 95% Mouse 78% AirPods 62%"
            let parts = devices.map { dev in
                let short = shortName(dev)
                return "\(short) \(dev.batteryLevel)%"
            }
            let text = parts.joined(separator: "  ")
            return coloredForLowBattery(text, devices: devices)
        }

        // Show current device
        let dev = devices[min(_currentIndex, devices.count - 1)]
        let text = "\(dev.deviceType.icon) \(dev.name.prefix(10)) \(dev.batteryLevel)%"
        return coloredForLowBattery(text, devices: [dev])
    }

    private func shortName(_ dev: BTDevice) -> String {
        switch dev.deviceType {
        case .keyboard: return "KB"
        case .mouse, .trackpad: return "Mouse"
        case .airpods: return "Pods"
        case .headphones: return "HP"
        case .gamepad: return "Pad"
        case .other: return String(dev.name.prefix(4))
        }
    }

    private func coloredForLowBattery(_ text: String, devices: [BTDevice]) -> WidgetDisplayMode {
        let hasLow = devices.contains { $0.batteryLevel <= config.lowBatteryThreshold }
        if hasLow {
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            ])
            return .attributedText(attr)
        }
        return .text(text)
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "BLUETOOTH BATTERIES", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if devices.isEmpty {
            let noDevices = NSMenuItem(title: "No Bluetooth devices with battery info", action: nil, keyEquivalent: "")
            noDevices.isEnabled = false
            menu.addItem(noDevices)
        } else {
            for dev in devices {
                let batteryBar = batteryBarString(dev.batteryLevel)
                let item = NSMenuItem(
                    title: "\(dev.deviceType.icon) \(dev.name) - \(dev.batteryLevel)% \(batteryBar)",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    private func batteryBarString(_ pct: Int) -> String {
        let filled = pct / 10
        return "[" + String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled) + "]"
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
