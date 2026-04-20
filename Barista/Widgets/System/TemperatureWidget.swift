import Cocoa

struct TemperatureConfig: Codable, Equatable {
    var useFahrenheit: Bool
    var showSensorName: Bool
    var primarySensor: String  // SMC key, e.g. "TC0P"
    var alertThreshold: Double  // Celsius
    var refreshRate: TimeInterval

    static let `default` = TemperatureConfig(
        useFahrenheit: false,
        showSensorName: true,
        primarySensor: "TC0P",
        alertThreshold: 85,
        refreshRate: 5
    )
}

class TemperatureWidget: BaristaWidget, InteractiveDropdown {
    static let widgetID = "temperature-sensors"
    static let displayName = "Temperature"
    static let subtitle = "CPU, GPU & system temperatures"
    static let iconName = "thermometer.medium"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = TemperatureConfig.default

    var config: TemperatureConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var allReadings: [(name: String, key: String, value: Double)] = []
    private(set) var primaryTemp: Double = 0
    private(set) var history: [Double] = []
    private let maxHistory = 60
    private(set) var fanSpeeds: [(index: Int, rpm: Double)] = []

    required init(config: TemperatureConfig) {
        self.config = config
    }

    func start() {
        updateTemps()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.updateTemps()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTemps() {
        allReadings = SMCReader.shared.readAllTemperatures()

        // Read primary sensor
        if let val = SMCReader.shared.readValue(key: config.primarySensor) {
            primaryTemp = val
        } else if let first = allReadings.first {
            primaryTemp = first.value
            config.primarySensor = first.key
        }

        history.append(primaryTemp)
        if history.count > maxHistory { history.removeFirst() }

        // Read fans
        fanSpeeds = []
        let fanCount = SMCReader.shared.fanCount()
        for i in 0..<fanCount {
            if let rpm = SMCReader.shared.fanSpeed(index: i) {
                fanSpeeds.append((index: i, rpm: rpm))
            }
        }

        onDisplayUpdate?()
    }

    private func formatTemp(_ celsius: Double) -> String {
        if config.useFahrenheit {
            return String(format: "%.0f\u{00B0}F", celsius * 9.0 / 5.0 + 32)
        }
        return String(format: "%.0f\u{00B0}C", celsius)
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        var parts: [String] = []

        if config.showSensorName {
            let sensorName = SMCReader.knownSensors.first(where: { $0.key == config.primarySensor })?.name ?? "Temp"
            // Shorten for menu bar
            let short = sensorName
                .replacingOccurrences(of: "Proximity", with: "")
                .replacingOccurrences(of: "CPU ", with: "CPU ")
                .trimmingCharacters(in: .whitespaces)
            parts.append(short)
        } else {
            parts.append("\u{1F321}")
        }

        parts.append(formatTemp(primaryTemp))

        let text = parts.joined(separator: " ")

        if primaryTemp >= config.alertThreshold {
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

        let header = NSMenuItem(title: "TEMPERATURE SENSORS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for reading in allReadings {
            let marker = reading.key == config.primarySensor ? " *" : ""
            let item = NSMenuItem(
                title: "\(reading.name): \(formatTemp(reading.value))\(marker)",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        if allReadings.isEmpty {
            let noData = NSMenuItem(title: "No sensors detected", action: nil, keyEquivalent: "")
            noData.isEnabled = false
            menu.addItem(noData)
        }

        if !fanSpeeds.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for fan in fanSpeeds {
                let item = NSMenuItem(
                    title: String(format: "Fan %d: %.0f RPM", fan.index + 1, fan.rpm),
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

    // MARK: - Interactive Dropdown

    func buildDropdownPopover() -> NSView {
        let width: CGFloat = 340
        let rowH: CGFloat = 22
        let padding: CGFloat = 16
        let sensorCount = max(allReadings.count, 1)
        let fanCount = fanSpeeds.count
        let sparkH: CGFloat = history.count >= 2 ? 70 : 0
        let height = padding + 20 + 8 + CGFloat(sensorCount) * rowH + (fanCount > 0 ? 8 + CGFloat(fanCount) * rowH : 0) + 8 + sparkH + padding

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        var y = height - padding

        // Title
        let title = NSTextField(labelWithString: "Temperature Sensors")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: padding, y: y - 18, width: width - padding * 2, height: 18)
        container.addSubview(title)
        y -= 28

        // Sensor readings
        if allReadings.isEmpty {
            let noData = NSTextField(labelWithString: "No sensors detected")
            noData.font = .systemFont(ofSize: 11)
            noData.textColor = Theme.textMuted
            noData.frame = NSRect(x: padding, y: y - 16, width: width - padding * 2, height: 16)
            container.addSubview(noData)
            y -= rowH
        } else {
            for reading in allReadings {
                let isPrimary = reading.key == config.primarySensor
                let label = NSTextField(labelWithString: reading.name)
                label.font = .systemFont(ofSize: 11, weight: isPrimary ? .semibold : .regular)
                label.textColor = isPrimary ? Theme.textPrimary : Theme.textSecondary
                label.frame = NSRect(x: padding, y: y - 16, width: 180, height: 16)
                container.addSubview(label)

                let tempColor: NSColor = reading.value >= config.alertThreshold ? Theme.red : (reading.value >= config.alertThreshold * 0.85 ? Theme.accent : Theme.green)
                let value = NSTextField(labelWithString: formatTemp(reading.value))
                value.font = .monospacedDigitSystemFont(ofSize: 11, weight: isPrimary ? .semibold : .regular)
                value.textColor = tempColor
                value.alignment = .right
                value.frame = NSRect(x: width - padding - 80, y: y - 16, width: 80, height: 16)
                container.addSubview(value)

                y -= rowH
            }
        }

        // Fan speeds
        if !fanSpeeds.isEmpty {
            y -= 4
            let divider = NSView(frame: NSRect(x: padding, y: y, width: width - padding * 2, height: 1))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Theme.divider.cgColor
            container.addSubview(divider)
            y -= 8

            for fan in fanSpeeds {
                let label = NSTextField(labelWithString: "Fan \(fan.index + 1)")
                label.font = .systemFont(ofSize: 11)
                label.textColor = Theme.textSecondary
                label.frame = NSRect(x: padding, y: y - 16, width: 120, height: 16)
                container.addSubview(label)

                let value = NSTextField(labelWithString: String(format: "%.0f RPM", fan.rpm))
                value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                value.textColor = Theme.textSecondary
                value.alignment = .right
                value.frame = NSRect(x: width - padding - 80, y: y - 16, width: 80, height: 16)
                container.addSubview(value)

                y -= rowH
            }
        }

        // Sparkline
        if history.count >= 2 {
            y -= 4
            let sparkWidth = width - padding * 2
            let sparkImg = SparklineRenderer.render(
                data: history,
                width: sparkWidth,
                style: SparklineRenderer.Style(
                    lineColor: Theme.red,
                    fillColor: Theme.red.withAlphaComponent(0.08),
                    lineWidth: 1.5,
                    height: sparkH,
                    pointRadius: 2
                )
            )
            let imgView = NSImageView(frame: NSRect(x: padding, y: y - sparkH, width: sparkWidth, height: sparkH))
            imgView.image = sparkImg
            imgView.imageScaling = .scaleNone
            container.addSubview(imgView)
        }

        return container
    }

    var dropdownSize: NSSize {
        let rowH: CGFloat = 22
        let padding: CGFloat = 16
        let sensorCount = max(allReadings.count, 1)
        let fanCount = fanSpeeds.count
        let sparkH: CGFloat = history.count >= 2 ? 70 : 0
        let height = padding + 20 + 8 + CGFloat(sensorCount) * rowH + (fanCount > 0 ? 8 + CGFloat(fanCount) * rowH : 0) + 8 + sparkH + padding
        return NSSize(width: 340, height: max(height, 120))
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
