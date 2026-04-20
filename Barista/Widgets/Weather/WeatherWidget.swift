import Cocoa
import CoreLocation

struct WeatherConfig: Codable, Equatable {
    var useCelsius: Bool
    var showFeelsLike: Bool
    var showCity: Bool
    var showEmoji: Bool
    var manualLat: Double?
    var manualLon: Double?
    var cityName: String

    static let `default` = WeatherConfig(
        useCelsius: false,
        showFeelsLike: false,
        showCity: true,
        showEmoji: true,
        manualLat: 40.7128,
        manualLon: -74.0060,
        cityName: "New York"
    )
}

class WeatherWidget: BaristaWidget {
    static let widgetID = "weather-current"
    static let displayName = "Current Weather"
    static let subtitle = "Temperature, conditions, and forecast"
    static let iconName = "cloud.sun"
    static let category = WidgetCategory.weather
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = WeatherConfig.default

    var config: WeatherConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 900 }

    private var timer: Timer?
    private(set) var temperature: Double?
    private(set) var feelsLike: Double?
    private(set) var weatherCode: Int = 0
    private(set) var humidity: Int = 0
    private(set) var windSpeed: Double = 0
    private(set) var highTemp: Double?
    private(set) var lowTemp: Double?
    private(set) var lastFetchFailed = false

    required init(config: WeatherConfig) {
        self.config = config
    }

    func start() {
        fetchWeather()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.fetchWeather()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchWeather() {
        let lat = config.manualLat ?? 40.7128
        let lon = config.manualLon ?? -74.0060
        let unit = config.useCelsius ? "celsius" : "fahrenheit"
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min&temperature_unit=\(unit)&wind_speed_unit=mph&forecast_days=1"

        guard let url = URL(string: urlStr) else { return }

        DataFetcher.shared.fetch(url: url, maxAge: 600) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.parseWeather(data: data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.temperature == nil {
                        self.onDisplayUpdate?()
                    }
                }
            }
        }
    }

    private func parseWeather(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let current = json["current"] as? [String: Any] {
                let temp = current["temperature_2m"] as? Double
                let feels = current["apparent_temperature"] as? Double
                let code = current["weather_code"] as? Int
                let humid = current["relative_humidity_2m"] as? Int
                let wind = current["wind_speed_10m"] as? Double

                var hi: Double?
                var lo: Double?
                if let daily = json["daily"] as? [String: Any] {
                    if let maxArr = daily["temperature_2m_max"] as? [Double], let first = maxArr.first { hi = first }
                    if let minArr = daily["temperature_2m_min"] as? [Double], let first = minArr.first { lo = first }
                }

                DispatchQueue.main.async {
                    self.temperature = temp
                    self.feelsLike = feels
                    self.weatherCode = code ?? 0
                    self.humidity = humid ?? 0
                    self.windSpeed = wind ?? 0
                    self.highTemp = hi
                    self.lowTemp = lo
                    self.onDisplayUpdate?()
                }
            }
        } catch {}
    }

    func weatherEmoji(code: Int) -> String {
        switch code {
        case 0: return "\u{2600}\u{FE0F}"       // Clear
        case 1, 2: return "\u{26C5}"            // Partly cloudy
        case 3: return "\u{2601}\u{FE0F}"       // Overcast
        case 45, 48: return "\u{1F32B}\u{FE0F}" // Fog
        case 51, 53, 55: return "\u{1F326}"     // Drizzle
        case 61, 63, 65: return "\u{1F327}"     // Rain
        case 66, 67: return "\u{1F327}"         // Freezing rain
        case 71, 73, 75, 77: return "\u{1F328}" // Snow
        case 80, 81, 82: return "\u{1F326}"     // Showers
        case 85, 86: return "\u{1F328}"         // Snow showers
        case 95: return "\u{26C8}"              // Thunderstorm
        case 96, 99: return "\u{26C8}"          // Thunderstorm + hail
        default: return "\u{2600}\u{FE0F}"
        }
    }

    func weatherDesc(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 61, 63: return "Rain"
        case 65: return "Heavy Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73: return "Snow"
        case 75: return "Heavy Snow"
        case 77: return "Snow Grains"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Hail"
        default: return "Unknown"
        }
    }

    func render() -> WidgetDisplayMode {
        guard let temp = temperature else {
            return .text(lastFetchFailed ? "Weather: Offline" : "Loading...")
        }

        let unit = config.useCelsius ? "C" : "F"
        var parts: [String] = []

        if config.showEmoji {
            parts.append(weatherEmoji(code: weatherCode))
        }

        parts.append(String(format: "%.0f\u{00B0}%@", temp, unit))

        if config.showFeelsLike, let feels = feelsLike {
            parts.append(String(format: "feels %.0f\u{00B0}", feels))
        }

        if config.showCity {
            parts.append(config.cityName)
        }

        return .text(parts.joined(separator: " "))
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "WEATHER", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let unit = config.useCelsius ? "C" : "F"

        if let temp = temperature {
            let emoji = weatherEmoji(code: weatherCode)
            let desc = weatherDesc(code: weatherCode)
            let condItem = NSMenuItem(title: "\(emoji) \(desc)", action: nil, keyEquivalent: "")
            condItem.isEnabled = false
            menu.addItem(condItem)

            let tempItem = NSMenuItem(title: String(format: "Temperature: %.1f\u{00B0}%@", temp, unit), action: nil, keyEquivalent: "")
            tempItem.isEnabled = false
            menu.addItem(tempItem)

            if let feels = feelsLike {
                let feelsItem = NSMenuItem(title: String(format: "Feels Like: %.1f\u{00B0}%@", feels, unit), action: nil, keyEquivalent: "")
                feelsItem.isEnabled = false
                menu.addItem(feelsItem)
            }

            let humidItem = NSMenuItem(title: "Humidity: \(humidity)%", action: nil, keyEquivalent: "")
            humidItem.isEnabled = false
            menu.addItem(humidItem)

            let windItem = NSMenuItem(title: String(format: "Wind: %.1f mph", windSpeed), action: nil, keyEquivalent: "")
            windItem.isEnabled = false
            menu.addItem(windItem)

            if let hi = highTemp, let lo = lowTemp {
                menu.addItem(NSMenuItem.separator())
                let rangeItem = NSMenuItem(title: String(format: "High: %.0f\u{00B0}  Low: %.0f\u{00B0}", hi, lo), action: nil, keyEquivalent: "")
                rangeItem.isEnabled = false
                menu.addItem(rangeItem)
            }
        } else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let cityItem = NSMenuItem(title: "Location: \(config.cityName)", action: nil, keyEquivalent: "")
        cityItem.isEnabled = false
        menu.addItem(cityItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
