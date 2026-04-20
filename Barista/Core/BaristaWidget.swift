import Cocoa

// MARK: - Widget Display Mode

enum WidgetDisplayMode {
    case text(String)
    case attributedText(NSAttributedString)
    case scrollingText(NSAttributedString, width: CGFloat)
    case iconAndText(NSImage, String)
    case sparkline([Double], label: String?, width: CGFloat)
}

// MARK: - Widget Category

enum WidgetCategory: String, CaseIterable, Codable {
    case timeCalendar = "Time & Calendar"
    case weather = "Weather"
    case finance = "Finance"
    case system = "System"
    case productivity = "Productivity"
    case musicMedia = "Music & Media"
    case social = "Social"
    case funLifestyle = "Fun & Lifestyle"
    case sports = "Sports"
    case developer = "Developer"
    case utility = "Utility"
    case health = "Health"

    var icon: String {
        switch self {
        case .timeCalendar: return "clock"
        case .weather: return "cloud.sun"
        case .finance: return "chart.line.uptrend.xyaxis"
        case .system: return "cpu"
        case .productivity: return "checkmark.circle"
        case .musicMedia: return "music.note"
        case .social: return "person.2"
        case .funLifestyle: return "sparkles"
        case .sports: return "sportscourt"
        case .developer: return "terminal"
        case .utility: return "wrench"
        case .health: return "heart.fill"
        }
    }
}

// MARK: - Widget Descriptor (static metadata for gallery)

protocol WidgetDescriptor {
    static var widgetID: String { get }
    static var displayName: String { get }
    static var subtitle: String { get }
    static var iconName: String { get }
    static var category: WidgetCategory { get }
    static var allowsMultiple: Bool { get }
    static var isPremium: Bool { get }
}

// MARK: - Widget Protocol

protocol BaristaWidget: AnyObject, WidgetDescriptor {
    associatedtype Config: Codable & Equatable

    static var defaultConfig: Config { get }

    var config: Config { get set }
    var onDisplayUpdate: (() -> Void)? { get set }
    var refreshInterval: TimeInterval? { get }

    init(config: Config)

    func start()
    func stop()
    func render() -> WidgetDisplayMode
    func buildDropdownMenu() -> NSMenu
    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView]
}

// MARK: - Cycleable Protocol

/// Widgets that display multiple items (games, stories, zones) and can cycle through them.
/// Conforming widgets get click-to-advance and auto-rotation in the menu bar.
protocol Cycleable: AnyObject {
    var itemCount: Int { get }
    var currentIndex: Int { get }
    var cycleInterval: TimeInterval { get }
    func cycleNext()
}

// MARK: - Interactive Dropdown Protocol

/// Widgets that need rich dropdowns (graphs, sliders, calendars) instead of plain NSMenu.
/// Conforming widgets get an NSPopover instead of NSMenu when clicking the status item.
protocol InteractiveDropdown: AnyObject {
    func buildDropdownPopover() -> NSView
    var dropdownSize: NSSize { get }
}
