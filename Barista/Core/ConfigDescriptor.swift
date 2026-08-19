import Cocoa

/// Describes a single configurable setting for a widget.
/// Used by the generic config panel builder to create UI automatically.
enum ConfigField {
    /// On/off toggle (NSSwitch)
    case toggle(label: String, key: String, get: () -> Bool, set: (Bool) -> Void)

    /// Numeric slider with integer steps
    case slider(label: String, key: String, min: Double, max: Double, step: Double, get: () -> Double, set: (Double) -> Void, format: String? = nil)

    /// Text input (NSTextField)
    case text(label: String, key: String, placeholder: String, get: () -> String, set: (String) -> Void)

    /// Dropdown picker (NSPopUpButton)
    case picker(label: String, key: String, options: [(title: String, value: String)], get: () -> String, set: (String) -> Void)

    /// Read-only info line
    case info(label: String, value: () -> String)

    /// Section header (visual separator)
    case section(title: String)
}

/// Protocol for widgets that describe their config declaratively.
/// Widgets conforming to this get automatic config panels - no need to hand-code
/// buildConfigControls or add cases to AppDelegate's switch statements.
protocol DeclarativeConfig: AnyObject {
    func configFields() -> [ConfigField]
}
