import Cocoa
import CoreLocation

// MARK: - Config

struct WeatherConfig: Codable, Equatable {
    var displayMode: WeatherDisplayMode = .emojiTemp
    var useCelsius: Bool = false
    var showFeelsLike: Bool = false
    var showCity: Bool = true
    var showEmoji: Bool = true
    var showHumidity: Bool = false
    var showWind: Bool = false
    var showUV: Bool = false
    var showHiLo: Bool = true
    var showHourlyInDropdown: Bool = true
    var showDailyInDropdown: Bool = true
    var showDetailsInDropdown: Bool = true
    var refreshRate: TimeInterval = 120
    var accentColor: AccentPreset = .cyan
    var manualLat: Double? = 40.7128
    var manualLon: Double? = -74.0060
    var cityName: String = "New York"
    var windUnit: WindUnit = .mph
    var hourlyCount: Int = 12

    static let `default` = WeatherConfig()

    enum WeatherDisplayMode: String, Codable, Equatable {
        case emojiTemp     // ☀️ 72°F
        case tempOnly      // 72°F
        case detailed      // ☀️ 72°F feels 68° NYC
        case compact       // 72°
        case hiLo          // 78°/62°
    }

    enum AccentPreset: String, Codable, Equatable, CaseIterable {
        case blue, cyan, green, amber, purple, red, white
        var color: NSColor {
            switch self {
            case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
            case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
            case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
            case .amber:  return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
            case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
            case .red:    return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
    }

    enum WindUnit: String, Codable, Equatable {
        case mph, kmh, knots, ms
        var label: String {
            switch self {
            case .mph: return "mph"
            case .kmh: return "km/h"
            case .knots: return "kn"
            case .ms: return "m/s"
            }
        }
        var apiParam: String {
            switch self {
            case .mph: return "mph"
            case .kmh: return "kmh"
            case .knots: return "kn"
            case .ms: return "ms"
            }
        }
    }
}

// MARK: - Widget

class WeatherWidget: BaristaWidget {
    static let widgetID = "weather-current"
    static let displayName = "Current Weather"
    static let subtitle = "Temp, forecast, UV, wind & more"
    static let iconName = "cloud.sun"
    static let category = WidgetCategory.weather
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = WeatherConfig.default

    var config: WeatherConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0

    // Current conditions
    private(set) var temperature: Double?
    private(set) var feelsLike: Double?
    private(set) var weatherCode: Int = 0
    private(set) var humidity: Int = 0
    private(set) var windSpeed: Double = 0
    private(set) var windDirection: Int = 0
    private(set) var windGusts: Double = 0
    private(set) var pressure: Double = 0       // hPa
    private(set) var visibility: Double = 0     // km
    private(set) var uvIndex: Double = 0
    private(set) var dewPoint: Double = 0
    private(set) var cloudCover: Int = 0
    private(set) var precipitation: Double = 0  // mm
    private(set) var isDay: Bool = true

    // Daily
    private(set) var highTemp: Double?
    private(set) var lowTemp: Double?
    private(set) var sunrise: String = ""
    private(set) var sunset: String = ""
    private(set) var precipProb: Int = 0        // % daily max
    private(set) var uvMax: Double = 0

    // 7-day forecast
    private(set) var dailyForecast: [(date: String, code: Int, hi: Double, lo: Double, precip: Int)] = []

    // Hourly forecast
    private(set) var hourlyForecast: [(hour: String, code: Int, temp: Double, precip: Int)] = []

    // Temp history (from hourly past)
    private(set) var tempHistory: [Double] = []

    private(set) var lastFetchFailed = false
    private(set) var lastFetchTime: Date?

    required init(config: WeatherConfig) {
        self.config = config
    }

    func start() {
        currentTimerInterval = config.refreshRate
        fetchWeather()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.fetchWeather()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Data Fetch

    private func fetchWeather() {
        // Self-correcting timer
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.fetchWeather()
            }
        }

        let lat = config.manualLat ?? 40.7128
        let lon = config.manualLon ?? -74.0060
        let tempUnit = config.useCelsius ? "celsius" : "fahrenheit"
        let windUnit = config.windUnit.apiParam

        let currentParams = "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,surface_pressure,visibility,uv_index,dew_point_2m,cloud_cover,precipitation,is_day"
        let hourlyParams = "temperature_2m,weather_code,precipitation_probability"
        let dailyParams = "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max,uv_index_max"

        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=\(currentParams)&hourly=\(hourlyParams)&daily=\(dailyParams)&temperature_unit=\(tempUnit)&wind_speed_unit=\(windUnit)&forecast_days=7&past_hours=6&forecast_hours=24"

        guard let url = URL(string: urlStr) else { return }

        let cacheAge = min(max(config.refreshRate * 0.8, 30), 120)
        DataFetcher.shared.fetch(url: url, maxAge: cacheAge) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.lastFetchTime = Date()
                self.parseWeather(data: data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.temperature == nil { self.onDisplayUpdate?() }
                }
            }
        }
    }

    private func parseWeather(data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            // Current
            if let current = json["current"] as? [String: Any] {
                let temp = current["temperature_2m"] as? Double
                let feels = current["apparent_temperature"] as? Double
                let code = current["weather_code"] as? Int
                let humid = current["relative_humidity_2m"] as? Int
                let wind = current["wind_speed_10m"] as? Double
                let windDir = current["wind_direction_10m"] as? Int
                let gusts = current["wind_gusts_10m"] as? Double
                let press = current["surface_pressure"] as? Double
                let vis = current["visibility"] as? Double
                let uv = current["uv_index"] as? Double
                let dew = current["dew_point_2m"] as? Double
                let cloud = current["cloud_cover"] as? Int
                let precip = current["precipitation"] as? Double
                let day = current["is_day"] as? Int

                DispatchQueue.main.async {
                    self.temperature = temp
                    self.feelsLike = feels
                    self.weatherCode = code ?? 0
                    self.humidity = humid ?? 0
                    self.windSpeed = wind ?? 0
                    self.windDirection = windDir ?? 0
                    self.windGusts = gusts ?? 0
                    self.pressure = press ?? 0
                    self.visibility = (vis ?? 0) / 1000.0  // m -> km
                    self.uvIndex = uv ?? 0
                    self.dewPoint = dew ?? 0
                    self.cloudCover = cloud ?? 0
                    self.precipitation = precip ?? 0
                    self.isDay = (day ?? 1) == 1
                }
            }

            // Daily
            if let daily = json["daily"] as? [String: Any] {
                let maxArr = daily["temperature_2m_max"] as? [Double] ?? []
                let minArr = daily["temperature_2m_min"] as? [Double] ?? []
                let codes = daily["weather_code"] as? [Int] ?? []
                let dates = daily["time"] as? [String] ?? []
                let sunrises = daily["sunrise"] as? [String] ?? []
                let sunsets = daily["sunset"] as? [String] ?? []
                let precipProbs = daily["precipitation_probability_max"] as? [Int] ?? []
                let uvMaxes = daily["uv_index_max"] as? [Double] ?? []

                var forecasts: [(date: String, code: Int, hi: Double, lo: Double, precip: Int)] = []
                for i in 0..<min(dates.count, 7) {
                    let hi = i < maxArr.count ? maxArr[i] : 0
                    let lo = i < minArr.count ? minArr[i] : 0
                    let code = i < codes.count ? codes[i] : 0
                    let pp = i < precipProbs.count ? precipProbs[i] : 0
                    forecasts.append((date: dates[i], code: code, hi: hi, lo: lo, precip: pp))
                }

                DispatchQueue.main.async {
                    self.highTemp = maxArr.first
                    self.lowTemp = minArr.first
                    self.sunrise = Self.formatTimeFromISO(sunrises.first ?? "")
                    self.sunset = Self.formatTimeFromISO(sunsets.first ?? "")
                    self.precipProb = precipProbs.first ?? 0
                    self.uvMax = uvMaxes.first ?? 0
                    self.dailyForecast = forecasts
                }
            }

            // Hourly
            if let hourly = json["hourly"] as? [String: Any] {
                let times = hourly["time"] as? [String] ?? []
                let temps = hourly["temperature_2m"] as? [Double] ?? []
                let codes = hourly["weather_code"] as? [Int] ?? []
                let precips = hourly["precipitation_probability"] as? [Int] ?? []

                // Find current hour index
                let now = Date()
                let isoFmt = ISO8601DateFormatter()
                isoFmt.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                var currentIdx = 0
                for (i, t) in times.enumerated() {
                    if let d = isoFmt.date(from: t), d <= now { currentIdx = i }
                }

                // Past temps for history (last 6h)
                let pastStart = max(0, currentIdx - 6)
                let pastTemps = Array(temps[pastStart...min(currentIdx, temps.count - 1)])

                // Future hourly
                var hourlyArr: [(hour: String, code: Int, temp: Double, precip: Int)] = []
                let maxHours = min(config.hourlyCount, 24)
                for i in currentIdx..<min(currentIdx + maxHours, times.count) {
                    let hr = Self.formatHourFromISO(times[i])
                    let c = i < codes.count ? codes[i] : 0
                    let t = i < temps.count ? temps[i] : 0
                    let p = i < precips.count ? precips[i] : 0
                    hourlyArr.append((hour: hr, code: c, temp: t, precip: p))
                }

                DispatchQueue.main.async {
                    self.tempHistory = pastTemps
                    self.hourlyForecast = hourlyArr
                    self.onDisplayUpdate?()
                }
            }

        } catch {}
    }

    // MARK: - Time Formatters

    static func formatTimeFromISO(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        guard let date = fmt.date(from: iso) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }

    static func formatHourFromISO(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        guard let date = fmt.date(from: iso) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "ha"
        return df.string(from: date).lowercased()
    }

    static func formatDayFromISO(_ iso: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: iso) else { return iso }

        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }

        let df = DateFormatter()
        df.dateFormat = "EEE"
        return df.string(from: date)
    }

    // MARK: - Weather Descriptions

    func weatherEmoji(code: Int) -> String {
        switch code {
        case 0: return isDay ? "\u{2600}\u{FE0F}" : "\u{1F319}"
        case 1, 2: return isDay ? "\u{26C5}" : "\u{1F319}"
        case 3: return "\u{2601}\u{FE0F}"
        case 45, 48: return "\u{1F32B}\u{FE0F}"
        case 51, 53, 55: return "\u{1F326}"
        case 61, 63, 65: return "\u{1F327}"
        case 66, 67: return "\u{1F327}"
        case 71, 73, 75, 77: return "\u{1F328}"
        case 80, 81, 82: return "\u{1F326}"
        case 85, 86: return "\u{1F328}"
        case 95: return "\u{26C8}"
        case 96, 99: return "\u{26C8}"
        default: return "\u{2600}\u{FE0F}"
        }
    }

    func weatherDesc(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45: return "Fog"
        case 48: return "Rime Fog"
        case 51: return "Light Drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy Drizzle"
        case 61: return "Light Rain"
        case 63: return "Rain"
        case 65: return "Heavy Rain"
        case 66: return "Light Freezing Rain"
        case 67: return "Heavy Freezing Rain"
        case 71: return "Light Snow"
        case 73: return "Snow"
        case 75: return "Heavy Snow"
        case 77: return "Snow Grains"
        case 80: return "Light Showers"
        case 81: return "Showers"
        case 82: return "Heavy Showers"
        case 85: return "Light Snow Showers"
        case 86: return "Heavy Snow Showers"
        case 95: return "Thunderstorm"
        case 96: return "Thunderstorm + Hail"
        case 99: return "Severe Thunderstorm"
        default: return "Unknown"
        }
    }

    static func windDirectionStr(_ deg: Int) -> String {
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let idx = ((deg + 11) % 360) / 22
        return idx < dirs.count ? dirs[idx] : "N"
    }

    static func uvLabel(_ uv: Double) -> (String, NSColor) {
        if uv <= 2 { return ("Low", NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)) }
        if uv <= 5 { return ("Moderate", NSColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1)) }
        if uv <= 7 { return ("High", NSColor(red: 1.0, green: 0.50, blue: 0.15, alpha: 1)) }
        if uv <= 10 { return ("Very High", NSColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1)) }
        return ("Extreme", NSColor(red: 0.65, green: 0.20, blue: 0.80, alpha: 1))
    }

    var unitSuffix: String { config.useCelsius ? "C" : "F" }

    func formatTemp(_ t: Double) -> String {
        String(format: "%.0f\u{00B0}", t)
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        guard let temp = temperature else {
            return .text(lastFetchFailed ? "Weather: Offline" : "Loading...")
        }

        switch config.displayMode {
        case .emojiTemp:
            var parts: [String] = []
            if config.showEmoji { parts.append(weatherEmoji(code: weatherCode)) }
            parts.append("\(formatTemp(temp))\(unitSuffix)")
            if config.showCity { parts.append(config.cityName) }
            return .text(parts.joined(separator: " "))

        case .tempOnly:
            return .text("\(formatTemp(temp))\(unitSuffix)")

        case .detailed:
            return renderDetailedAttributed(temp: temp)

        case .compact:
            return .text(formatTemp(temp))

        case .hiLo:
            if let hi = highTemp, let lo = lowTemp {
                return .text("\(formatTemp(hi))/\(formatTemp(lo))")
            }
            return .text(formatTemp(temp))
        }
    }

    private func renderDetailedAttributed(temp: Double) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()

        if config.showEmoji {
            str.append(NSAttributedString(string: weatherEmoji(code: weatherCode) + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 12)
            ]))
        }

        str.append(NSAttributedString(string: "\(formatTemp(temp))\(unitSuffix)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: config.accentColor.color
        ]))

        if config.showFeelsLike, let feels = feelsLike {
            str.append(NSAttributedString(string: " feels \(formatTemp(feels))", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: Theme.textMuted
            ]))
        }

        if config.showHumidity {
            str.append(NSAttributedString(string: " \(humidity)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 0.7)
            ]))
        }

        if config.showWind {
            str.append(NSAttributedString(string: String(format: " %.0f%@", windSpeed, config.windUnit.label), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]))
        }

        if config.showUV && uvIndex > 0 {
            let (_, uvColor) = Self.uvLabel(uvIndex)
            str.append(NSAttributedString(string: String(format: " UV%.0f", uvIndex), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: uvColor.withAlphaComponent(0.7)
            ]))
        }

        if config.showHiLo, let hi = highTemp, let lo = lowTemp {
            str.append(NSAttributedString(string: " \(formatTemp(hi))/\(formatTemp(lo))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]))
        }

        if config.showCity {
            str.append(NSAttributedString(string: " \(config.cityName)", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: Theme.textMuted
            ]))
        }

        return .attributedText(str)
    }

    // MARK: - Dropdown (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "WEATHER", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())
        if let temp = temperature {
            let item = NSMenuItem(title: "\(weatherEmoji(code: weatherCode)) \(formatTemp(temp))\(unitSuffix) - \(weatherDesc(code: weatherCode))", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
}

// MARK: - Interactive Dropdown

extension WeatherWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 200 // header + conditions card + chips
        if config.showHourlyInDropdown && !hourlyForecast.isEmpty { h += 80 }
        if config.showDailyInDropdown && !dailyForecast.isEmpty {
            h += CGFloat(min(dailyForecast.count, 7)) * 22 + 24
        }
        if config.showDetailsInDropdown { h += 60 }
        h += SuperWidgetKit.panelHeight + 8
        h += 30 // footer
        return NSSize(width: 360, height: min(max(h, 300), 780))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 360
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)
        y = buildConditionsCard(in: container, y: y, pad: pad, cw: cw)
        y = buildInfoChips(in: container, y: y, pad: pad, cw: cw)

        if config.showHourlyInDropdown && !hourlyForecast.isEmpty {
            y = buildHourlyForecast(in: container, y: y, pad: pad, cw: cw)
        }

        if config.showDailyInDropdown && !dailyForecast.isEmpty {
            y = buildDailyForecast(in: container, y: y, pad: pad, cw: cw)
        }

        if config.showDetailsInDropdown {
            y = buildDetails(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let tempText = temperature.map { "\(formatTemp($0))\(unitSuffix)" } ?? "--"
        let feelsText = feelsLike.map { "\(formatTemp($0))\(unitSuffix)" } ?? "--"
        let rainText = precipProb > 0 || precipitation > 0 ? "\(precipProb)%" : "\(cloudCover)%"
        let (uvText, uvColor) = Self.uvLabel(uvIndex)
        let hiLo = highTemp.flatMap { hi in lowTemp.map { lo in "High/low \(formatTemp(hi))/\(formatTemp(lo))\(unitSuffix)" } } ?? "High/low unavailable"
        let sunText = (!sunrise.isEmpty && !sunset.isEmpty) ? "Sun \(sunrise)-\(sunset)" : "Sun times pending"
        let windText = "Wind \(Self.windDirectionStr(windDirection)) \(String(format: "%.0f", windSpeed)) \(config.windUnit.label)"

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Temp", value: tempText, color: config.accentColor.color),
                SuperWidgetMetric(label: "Feels", value: feelsText, color: Theme.textSecondary),
                SuperWidgetMetric(label: precipProb > 0 ? "Rain" : "Clouds", value: rainText, color: Theme.brandCyan),
                SuperWidgetMetric(label: "UV", value: String(format: "%.0f %@", uvIndex, uvText), color: uvColor)
            ],
            insights: [
                weatherDesc(code: weatherCode),
                hiLo,
                windText
            ],
            actions: [
                sunText,
                "Humidity \(humidity)%",
                "Refresh \(Int(config.refreshRate))s"
            ],
            accent: config.accentColor.color
        )
    }

    // MARK: Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: config.cityName)
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 200, height: 20)
        container.addSubview(title)

        let desc = NSTextField(labelWithString: weatherDesc(code: weatherCode))
        desc.font = .systemFont(ofSize: 10, weight: .medium)
        desc.textColor = Theme.textMuted; desc.alignment = .right
        desc.frame = NSRect(x: pad + cw - 140, y: y - 18, width: 140, height: 16)
        container.addSubview(desc)

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Conditions Card

    private func buildConditionsCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 70
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Large emoji
        let emoji = NSTextField(labelWithString: weatherEmoji(code: weatherCode))
        emoji.font = .systemFont(ofSize: 32)
        emoji.frame = NSRect(x: 12, y: (cardH - 38) / 2, width: 44, height: 38)
        card.addSubview(emoji)

        // Temperature (large)
        guard let temp = temperature else {
            y -= cardH + 8
            return y
        }
        let tempLabel = NSTextField(labelWithString: "\(formatTemp(temp))\(unitSuffix)")
        tempLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .heavy)
        tempLabel.textColor = config.accentColor.color
        tempLabel.frame = NSRect(x: 58, y: cardH - 40, width: 120, height: 34)
        card.addSubview(tempLabel)

        // Feels like
        if let feels = feelsLike {
            let feelsLabel = NSTextField(labelWithString: "Feels \(formatTemp(feels))\(unitSuffix)")
            feelsLabel.font = .systemFont(ofSize: 10, weight: .medium)
            feelsLabel.textColor = Theme.textMuted
            feelsLabel.frame = NSRect(x: 58, y: 8, width: 100, height: 14)
            card.addSubview(feelsLabel)
        }

        // Hi/Lo on right
        if let hi = highTemp, let lo = lowTemp {
            let hiLo = NSTextField(labelWithString: "\(formatTemp(hi)) / \(formatTemp(lo))")
            hiLo.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            hiLo.textColor = Theme.textSecondary
            hiLo.alignment = .right
            hiLo.frame = NSRect(x: cw - 110, y: cardH - 36, width: 100, height: 18)
            card.addSubview(hiLo)

            let hiLoLabel = NSTextField(labelWithString: "High / Low")
            hiLoLabel.font = .systemFont(ofSize: 8, weight: .semibold)
            hiLoLabel.textColor = Theme.textFaint; hiLoLabel.alignment = .right
            hiLoLabel.frame = NSRect(x: cw - 110, y: cardH - 50, width: 100, height: 12)
            card.addSubview(hiLoLabel)
        }

        // Sunrise/sunset
        if !sunrise.isEmpty && !sunset.isEmpty {
            let sunStr = "\u{2600}\u{FE0F} \(sunrise)  \u{1F319} \(sunset)"
            let sunLabel = NSTextField(labelWithString: sunStr)
            sunLabel.font = .systemFont(ofSize: 9, weight: .medium)
            sunLabel.textColor = Theme.textFaint; sunLabel.alignment = .right
            sunLabel.frame = NSRect(x: cw - 180, y: 8, width: 170, height: 14)
            card.addSubview(sunLabel)
        }

        y -= cardH + 8
        return y
    }

    // MARK: Info Chips

    private func buildInfoChips(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        var chips: [(String, String, NSColor)] = []
        chips.append(("\(humidity)%", "Humidity", NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1)))
        chips.append((String(format: "%.0f %@", windSpeed, config.windUnit.label), "Wind", Theme.textSecondary))

        let (uvLabel, uvColor) = Self.uvLabel(uvIndex)
        chips.append((String(format: "%.0f %@", uvIndex, uvLabel), "UV Index", uvColor))

        if precipProb > 0 || precipitation > 0 {
            chips.append(("\(precipProb)%", "Precip", NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)))
        } else {
            chips.append(("\(cloudCover)%", "Clouds", Theme.textMuted))
        }

        let chipW = (cw - CGFloat(chips.count - 1) * 6) / CGFloat(chips.count)
        for (i, (val, label, color)) in chips.enumerated() {
            let cx = pad + CGFloat(i) * (chipW + 6)
            let chip = makeCard(x: cx, y: y - 40, w: chipW, h: 40)
            container.addSubview(chip)

            let vl = NSTextField(labelWithString: val)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            vl.textColor = color; vl.alignment = .center
            vl.lineBreakMode = .byTruncatingTail
            vl.frame = NSRect(x: 2, y: 16, width: chipW - 4, height: 16)
            chip.addSubview(vl)

            let ll = NSTextField(labelWithString: label)
            ll.font = .systemFont(ofSize: 8, weight: .semibold)
            ll.textColor = Theme.textFaint; ll.alignment = .center
            ll.frame = NSRect(x: 2, y: 4, width: chipW - 4, height: 12)
            chip.addSubview(ll)
        }

        y -= 48
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Hourly Forecast

    private func buildHourlyForecast(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("HOURLY FORECAST")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        let hours = Array(hourlyForecast.prefix(config.hourlyCount))
        guard !hours.isEmpty else { return y }

        // Temperature sparkline from hourly data
        let temps = hours.map { $0.temp }
        let chartH: CGFloat = 36
        let chartBg = makeCard(x: pad, y: y - chartH, w: cw, h: chartH)
        container.addSubview(chartBg)

        if temps.count >= 2 {
            let img = SparklineRenderer.render(data: temps, width: cw, style: SparklineRenderer.Style(
                lineColor: config.accentColor.color,
                fillColor: config.accentColor.color.withAlphaComponent(0.08),
                lineWidth: 1.5, height: chartH, pointRadius: 1.5
            ))
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: cw, height: chartH))
            iv.image = img; iv.imageScaling = .scaleNone
            chartBg.addSubview(iv)

            // Min/max labels on chart
            if let hi = temps.max(), let lo = temps.min() {
                let hiLabel = NSTextField(labelWithString: formatTemp(hi))
                hiLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .bold)
                hiLabel.textColor = config.accentColor.color.withAlphaComponent(0.7)
                hiLabel.frame = NSRect(x: 4, y: chartH - 12, width: 30, height: 10)
                chartBg.addSubview(hiLabel)

                let loLabel = NSTextField(labelWithString: formatTemp(lo))
                loLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .bold)
                loLabel.textColor = Theme.textFaint
                loLabel.frame = NSRect(x: 4, y: 2, width: 30, height: 10)
                chartBg.addSubview(loLabel)
            }
        }
        y -= chartH + 4

        // Hour labels row
        let hourCount = min(hours.count, 8)
        let colW = cw / CGFloat(hourCount)
        for i in 0..<hourCount {
            let step = hours.count > 8 ? hours.count / hourCount : 1
            let idx = min(i * step, hours.count - 1)
            let hour = hours[idx]
            let cx = pad + CGFloat(i) * colW

            let hl = NSTextField(labelWithString: hour.hour)
            hl.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
            hl.textColor = Theme.textFaint; hl.alignment = .center
            hl.frame = NSRect(x: cx, y: y - 10, width: colW, height: 10)
            container.addSubview(hl)
        }
        y -= 16

        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Daily Forecast

    private func buildDailyForecast(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("7-DAY FORECAST")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 18

        // Find min/max across all days for bar scaling
        let allHi = dailyForecast.map { $0.hi }
        let allLo = dailyForecast.map { $0.lo }
        let minTemp = allLo.min() ?? 0
        let maxTemp = allHi.max() ?? 100
        let tempRange = max(maxTemp - minTemp, 1)

        for day in dailyForecast {
            let rowH: CGFloat = 20

            // Day name
            let dayName = Self.formatDayFromISO(day.date)
            let dayLabel = NSTextField(labelWithString: dayName)
            dayLabel.font = .systemFont(ofSize: 10, weight: dayName == "Today" ? .bold : .medium)
            dayLabel.textColor = dayName == "Today" ? Theme.textPrimary : Theme.textSecondary
            dayLabel.frame = NSRect(x: pad, y: y - rowH + 3, width: 60, height: 14)
            container.addSubview(dayLabel)

            // Emoji
            let emojiLabel = NSTextField(labelWithString: weatherEmoji(code: day.code))
            emojiLabel.font = .systemFont(ofSize: 11)
            emojiLabel.frame = NSRect(x: pad + 60, y: y - rowH + 2, width: 20, height: 16)
            container.addSubview(emojiLabel)

            // Lo temp
            let loLabel = NSTextField(labelWithString: formatTemp(day.lo))
            loLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            loLabel.textColor = Theme.textFaint; loLabel.alignment = .right
            loLabel.frame = NSRect(x: pad + 80, y: y - rowH + 3, width: 32, height: 14)
            container.addSubview(loLabel)

            // Temperature bar
            let barX: CGFloat = pad + 118
            let barMaxW: CGFloat = cw - 190
            let barH: CGFloat = 5
            let barY = y - rowH + 8

            let barBg = NSView(frame: NSRect(x: barX, y: barY, width: barMaxW, height: barH))
            barBg.wantsLayer = true
            barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            barBg.layer?.cornerRadius = 2.5
            container.addSubview(barBg)

            let loOffset = CGFloat((day.lo - minTemp) / tempRange) * barMaxW
            let hiOffset = CGFloat((day.hi - minTemp) / tempRange) * barMaxW
            let fillW = max(hiOffset - loOffset, 3)
            let fillBar = NSView(frame: NSRect(x: barX + loOffset, y: barY, width: fillW, height: barH))
            fillBar.wantsLayer = true
            fillBar.layer?.cornerRadius = 2.5
            // Gradient from cool to warm
            let midTemp = (day.hi + day.lo) / 2.0
            let warmth = CGFloat((midTemp - minTemp) / tempRange)
            let barColor = NSColor(
                red: 0.30 + 0.70 * warmth,
                green: 0.85 - 0.35 * warmth,
                blue: 0.95 - 0.65 * warmth,
                alpha: 0.7
            )
            fillBar.wantsLayer = true
            fillBar.layer?.backgroundColor = barColor.cgColor
            container.addSubview(fillBar)

            // Hi temp
            let hiLabel = NSTextField(labelWithString: formatTemp(day.hi))
            hiLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
            hiLabel.textColor = Theme.textSecondary
            hiLabel.frame = NSRect(x: pad + cw - 66, y: y - rowH + 3, width: 32, height: 14)
            container.addSubview(hiLabel)

            // Precip
            if day.precip > 0 {
                let pLabel = NSTextField(labelWithString: "\(day.precip)%")
                pLabel.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
                pLabel.textColor = NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 0.7)
                pLabel.alignment = .right
                pLabel.frame = NSRect(x: pad + cw - 30, y: y - rowH + 4, width: 28, height: 12)
                container.addSubview(pLabel)
            }

            y -= rowH + 2
        }

        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: Details

    private func buildDetails(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("DETAILS")
        header.frame = NSRect(x: pad, y: y - 12, width: 80, height: 12)
        container.addSubview(header)
        y -= 18

        let cardH: CGFloat = 40
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let items: [(String, String)] = [
            ("Dew Pt", "\(formatTemp(dewPoint))"),
            ("Pressure", String(format: "%.0f hPa", pressure)),
            ("Visibility", String(format: "%.0f km", visibility)),
            ("Gusts", String(format: "%.0f %@", windGusts, config.windUnit.label)),
        ]

        let colW = (cw - 16) / CGFloat(items.count)
        for (i, (label, val)) in items.enumerated() {
            let x = 8 + CGFloat(i) * colW

            let ll = NSTextField(labelWithString: label)
            ll.font = .systemFont(ofSize: 8, weight: .semibold)
            ll.textColor = Theme.textFaint
            ll.frame = NSRect(x: x, y: 22, width: colW, height: 10)
            card.addSubview(ll)

            let vl = NSTextField(labelWithString: val)
            vl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            vl.textColor = Theme.textSecondary
            vl.lineBreakMode = .byTruncatingTail
            vl.frame = NSRect(x: x, y: 6, width: colW, height: 14)
            card.addSubview(vl)
        }

        y -= cardH + 4
        return y
    }

    // MARK: Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        var parts: [String] = ["Open-Meteo"]
        if let lastFetch = lastFetchTime {
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            parts.append("Updated \(df.string(from: lastFetch))")
        }

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost; footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: UI Helpers

    private func makeCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return v
    }

    private func addDivider(in container: NSView, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.addSubview(d)
        y -= 8
    }
}

// MARK: - Declarative Config

extension WeatherWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Emoji + Temp", value: "emojiTemp"),
                (title: "Temp Only", value: "tempOnly"),
                (title: "Detailed", value: "detailed"),
                (title: "Compact", value: "compact"),
                (title: "Hi/Lo", value: "hiLo"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "emojiTemp" },
               set: { [weak self] in self?.config.displayMode = WeatherConfig.WeatherDisplayMode(rawValue: $0) ?? .emojiTemp }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "cyan" },
               set: { [weak self] in self?.config.accentColor = WeatherConfig.AccentPreset(rawValue: $0) ?? .cyan }),

            .section(title: "Menu Bar Info"),
            .toggle(label: "Show Emoji", key: "showEmoji",
                    get: { [weak self] in self?.config.showEmoji ?? true },
                    set: { [weak self] in self?.config.showEmoji = $0 }),
            .toggle(label: "Show City Name", key: "showCity",
                    get: { [weak self] in self?.config.showCity ?? true },
                    set: { [weak self] in self?.config.showCity = $0 }),
            .toggle(label: "Show Feels Like", key: "showFeelsLike",
                    get: { [weak self] in self?.config.showFeelsLike ?? false },
                    set: { [weak self] in self?.config.showFeelsLike = $0 }),
            .toggle(label: "Show Humidity", key: "showHumidity",
                    get: { [weak self] in self?.config.showHumidity ?? false },
                    set: { [weak self] in self?.config.showHumidity = $0 }),
            .toggle(label: "Show Wind", key: "showWind",
                    get: { [weak self] in self?.config.showWind ?? false },
                    set: { [weak self] in self?.config.showWind = $0 }),
            .toggle(label: "Show UV Index", key: "showUV",
                    get: { [weak self] in self?.config.showUV ?? false },
                    set: { [weak self] in self?.config.showUV = $0 }),
            .toggle(label: "Show Hi/Lo", key: "showHiLo",
                    get: { [weak self] in self?.config.showHiLo ?? true },
                    set: { [weak self] in self?.config.showHiLo = $0 }),

            .section(title: "Units"),
            .toggle(label: "Use Celsius", key: "useCelsius",
                    get: { [weak self] in self?.config.useCelsius ?? false },
                    set: { [weak self] in self?.config.useCelsius = $0 }),
            .picker(label: "Wind Unit", key: "windUnit", options: [
                (title: "mph", value: "mph"),
                (title: "km/h", value: "kmh"),
                (title: "Knots", value: "knots"),
                (title: "m/s", value: "ms"),
            ], get: { [weak self] in self?.config.windUnit.rawValue ?? "mph" },
               set: { [weak self] in self?.config.windUnit = WeatherConfig.WindUnit(rawValue: $0) ?? .mph }),

            .section(title: "Dropdown"),
            .toggle(label: "Show Hourly Forecast", key: "showHourlyInDropdown",
                    get: { [weak self] in self?.config.showHourlyInDropdown ?? true },
                    set: { [weak self] in self?.config.showHourlyInDropdown = $0 }),
            .toggle(label: "Show 7-Day Forecast", key: "showDailyInDropdown",
                    get: { [weak self] in self?.config.showDailyInDropdown ?? true },
                    set: { [weak self] in self?.config.showDailyInDropdown = $0 }),
            .toggle(label: "Show Details", key: "showDetailsInDropdown",
                    get: { [weak self] in self?.config.showDetailsInDropdown ?? true },
                    set: { [weak self] in self?.config.showDetailsInDropdown = $0 }),
            .slider(label: "Hourly Count", key: "hourlyCount", min: 6, max: 24, step: 3,
                    get: { [weak self] in Double(self?.config.hourlyCount ?? 12) },
                    set: { [weak self] in self?.config.hourlyCount = Int($0) },
                    format: "%.0f h"),

            .section(title: "Location"),
            .text(label: "City Name", key: "cityName", placeholder: "City name",
                  get: { [weak self] in self?.config.cityName ?? "" },
                  set: { [weak self] in self?.config.cityName = $0 }),
            .text(label: "Latitude", key: "manualLat", placeholder: "40.7128",
                  get: { [weak self] in self?.config.manualLat.map { String(format: "%.4f", $0) } ?? "" },
                  set: { [weak self] in self?.config.manualLat = Double($0) }),
            .text(label: "Longitude", key: "manualLon", placeholder: "-74.0060",
                  get: { [weak self] in self?.config.manualLon.map { String(format: "%.4f", $0) } ?? "" },
                  set: { [weak self] in self?.config.manualLon = Double($0) }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 60, max: 900, step: 30,
                    get: { [weak self] in self?.config.refreshRate ?? 120 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
        ]
    }
}
