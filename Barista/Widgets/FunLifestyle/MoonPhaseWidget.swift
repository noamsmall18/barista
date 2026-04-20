import Cocoa

struct MoonPhaseConfig: Codable, Equatable {
    var showName: Bool
    var showIllumination: Bool
    var showCountdown: Bool

    static let `default` = MoonPhaseConfig(
        showName: true,
        showIllumination: false,
        showCountdown: false
    )
}

class MoonPhaseWidget: BaristaWidget {
    static let widgetID = "moon-phase"
    static let displayName = "Moon Phase"
    static let subtitle = "Current lunar phase and illumination"
    static let iconName = "moon.stars"
    static let category = WidgetCategory.funLifestyle
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = MoonPhaseConfig.default

    var config: MoonPhaseConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 3600 }

    private var timer: Timer?
    private(set) var phase: Double = 0 // 0-1 synodic cycle
    private(set) var phaseName: String = ""
    private(set) var phaseEmoji: String = ""
    private(set) var illumination: Double = 0

    required init(config: MoonPhaseConfig) {
        self.config = config
    }

    func start() {
        computePhase()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.computePhase()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func computePhase() {
        // Known new moon: Jan 6, 2000 18:14 UTC
        let knownNewMoon = Date(timeIntervalSince1970: 947182440)
        let synodicMonth = 29.53058867
        let daysSinceNew = Date().timeIntervalSince(knownNewMoon) / 86400
        let cycles = daysSinceNew / synodicMonth
        phase = cycles - floor(cycles) // 0 to 1

        // Illumination (approximate)
        illumination = (1 - cos(phase * 2 * .pi)) / 2 * 100

        // Phase name and emoji
        switch phase {
        case 0..<0.0625:
            phaseName = "New Moon"; phaseEmoji = "\u{1F311}"
        case 0.0625..<0.1875:
            phaseName = "Waxing Crescent"; phaseEmoji = "\u{1F312}"
        case 0.1875..<0.3125:
            phaseName = "First Quarter"; phaseEmoji = "\u{1F313}"
        case 0.3125..<0.4375:
            phaseName = "Waxing Gibbous"; phaseEmoji = "\u{1F314}"
        case 0.4375..<0.5625:
            phaseName = "Full Moon"; phaseEmoji = "\u{1F315}"
        case 0.5625..<0.6875:
            phaseName = "Waning Gibbous"; phaseEmoji = "\u{1F316}"
        case 0.6875..<0.8125:
            phaseName = "Last Quarter"; phaseEmoji = "\u{1F317}"
        case 0.8125..<0.9375:
            phaseName = "Waning Crescent"; phaseEmoji = "\u{1F318}"
        default:
            phaseName = "New Moon"; phaseEmoji = "\u{1F311}"
        }
    }

    func render() -> WidgetDisplayMode {
        var parts = [phaseEmoji]
        if config.showName { parts.append(phaseName) }
        if config.showIllumination { parts.append(String(format: "%.0f%%", illumination)) }
        if config.showCountdown {
            // Days until next full moon (phase 0.5) or new moon (phase 0)
            let synodicMonth = 29.53058867
            let nextFull = phase < 0.5 ? (0.5 - phase) * synodicMonth : (1.5 - phase) * synodicMonth
            parts.append(String(format: "Full in %dd", Int(nextFull)))
        }
        return .text(parts.joined(separator: " "))
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "MOON PHASE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let phaseItem = NSMenuItem(title: "\(phaseEmoji) \(phaseName)", action: nil, keyEquivalent: "")
        phaseItem.isEnabled = false
        menu.addItem(phaseItem)

        let illumItem = NSMenuItem(title: String(format: "Illumination: %.1f%%", illumination), action: nil, keyEquivalent: "")
        illumItem.isEnabled = false
        menu.addItem(illumItem)

        // Days to next full/new
        let synodicMonth = 29.53058867
        let daysToFull = phase < 0.5 ? (0.5 - phase) * synodicMonth : (1.5 - phase) * synodicMonth
        let daysToNew = (1.0 - phase) * synodicMonth

        menu.addItem(NSMenuItem.separator())
        let fullItem = NSMenuItem(title: String(format: "Next Full Moon: %.0f days", daysToFull), action: nil, keyEquivalent: "")
        fullItem.isEnabled = false
        menu.addItem(fullItem)

        let newItem = NSMenuItem(title: String(format: "Next New Moon: %.0f days", daysToNew), action: nil, keyEquivalent: "")
        newItem.isEnabled = false
        menu.addItem(newItem)

        // Phase calendar
        menu.addItem(NSMenuItem.separator())
        let calHeader = NSMenuItem(title: "This Month:", action: nil, keyEquivalent: "")
        calHeader.isEnabled = false
        menu.addItem(calHeader)

        let emojis = ["\u{1F311}", "\u{1F312}", "\u{1F313}", "\u{1F314}", "\u{1F315}", "\u{1F316}", "\u{1F317}", "\u{1F318}"]
        var calLine = ""
        for day in stride(from: -14, through: 14, by: 7) {
            let dayPhase = phase + Double(day) / synodicMonth
            let norm = dayPhase - floor(dayPhase)
            let idx = min(Int(norm * 8), 7)
            let label = day == 0 ? "Today" : (day > 0 ? "+\(day)d" : "\(day)d")
            calLine += "\(emojis[idx])\(label) "
        }
        let calItem = NSMenuItem(title: calLine, action: nil, keyEquivalent: "")
        calItem.isEnabled = false
        menu.addItem(calItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
