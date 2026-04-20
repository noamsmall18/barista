import Cocoa

/// Codable color wrapper for persistence.
struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    init(_ color: NSColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Hex string like "#ff7f50"
    var hex: String {
        String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

/// Full menu bar appearance configuration.
struct MenuBarAppearance: Codable, Equatable {
    var isEnabled: Bool
    var mode: AppearanceMode
    var opacity: Double  // 0.0 - 1.0

    enum AppearanceMode: Codable, Equatable {
        case solid(color: CodableColor)
        case gradient(colors: [CodableColor], angle: Double)
        case dynamicGradient(style: DynamicStyle)
        case frostedGlass(tintColor: CodableColor)
    }

    enum DynamicStyle: String, Codable, CaseIterable {
        case sunrise = "Sunrise"
        case ocean = "Ocean"
        case forest = "Forest"
        case neon = "Neon"
        case lavender = "Lavender"
    }

    static let `default` = MenuBarAppearance(
        isEnabled: false,
        mode: .solid(color: CodableColor(red: 0.1, green: 0.1, blue: 0.2)),
        opacity: 0.8
    )

    // MARK: - Presets

    static let presets: [(String, MenuBarAppearance)] = [
        ("Midnight", MenuBarAppearance(
            isEnabled: true,
            mode: .gradient(
                colors: [
                    CodableColor(red: 0.05, green: 0.02, blue: 0.15),
                    CodableColor(red: 0.02, green: 0.05, blue: 0.20)
                ],
                angle: 0
            ),
            opacity: 0.85
        )),
        ("Sunset", MenuBarAppearance(
            isEnabled: true,
            mode: .gradient(
                colors: [
                    CodableColor(red: 0.85, green: 0.25, blue: 0.15),
                    CodableColor(red: 0.95, green: 0.55, blue: 0.15),
                    CodableColor(red: 0.45, green: 0.10, blue: 0.35)
                ],
                angle: 0
            ),
            opacity: 0.7
        )),
        ("Ocean", MenuBarAppearance(
            isEnabled: true,
            mode: .gradient(
                colors: [
                    CodableColor(red: 0.02, green: 0.15, blue: 0.30),
                    CodableColor(red: 0.05, green: 0.30, blue: 0.45)
                ],
                angle: 0
            ),
            opacity: 0.8
        )),
        ("Forest", MenuBarAppearance(
            isEnabled: true,
            mode: .gradient(
                colors: [
                    CodableColor(red: 0.05, green: 0.18, blue: 0.08),
                    CodableColor(red: 0.10, green: 0.28, blue: 0.12)
                ],
                angle: 0
            ),
            opacity: 0.8
        )),
        ("Neon", MenuBarAppearance(
            isEnabled: true,
            mode: .gradient(
                colors: [
                    CodableColor(red: 0.55, green: 0.0, blue: 0.80),
                    CodableColor(red: 0.0, green: 0.70, blue: 0.90)
                ],
                angle: 0
            ),
            opacity: 0.65
        )),
        ("Rose", MenuBarAppearance(
            isEnabled: true,
            mode: .gradient(
                colors: [
                    CodableColor(red: 0.40, green: 0.05, blue: 0.20),
                    CodableColor(red: 0.60, green: 0.10, blue: 0.30)
                ],
                angle: 0
            ),
            opacity: 0.75
        )),
        ("Monochrome", MenuBarAppearance(
            isEnabled: true,
            mode: .solid(color: CodableColor(red: 0.12, green: 0.12, blue: 0.12)),
            opacity: 0.9
        )),
        ("Frosted", MenuBarAppearance(
            isEnabled: true,
            mode: .frostedGlass(tintColor: CodableColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 0.3)),
            opacity: 1.0
        )),
    ]

    // MARK: - Dynamic Gradient Colors

    /// Returns interpolated colors for dynamic gradients based on time of day.
    static func dynamicColors(for style: DynamicStyle) -> [CodableColor] {
        let hour = Calendar.current.component(.hour, from: Date())
        let minute = Calendar.current.component(.minute, from: Date())
        let progress = (Double(hour) * 60 + Double(minute)) / 1440.0  // 0.0 - 1.0 over 24h

        switch style {
        case .sunrise:
            if progress < 0.25 {  // midnight to 6am - deep blue
                return [CodableColor(red: 0.02, green: 0.02, blue: 0.12), CodableColor(red: 0.05, green: 0.05, blue: 0.18)]
            } else if progress < 0.35 {  // 6am to 8:24am - sunrise
                return [CodableColor(red: 0.85, green: 0.35, blue: 0.15), CodableColor(red: 0.95, green: 0.65, blue: 0.20)]
            } else if progress < 0.75 {  // 8:24am to 6pm - bright blue
                return [CodableColor(red: 0.15, green: 0.40, blue: 0.70), CodableColor(red: 0.20, green: 0.55, blue: 0.85)]
            } else if progress < 0.85 {  // 6pm to 8:24pm - sunset
                return [CodableColor(red: 0.80, green: 0.25, blue: 0.20), CodableColor(red: 0.55, green: 0.15, blue: 0.40)]
            } else {  // 8:24pm to midnight - night
                return [CodableColor(red: 0.05, green: 0.02, blue: 0.15), CodableColor(red: 0.02, green: 0.05, blue: 0.20)]
            }
        case .ocean:
            let depth = 0.15 + sin(progress * .pi * 2) * 0.1
            return [
                CodableColor(red: 0.02, green: depth, blue: depth + 0.15),
                CodableColor(red: 0.05, green: depth + 0.1, blue: depth + 0.25)
            ]
        case .forest:
            let life = 0.15 + sin(progress * .pi * 2) * 0.08
            return [
                CodableColor(red: 0.03, green: life, blue: 0.05),
                CodableColor(red: 0.06, green: life + 0.10, blue: 0.08)
            ]
        case .neon:
            let shift = progress * .pi * 2
            return [
                CodableColor(red: 0.4 + sin(shift) * 0.2, green: 0.0, blue: 0.6 + cos(shift) * 0.2),
                CodableColor(red: 0.0, green: 0.5 + sin(shift + 1) * 0.2, blue: 0.7 + cos(shift + 1) * 0.2)
            ]
        case .lavender:
            return [
                CodableColor(red: 0.30, green: 0.15, blue: 0.45),
                CodableColor(red: 0.45, green: 0.25, blue: 0.55)
            ]
        }
    }

    // MARK: - Persistence

    private static let key = "barista.menuBarAppearance"

    static func load() -> MenuBarAppearance {
        guard let data = UserDefaults.standard.data(forKey: key),
              let appearance = try? JSONDecoder().decode(MenuBarAppearance.self, from: data) else {
            return .default
        }
        return appearance
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: MenuBarAppearance.key)
        }
    }
}
