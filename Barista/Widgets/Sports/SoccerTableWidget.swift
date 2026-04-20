import Cocoa

struct SoccerTableConfig: Codable, Equatable {
    var apiKey: String
    var competitionCode: String

    static let `default` = SoccerTableConfig(
        apiKey: "",
        competitionCode: "PL"
    )
}

class SoccerTableWidget: BaristaWidget, Cycleable {
    static let widgetID = "soccer-table"
    static let displayName = "Soccer Table"
    static let subtitle = "League standings from football-data.org"
    static let iconName = "soccerball"
    static let category = WidgetCategory.sports
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = SoccerTableConfig.default

    var config: SoccerTableConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 3600 }

    private var timer: Timer?
    private(set) var teams: [TeamStanding] = []
    private(set) var displayIndex: Int = 0
    private(set) var lastFetchFailed = false

    struct TeamStanding {
        var position: Int
        var shortName: String
        var points: Int
        var won: Int
        var draw: Int
        var lost: Int
        var goalsFor: Int
        var goalsAgainst: Int
    }

    // MARK: - Cycleable

    var itemCount: Int { min(max(teams.count, 1), 5) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 5 }

    func cycleNext() {
        guard !teams.isEmpty else { return }
        displayIndex = (displayIndex + 1) % min(teams.count, 5)
        onDisplayUpdate?()
    }

    required init(config: SoccerTableConfig) {
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
        guard !config.apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.teams = []
                self.onDisplayUpdate?()
            }
            return
        }

        let urlStr = "https://api.football-data.org/v4/competitions/\(config.competitionCode)/standings"
        guard let url = URL(string: urlStr) else { return }

        let request = DataFetcher.FetchRequest(
            url: url,
            headers: ["X-Auth-Token": config.apiKey],
            maxAge: 3600
        )

        DataFetcher.shared.fetch(request) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.parseStandings(data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.teams.isEmpty { self.onDisplayUpdate?() }
                }
            }
        }
    }

    private func parseStandings(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let standings = json["standings"] as? [[String: Any]],
              let firstStanding = standings.first,
              let table = firstStanding["table"] as? [[String: Any]] else {
            DispatchQueue.main.async {
                self.lastFetchFailed = true
                if self.teams.isEmpty { self.onDisplayUpdate?() }
            }
            return
        }

        var parsed: [TeamStanding] = []
        for entry in table {
            let position = entry["position"] as? Int ?? 0
            let team = entry["team"] as? [String: Any]
            let shortName = team?["shortName"] as? String ?? "?"
            let points = entry["points"] as? Int ?? 0
            let won = entry["won"] as? Int ?? 0
            let draw = entry["draw"] as? Int ?? 0
            let lost = entry["lost"] as? Int ?? 0
            let goalsFor = entry["goalsFor"] as? Int ?? 0
            let goalsAgainst = entry["goalsAgainst"] as? Int ?? 0

            parsed.append(TeamStanding(
                position: position,
                shortName: shortName,
                points: points,
                won: won,
                draw: draw,
                lost: lost,
                goalsFor: goalsFor,
                goalsAgainst: goalsAgainst
            ))
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastFetchFailed = false
            self?.teams = parsed
            if self?.displayIndex ?? 0 >= min(parsed.count, 5) {
                self?.displayIndex = 0
            }
            self?.onDisplayUpdate?()
        }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        guard !config.apiKey.isEmpty else {
            return .text("Soccer: Set API Key")
        }

        guard !teams.isEmpty else {
            return .text(lastFetchFailed ? "Soccer: Offline" : "Soccer Loading...")
        }

        let idx = displayIndex % min(teams.count, 5)
        let t = teams[idx]
        return .text("#\(t.position) \(t.shortName) \(t.points)pts")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "SOCCER TABLE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if config.apiKey.isEmpty {
            let noKey = NSMenuItem(title: "API key required (football-data.org)", action: nil, keyEquivalent: "")
            noKey.isEnabled = false
            menu.addItem(noKey)
        } else if teams.isEmpty {
            let noData = NSMenuItem(title: lastFetchFailed ? "Failed to load standings" : "Loading...", action: nil, keyEquivalent: "")
            noData.isEnabled = false
            menu.addItem(noData)
        } else {
            let top10 = teams.prefix(10)
            for t in top10 {
                let gd = t.goalsFor - t.goalsAgainst
                let gdStr = gd >= 0 ? "+\(gd)" : "\(gd)"
                let item = NSMenuItem(
                    title: "  #\(t.position) \(t.shortName) - \(t.points)pts  W\(t.won) D\(t.draw) L\(t.lost)  GD:\(gdStr)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if teams.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle teams", action: nil, keyEquivalent: "")
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
