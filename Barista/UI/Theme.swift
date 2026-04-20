import Cocoa

struct Theme {
    // Brand colors from logo
    static let brandAmber = NSColor(red: 0.96, green: 0.655, blue: 0.231, alpha: 1)      // #f5a73b
    static let brandAmberBright = NSColor(red: 0.973, green: 0.722, blue: 0.306, alpha: 1) // #f8b84e
    static let brandCyan = NSColor(red: 0.365, green: 0.878, blue: 0.902, alpha: 1)       // #5de0e6
    static let brandCyanBright = NSColor(red: 0.478, green: 0.91, blue: 0.929, alpha: 1)  // #7ae8ed

    // Window & backgrounds - deep near-black with subtle navy tint
    static let bg = NSColor(red: 0.055, green: 0.047, blue: 0.071, alpha: 1)              // ~#0e0c12
    static let windowBg = NSColor(red: 0.055, green: 0.047, blue: 0.071, alpha: 0.82)     // translucent
    static let cardBg = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.045)            // glass
    static let cardBgHover = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)        // glass hover
    static let cardBorder = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.07)
    static let cardBorderHover = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18)
    static let inputBg = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.3)
    static let inputBorder = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)
    static let divider = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.05)
    static let glassBorder = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.10)

    // Text
    static let textPrimary = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.96)
    static let textSecondary = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.86)
    static let textMuted = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.54)
    static let textFaint = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.36)
    static let textGhost = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22)

    // Accent - amber from logo
    static let accent = brandAmber
    static let accentBg = NSColor(red: 0.96, green: 0.655, blue: 0.231, alpha: 0.10)

    // Status colors
    static let green = NSColor(red: 0.49, green: 0.847, blue: 0.627, alpha: 1)            // #7cd8a0
    static let greenBg = NSColor(red: 0.49, green: 0.847, blue: 0.627, alpha: 0.08)
    static let red = NSColor(red: 0.941, green: 0.541, blue: 0.541, alpha: 1)              // #f08a8a
    static let redBg = NSColor(red: 0.941, green: 0.541, blue: 0.541, alpha: 0.08)

    // Track/sunken controls
    static let trackBg = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.07)
    static let sunkenBg = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.3)

    static func colorForChange(_ pct: Double) -> NSColor {
        let abs = Swift.abs(pct)
        if pct >= 0 {
            if abs < 0.5 {
                return NSColor(red: 0.45, green: 0.75, blue: 0.58, alpha: 1)
            } else if abs < 2.0 {
                return NSColor(red: 0.25, green: 0.85, blue: 0.55, alpha: 1)
            } else if abs < 5.0 {
                return NSColor(red: 0.20, green: 0.95, blue: 0.55, alpha: 1)
            } else {
                return NSColor(red: 0.15, green: 1.00, blue: 0.60, alpha: 1)
            }
        } else {
            if abs < 0.5 {
                return NSColor(red: 0.80, green: 0.55, blue: 0.55, alpha: 1)
            } else if abs < 2.0 {
                return NSColor(red: 0.95, green: 0.45, blue: 0.40, alpha: 1)
            } else if abs < 5.0 {
                return NSColor(red: 1.00, green: 0.35, blue: 0.30, alpha: 1)
            } else {
                return NSColor(red: 1.00, green: 0.25, blue: 0.25, alpha: 1)
            }
        }
    }

    static func bgForChange(_ pct: Double) -> NSColor {
        return colorForChange(pct).withAlphaComponent(0.10)
    }

    static func borderForChange(_ pct: Double) -> NSColor {
        return colorForChange(pct).withAlphaComponent(0.35)
    }

    // MARK: - Additional Status Colors

    static let yellow = NSColor(red: 0.95, green: 0.82, blue: 0.35, alpha: 1)
    static let orange = NSColor(red: 0.95, green: 0.60, blue: 0.25, alpha: 1)
    static let purple = NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
    static let blue = NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 1)

    // MARK: - Semantic Colors

    static let success = green
    static let warning = brandAmber
    static let danger = red
    static let info = brandCyan

    // MARK: - Category Colors

    static func colorForCategory(_ category: WidgetCategory) -> NSColor {
        switch category {
        case .timeCalendar: return brandCyan
        case .weather: return blue
        case .finance: return green
        case .system: return orange
        case .productivity: return brandAmber
        case .musicMedia: return purple
        case .social: return brandCyanBright
        case .funLifestyle: return yellow
        case .sports: return red
        case .developer: return green
        case .utility: return textMuted
        case .health: return NSColor(red: 0.90, green: 0.40, blue: 0.50, alpha: 1)
        }
    }

    // MARK: - Factory Helpers

    static func monoLabel(_ text: String, size: CGFloat = 11, color: NSColor = textSecondary) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        label.textColor = color
        return label
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = textMuted
        let tracking = NSMutableAttributedString(string: text)
        tracking.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: text.count))
        tracking.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .semibold), range: NSRange(location: 0, length: text.count))
        tracking.addAttribute(.foregroundColor, value: textMuted, range: NSRange(location: 0, length: text.count))
        label.attributedStringValue = tracking
        return label
    }

    static func dividerView(width: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        v.wantsLayer = true
        v.layer?.backgroundColor = divider.cgColor
        return v
    }

    // MARK: - Animated Glow

    static func applyGlow(to layer: CALayer, color: NSColor, radius: CGFloat = 12) {
        layer.shadowColor = color.cgColor
        layer.shadowRadius = radius
        layer.shadowOpacity = 0.6
        layer.shadowOffset = .zero
    }
}
