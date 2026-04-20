import Cocoa

struct ForexConfig: Codable, Equatable {
    var baseCurrency: String
    var targetCurrency: String
    var decimalPlaces: Int

    static let `default` = ForexConfig(
        baseCurrency: "USD",
        targetCurrency: "EUR",
        decimalPlaces: 4
    )
}

class ForexWidget: BaristaWidget {
    static let widgetID = "forex-rate"
    static let displayName = "Forex Rate"
    static let subtitle = "Live currency exchange rates"
    static let iconName = "dollarsign.circle"
    static let category = WidgetCategory.finance
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = ForexConfig.default

    var config: ForexConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 900 }

    private var timer: Timer?
    private(set) var rate: Double = 0
    private(set) var lastUpdated: String = ""
    private(set) var lastFetchFailed = false

    required init(config: ForexConfig) {
        self.config = config
    }

    func start() {
        fetchRate()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.fetchRate()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchRate() {
        let base = config.baseCurrency.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let target = config.targetCurrency.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://api.frankfurter.app/latest?from=\(base)&to=\(target)"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = json["rates"] as? [String: Double],
                  let r = rates[self.config.targetCurrency] else {
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.rate == 0 { self.onDisplayUpdate?() }
                }
                return
            }

            DispatchQueue.main.async {
                self.lastFetchFailed = false
                self.rate = r
                self.lastUpdated = json["date"] as? String ?? ""
                self.onDisplayUpdate?()
            }
        }.resume()
    }

    func render() -> WidgetDisplayMode {
        guard rate > 0 else {
            return .text(lastFetchFailed ? "Forex: Offline" : "\(config.baseCurrency)/\(config.targetCurrency): --")
        }
        let fmt = String(format: "%.\(config.decimalPlaces)f", rate)
        return .text("\(config.baseCurrency)/\(config.targetCurrency) \(fmt)")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "FOREX", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let pairItem = NSMenuItem(title: "\(config.baseCurrency) / \(config.targetCurrency)", action: nil, keyEquivalent: "")
        pairItem.isEnabled = false
        menu.addItem(pairItem)

        let rateStr = String(format: "%.\(config.decimalPlaces)f", rate)
        let rateItem = NSMenuItem(title: "Rate: \(rateStr)", action: nil, keyEquivalent: "")
        rateItem.isEnabled = false
        menu.addItem(rateItem)

        let inverseStr = rate > 0 ? String(format: "%.\(config.decimalPlaces)f", 1.0 / rate) : "--"
        let inverseItem = NSMenuItem(title: "Inverse: \(inverseStr)", action: nil, keyEquivalent: "")
        inverseItem.isEnabled = false
        menu.addItem(inverseItem)

        if !lastUpdated.isEmpty {
            let dateItem = NSMenuItem(title: "As of: \(lastUpdated)", action: nil, keyEquivalent: "")
            dateItem.isEnabled = false
            menu.addItem(dateItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
