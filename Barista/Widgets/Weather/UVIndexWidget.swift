import Cocoa

struct UVIndexConfig: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var refreshRate: TimeInterval

    static let `default` = UVIndexConfig(
        latitude: 40.7128,
        longitude: -74.0060,
        refreshRate: 900
    )
}

class UVIndexWidget: BaristaWidget {
    static let widgetID = "uv-index"
    static let displayName = "UV Index"
    static let subtitle = "Current UV index and exposure level"
    static let iconName = "sun.max.fill"
    static let category = WidgetCategory.weather
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = UVIndexConfig.default

    var config: UVIndexConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var uvIndex: Double?
    private(set) var lastFetchFailed = false

    required init(config: UVIndexConfig) {
        self.config = config
    }

    func start() {
        fetchUVIndex()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.fetchUVIndex()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchUVIndex() {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(config.latitude)&longitude=\(config.longitude)&current=uv_index"
        guard let url = URL(string: urlStr) else { return }

        DataFetcher.shared.fetch(url: url, maxAge: 600) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.parseResponse(data: data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    self.onDisplayUpdate?()
                }
            }
        }
    }

    private func parseResponse(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else {
            DispatchQueue.main.async {
                self.lastFetchFailed = true
                self.onDisplayUpdate?()
            }
            return
        }

        DispatchQueue.main.async {
            if let uv = current["uv_index"] as? Double {
                self.uvIndex = uv
            } else if let uv = current["uv_index"] as? Int {
                self.uvIndex = Double(uv)
            }
            self.onDisplayUpdate?()
        }
    }

    private func uvLabel(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        switch rounded {
        case 0...2: return "Low"
        case 3...5: return "Moderate"
        case 6...7: return "High"
        case 8...10: return "Very High"
        default: return "Extreme"
        }
    }

    private func uvColor(_ value: Double) -> NSColor {
        let rounded = Int(value.rounded())
        switch rounded {
        case 0...2: return Theme.green
        case 3...5: return NSColor.systemYellow
        case 6...7: return NSColor.systemOrange
        case 8...10: return Theme.red
        default: return NSColor.systemPurple
        }
    }

    func render() -> WidgetDisplayMode {
        if lastFetchFailed && uvIndex == nil {
            return .text("UV: Offline")
        }
        guard let uv = uvIndex else {
            return .text("UV: --")
        }

        let rounded = Int(uv.rounded())
        let label = uvLabel(uv)
        let color = uvColor(uv)
        let str = "UV \(rounded) \(label)"
        let attr = NSAttributedString(string: str, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ])
        return .attributedText(attr)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "UV INDEX", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if let uv = uvIndex {
            let rounded = Int(uv.rounded())
            let uvItem = NSMenuItem(title: "UV Index: \(rounded) - \(uvLabel(uv))", action: nil, keyEquivalent: "")
            uvItem.isEnabled = false
            menu.addItem(uvItem)

            let rawItem = NSMenuItem(title: "Raw value: \(String(format: "%.1f", uv))", action: nil, keyEquivalent: "")
            rawItem.isEnabled = false
            menu.addItem(rawItem)

            menu.addItem(NSMenuItem.separator())

            let advice: String
            switch rounded {
            case 0...2: advice = "No protection needed"
            case 3...5: advice = "Wear sunscreen"
            case 6...7: advice = "Sunscreen + hat recommended"
            case 8...10: advice = "Avoid sun exposure"
            default: advice = "Stay indoors if possible"
            }
            let adviceItem = NSMenuItem(title: advice, action: nil, keyEquivalent: "")
            adviceItem.isEnabled = false
            menu.addItem(adviceItem)
        } else {
            let offline = NSMenuItem(title: "Unable to fetch data", action: nil, keyEquivalent: "")
            offline.isEnabled = false
            menu.addItem(offline)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
