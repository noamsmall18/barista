import Cocoa

struct SunriseSunsetConfig: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var showDayLength: Bool

    static let `default` = SunriseSunsetConfig(
        latitude: 40.7128,
        longitude: -74.0060,
        showDayLength: false
    )
}

class SunriseSunsetWidget: BaristaWidget {
    static let widgetID = "sunrise-sunset"
    static let displayName = "Sunrise/Sunset"
    static let subtitle = "Today's sunrise and sunset times"
    static let iconName = "sunrise"
    static let category = WidgetCategory.weather
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = SunriseSunsetConfig.default

    var config: SunriseSunsetConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 900 }

    private var timer: Timer?
    private(set) var sunriseTime: String = "--:--"
    private(set) var sunsetTime: String = "--:--"
    private(set) var dayLengthMinutes: Int = 0

    required init(config: SunriseSunsetConfig) {
        self.config = config
    }

    func start() {
        computeSunTimes()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.computeSunTimes()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func computeSunTimes() {
        // Astronomical computation for sunrise/sunset
        // Computes in UTC then converts to local timezone
        let cal = Calendar.current
        let now = Date()
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: now) ?? 1)
        let lat = config.latitude
        let lng = config.longitude

        let zenith = 90.833
        let d2r = Double.pi / 180
        let r2d = 180 / Double.pi
        let lngHour = lng / 15

        // Local timezone offset in hours
        let tzOffsetSeconds = TimeZone.current.secondsFromGMT(for: now)
        let tzOffset = Double(tzOffsetSeconds) / 3600.0

        // Rising
        let tRise = dayOfYear + (6 - lngHour) / 24
        let mRise = 0.9856 * tRise - 3.289
        var lRise = mRise + 1.916 * sin(mRise * d2r) + 0.020 * sin(2 * mRise * d2r) + 282.634
        lRise = lRise.truncatingRemainder(dividingBy: 360)
        if lRise < 0 { lRise += 360 }
        var raRise = r2d * atan(0.91764 * tan(lRise * d2r))
        raRise = raRise.truncatingRemainder(dividingBy: 360)
        if raRise < 0 { raRise += 360 }
        let lQuadRise = floor(lRise / 90) * 90
        let raQuadRise = floor(raRise / 90) * 90
        raRise += lQuadRise - raQuadRise
        raRise /= 15
        let sinDecRise = 0.39782 * sin(lRise * d2r)
        let cosDecRise = cos(asin(sinDecRise))
        let cosHRise = (cos(zenith * d2r) - sinDecRise * sin(lat * d2r)) / (cosDecRise * cos(lat * d2r))

        if cosHRise <= 1 && cosHRise >= -1 {
            let hRise = 360 - r2d * acos(cosHRise)
            let utRise = (hRise / 15 + raRise - 0.06571 * tRise - 6.622).truncatingRemainder(dividingBy: 24)
            // Convert UTC to local time using actual timezone offset
            let localRise = (utRise + tzOffset + 24).truncatingRemainder(dividingBy: 24)
            let riseH = Int(localRise)
            let riseM = Int((localRise - Double(riseH)) * 60)
            let riseAmPm = riseH >= 12 ? "PM" : "AM"
            let riseH12 = riseH == 0 ? 12 : (riseH > 12 ? riseH - 12 : riseH)
            sunriseTime = String(format: "%d:%02d %@", riseH12, riseM, riseAmPm)

            // Setting
            let tSet = dayOfYear + (18 - lngHour) / 24
            let mSet = 0.9856 * tSet - 3.289
            var lSet = mSet + 1.916 * sin(mSet * d2r) + 0.020 * sin(2 * mSet * d2r) + 282.634
            lSet = lSet.truncatingRemainder(dividingBy: 360)
            if lSet < 0 { lSet += 360 }
            var raSet = r2d * atan(0.91764 * tan(lSet * d2r))
            raSet = raSet.truncatingRemainder(dividingBy: 360)
            if raSet < 0 { raSet += 360 }
            let lQuadSet = floor(lSet / 90) * 90
            let raQuadSet = floor(raSet / 90) * 90
            raSet += lQuadSet - raQuadSet
            raSet /= 15
            let sinDecSet = 0.39782 * sin(lSet * d2r)
            let cosDecSet = cos(asin(sinDecSet))
            let cosHSet = (cos(zenith * d2r) - sinDecSet * sin(lat * d2r)) / (cosDecSet * cos(lat * d2r))

            if cosHSet <= 1 && cosHSet >= -1 {
                let hSet = r2d * acos(cosHSet)
                let utSet = (hSet / 15 + raSet - 0.06571 * tSet - 6.622).truncatingRemainder(dividingBy: 24)
                var localSet = (utSet + tzOffset + 24).truncatingRemainder(dividingBy: 24)
                let setH = Int(localSet)
                let setM = Int((localSet - Double(setH)) * 60)
                let setAmPm = setH >= 12 ? "PM" : "AM"
                let setH12 = setH == 0 ? 12 : (setH > 12 ? setH - 12 : setH)
                sunsetTime = String(format: "%d:%02d %@", setH12, setM, setAmPm)

                // Fix negative day length when sunset wraps around midnight
                if localSet < localRise { localSet += 24 }
                dayLengthMinutes = Int((localSet - localRise) * 60)
            }
        }
    }

    func render() -> WidgetDisplayMode {
        if config.showDayLength {
            let h = dayLengthMinutes / 60
            let m = dayLengthMinutes % 60
            return .text("\u{2600}\u{FE0F} \(h)h \(m)m daylight")
        }
        return .text("\u{1F305} \(sunriseTime)  \u{1F307} \(sunsetTime)")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "SUNRISE / SUNSET", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let items: [(String, String)] = [
            ("Sunrise", sunriseTime),
            ("Sunset", sunsetTime),
            ("Day Length", "\(dayLengthMinutes / 60)h \(dayLengthMinutes % 60)m"),
        ]
        for (label, value) in items {
            let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
