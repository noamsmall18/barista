import Cocoa
import IOKit.pwr_mgt

struct KeepAwakeConfig: Codable, Equatable {
    var defaultDuration: Int  // minutes, 0 = indefinite
    var preventDisplaySleep: Bool
    var showCountdown: Bool

    static let `default` = KeepAwakeConfig(
        defaultDuration: 0,
        preventDisplaySleep: true,
        showCountdown: true
    )
}

class KeepAwakeWidget: BaristaWidget {
    static let widgetID = "keep-awake"
    static let displayName = "Keep Awake"
    static let subtitle = "Prevent your Mac from sleeping"
    static let iconName = "cup.and.saucer.fill"
    static let category = WidgetCategory.utility
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = KeepAwakeConfig.default

    var config: KeepAwakeConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 1 }

    private var timer: Timer?
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false
    private(set) var endTime: Date?

    required init(config: KeepAwakeConfig) {
        self.config = config
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deactivateAssertion()
    }

    private func tick() {
        if isActive, let end = endTime, Date() >= end {
            deactivateAssertion()
        }
        onDisplayUpdate?()
    }

    // MARK: - Power Assertion

    private func activateAssertion(minutes: Int) {
        deactivateAssertion()

        let type = config.preventDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString

        let reason = "Barista Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertionID)

        if result == kIOReturnSuccess {
            isActive = true
            endTime = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        }
    }

    private func deactivateAssertion() {
        if isActive {
            IOPMAssertionRelease(assertionID)
            isActive = false
            endTime = nil
            assertionID = 0
        }
    }

    func toggle(minutes: Int = 0) {
        if isActive {
            deactivateAssertion()
        } else {
            activateAssertion(minutes: minutes > 0 ? minutes : config.defaultDuration)
        }
        onDisplayUpdate?()
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        if !isActive {
            return .text("\u{2615} Sleep OK")
        }

        if config.showCountdown, let end = endTime {
            let remaining = Int(end.timeIntervalSince(Date()))
            if remaining <= 0 {
                return .text("\u{2615} Sleep OK")
            }
            let h = remaining / 3600
            let m = (remaining % 3600) / 60
            let s = remaining % 60
            let timeStr = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            let text = "\u{2615} Awake \(timeStr)"
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: Theme.brandAmber
            ])
            return .attributedText(attr)
        }

        let attr = NSAttributedString(string: "\u{2615} Awake", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Theme.brandAmber
        ])
        return .attributedText(attr)
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "KEEP AWAKE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if isActive {
            let statusItem = NSMenuItem(title: "\u{2615} Active - Mac will not sleep", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            if let end = endTime {
                let remaining = Int(end.timeIntervalSince(Date()))
                let m = remaining / 60
                let timeItem = NSMenuItem(title: "  \(m) minutes remaining", action: nil, keyEquivalent: "")
                timeItem.isEnabled = false
                menu.addItem(timeItem)
            } else {
                let indef = NSMenuItem(title: "  Indefinite (until disabled)", action: nil, keyEquivalent: "")
                indef.isEnabled = false
                menu.addItem(indef)
            }

            menu.addItem(NSMenuItem.separator())
            let stopItem = NSMenuItem(title: "Disable Keep Awake", action: #selector(toggleAwake), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let statusItem = NSMenuItem(title: "Mac can sleep normally", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            menu.addItem(NSMenuItem.separator())

            // Duration options
            let durations = [
                (0, "Indefinitely"),
                (15, "15 minutes"),
                (30, "30 minutes"),
                (60, "1 hour"),
                (120, "2 hours"),
                (240, "4 hours"),
                (480, "8 hours"),
            ]

            for (mins, label) in durations {
                let item = NSMenuItem(title: "Keep Awake \(label)", action: #selector(activateWithDuration(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mins
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let displayItem = NSMenuItem(
            title: config.preventDisplaySleep ? "Mode: Display + System" : "Mode: System Only",
            action: nil, keyEquivalent: ""
        )
        displayItem.isEnabled = false
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func toggleAwake() {
        toggle()
    }

    @objc private func activateWithDuration(_ sender: NSMenuItem) {
        activateAssertion(minutes: sender.tag)
        onDisplayUpdate?()
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
