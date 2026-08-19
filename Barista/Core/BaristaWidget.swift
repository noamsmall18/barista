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
    case finance = "Finance"
    case system = "System"
    case weather = "Weather"
    case productivity = "Productivity"
    case musicMedia = "Music & Media"
    case timeCalendar = "Time & Calendar"
    case sports = "Sports"
    case utility = "Utility"

    var icon: String {
        switch self {
        case .finance: return "chart.line.uptrend.xyaxis"
        case .system: return "cpu"
        case .weather: return "cloud.sun"
        case .productivity: return "checkmark.circle"
        case .musicMedia: return "music.note"
        case .timeCalendar: return "clock"
        case .sports: return "sportscourt"
        case .utility: return "wrench"
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
