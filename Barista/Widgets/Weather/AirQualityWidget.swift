import Cocoa

struct AirQualityConfig: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var refreshRate: TimeInterval

    static let `default` = AirQualityConfig(
        latitude: 40.7128,
        longitude: -74.0060,
        refreshRate: 600
    )
}

class AirQualityWidget: BaristaWidget {
    static let widgetID = "air-quality"
    static let displayName = "Air Quality"
    static let subtitle = "Current air quality index and pollutants"
    static let iconName = "aqi.medium"
    static let category = WidgetCategory.weather
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = AirQualityConfig.default

    var config: AirQualityConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var aqi: Int?
    private(set) var pm25: Double?
    private(set) var pm10: Double?
    private(set) var lastFetchFailed = false

    required init(config: AirQualityConfig) {
        self.config = config
    }

    func start() {
        fetchAirQuality()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.fetchAirQuality()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchAirQuality() {
        let urlStr = "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=\(config.latitude)&longitude=\(config.longitude)&current=us_aqi,pm2_5,pm10"
        guard let url = URL(string: urlStr) else { return }

        DataFetcher.shared.fetch(url: url, maxAge: 300) { [weak self] result in
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
            if let aqiVal = current["us_aqi"] as? Int {
                self.aqi = aqiVal
            } else if let aqiVal = current["us_aqi"] as? Double {
                self.aqi = Int(aqiVal)
            }
            if let pm25Val = current["pm2_5"] as? Double {
                self.pm25 = pm25Val
            }
            if let pm10Val = current["pm10"] as? Double {
                self.pm10 = pm10Val
            }
            self.onDisplayUpdate?()
        }
    }

    private func aqiLabel(_ value: Int) -> String {
        switch value {
        case 0...50: return "Good"
        case 51...100: return "Moderate"
        case 101...150: return "Unhealthy (SG)"
        default: return "Unhealthy"
        }
    }

    private func aqiColor(_ value: Int) -> NSColor {
        switch value {
        case 0...50: return Theme.green
        case 51...100: return NSColor.systemYellow
        case 101...150: return NSColor.systemOrange
        default: return Theme.red
        }
    }

    func render() -> WidgetDisplayMode {
        if lastFetchFailed && aqi == nil {
            return .text("AQI: Offline")
        }
        guard let aqiVal = aqi else {
            return .text("AQI: --")
        }

        let label = aqiLabel(aqiVal)
        let color = aqiColor(aqiVal)
        let str = "AQI \(aqiVal) \(label)"
        let attr = NSAttributedString(string: str, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ])
        return .attributedText(attr)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "AIR QUALITY", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if let aqiVal = aqi {
            let aqiItem = NSMenuItem(title: "US AQI: \(aqiVal) - \(aqiLabel(aqiVal))", action: nil, keyEquivalent: "")
            aqiItem.isEnabled = false
            menu.addItem(aqiItem)
        }

        if let pm25Val = pm25 {
            let pm25Item = NSMenuItem(title: "PM2.5: \(String(format: "%.1f", pm25Val)) ug/m3", action: nil, keyEquivalent: "")
            pm25Item.isEnabled = false
            menu.addItem(pm25Item)
        }

        if let pm10Val = pm10 {
            let pm10Item = NSMenuItem(title: "PM10: \(String(format: "%.1f", pm10Val)) ug/m3", action: nil, keyEquivalent: "")
            pm10Item.isEnabled = false
            menu.addItem(pm10Item)
        }

        if aqi == nil && lastFetchFailed {
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
