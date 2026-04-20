import Cocoa

struct F1StandingsConfig: Codable, Equatable {
    static let `default` = F1StandingsConfig()
}

class F1StandingsWidget: BaristaWidget, Cycleable {
    static let widgetID = "f1-standings"
    static let displayName = "F1 Standings"
    static let subtitle = "Current F1 driver championship standings"
    static let iconName = "flag.checkered"
    static let category = WidgetCategory.sports
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = F1StandingsConfig.default

    var config: F1StandingsConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 3600 }

    private var timer: Timer?
    private(set) var drivers: [DriverStanding] = []
    private(set) var displayIndex: Int = 0
    private(set) var lastFetchFailed = false

    struct DriverStanding {
        var position: String
        var familyName: String
        var constructor: String
        var points: String
    }

    // MARK: - Cycleable

    var itemCount: Int { min(max(drivers.count, 1), 5) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 5 }

    func cycleNext() {
        guard !drivers.isEmpty else { return }
        displayIndex = (displayIndex + 1) % min(drivers.count, 5)
        onDisplayUpdate?()
    }

    required init(config: F1StandingsConfig) {
        self.config = config
    }

    func start() {
        fetchStandings()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.fetchStandings()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Fetch

    private func fetchStandings() {
        guard let url = URL(string: "https://api.jolpi.ca/ergast/f1/current/driverStandings.json") else { return }

        DataFetcher.shared.fetch(url: url, maxAge: 3600) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.parseStandings(data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.drivers.isEmpty { self.onDisplayUpdate?() }
                }
            }
        }
    }

    private func parseStandings(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mrData = json["MRData"] as? [String: Any],
              let standingsTable = mrData["StandingsTable"] as? [String: Any],
              let standingsLists = standingsTable["StandingsLists"] as? [[String: Any]],
              let firstList = standingsLists.first,
              let driverStandings = firstList["DriverStandings"] as? [[String: Any]] else {
            DispatchQueue.main.async {
                self.lastFetchFailed = true
                if self.drivers.isEmpty { self.onDisplayUpdate?() }
            }
            return
        }

        var parsed: [DriverStanding] = []
        for standing in driverStandings {
            let position = standing["position"] as? String ?? "?"
            let points = standing["points"] as? String ?? "0"
            let driver = standing["Driver"] as? [String: Any]
            let familyName = driver?["familyName"] as? String ?? "?"
            let constructors = standing["Constructors"] as? [[String: Any]]
            let constructor = constructors?.first?["name"] as? String ?? "?"

            parsed.append(DriverStanding(
                position: position,
                familyName: familyName,
                constructor: constructor,
                points: points
            ))
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastFetchFailed = false
            self?.drivers = parsed
            if self?.displayIndex ?? 0 >= min(parsed.count, 5) {
                self?.displayIndex = 0
            }
            self?.onDisplayUpdate?()
        }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        guard !drivers.isEmpty else {
            return .text(lastFetchFailed ? "F1: Offline" : "F1 Loading...")
        }

        let idx = displayIndex % min(drivers.count, 5)
        let d = drivers[idx]
        return .text("F1 #\(d.position) \(d.familyName) \(d.points)pts")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "F1 STANDINGS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if drivers.isEmpty {
            let noData = NSMenuItem(title: lastFetchFailed ? "Failed to load standings" : "Loading...", action: nil, keyEquivalent: "")
            noData.isEnabled = false
            menu.addItem(noData)
        } else {
            let top10 = drivers.prefix(10)
            for d in top10 {
                let item = NSMenuItem(title: "  #\(d.position) \(d.familyName) - \(d.constructor) - \(d.points)pts", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if drivers.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle drivers", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
