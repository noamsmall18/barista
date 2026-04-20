import Cocoa

struct LiveScoresConfig: Codable, Equatable {
    var sport: String // "basketball", "football", "baseball", "hockey", "soccer"
    var league: String // "nba", "nfl", "mlb", "nhl", "eng.1"

    static let `default` = LiveScoresConfig(
        sport: "basketball",
        league: "nba"
    )
}

class LiveScoresWidget: BaristaWidget, Cycleable {
    static let widgetID = "live-scores"
    static let displayName = "Live Scores"
    static let subtitle = "Real-time sports scores from ESPN"
    static let iconName = "sportscourt"
    static let category = WidgetCategory.sports
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = LiveScoresConfig.default

    var config: LiveScoresConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?
    private(set) var games: [GameInfo] = []
    private(set) var displayIndex: Int = 0
    private(set) var lastFetchFailed = false

    struct GameInfo {
        var homeTeam: String
        var awayTeam: String
        var homeScore: Int
        var awayScore: Int
        var status: String // "In Progress", "Final", "Scheduled"
        var detail: String // "Q4 2:31", "Final", "7:30 PM"
        var isLive: Bool
    }

    // MARK: - Cycleable

    var itemCount: Int { max(games.count, 1) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 5 }

    func cycleNext() {
        guard !games.isEmpty else { return }
        displayIndex = (displayIndex + 1) % games.count
        onDisplayUpdate?()
    }

    required init(config: LiveScoresConfig) {
        self.config = config
    }

    func start() {
        fetchScores()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchScores()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchScores() {
        let safeSport = config.sport.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let safeLeague = config.league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let urlStr = "https://site.api.espn.com/apis/site/v2/sports/\(safeSport)/\(safeLeague)/scoreboard"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = json["events"] as? [[String: Any]] else {
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.games.isEmpty { self.onDisplayUpdate?() }
                }
                return
            }

            var parsed: [GameInfo] = []
            for event in events {
                guard let competitions = event["competitions"] as? [[String: Any]],
                      let comp = competitions.first,
                      let competitors = comp["competitors"] as? [[String: Any]],
                      competitors.count >= 2,
                      let status = event["status"] as? [String: Any],
                      let statusType = status["type"] as? [String: Any] else { continue }

                let home = competitors.first { ($0["homeAway"] as? String) == "home" } ?? competitors[0]
                let away = competitors.first { ($0["homeAway"] as? String) == "away" } ?? competitors[1]

                let homeTeam = (home["team"] as? [String: Any])?["abbreviation"] as? String ?? "?"
                let awayTeam = (away["team"] as? [String: Any])?["abbreviation"] as? String ?? "?"
                let homeScore = Int(home["score"] as? String ?? "0") ?? 0
                let awayScore = Int(away["score"] as? String ?? "0") ?? 0
                let state = statusType["state"] as? String ?? "pre"
                let detail = (status["type"] as? [String: Any])?["shortDetail"] as? String
                    ?? statusType["description"] as? String ?? ""

                parsed.append(GameInfo(
                    homeTeam: homeTeam,
                    awayTeam: awayTeam,
                    homeScore: homeScore,
                    awayScore: awayScore,
                    status: statusType["description"] as? String ?? "",
                    detail: detail,
                    isLive: state == "in"
                ))
            }

            DispatchQueue.main.async { [weak self] in
                self?.lastFetchFailed = false
                self?.games = parsed
                if self?.displayIndex ?? 0 >= parsed.count {
                    self?.displayIndex = 0
                }
                self?.onDisplayUpdate?()
            }
        }.resume()
    }

    func render() -> WidgetDisplayMode {
        guard !games.isEmpty else {
            return .text(lastFetchFailed ? "Scores: Offline" : "No games today")
        }

        let game = games[displayIndex % games.count]
        let text = "\(game.awayTeam) \(game.awayScore) - \(game.homeTeam) \(game.homeScore) \(game.detail)"
        let color: NSColor = game.isLive ? Theme.green : Theme.textPrimary
        let weight: NSFont.Weight = game.isLive ? .medium : .regular

        if text.count > 30 {
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: weight)
            ])
            return .scrollingText(attr, width: 200)
        }

        if game.isLive {
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: weight)
            ])
            return .attributedText(attr)
        }
        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let leagueName = config.league.uppercased()
        let header = NSMenuItem(title: "\(leagueName) SCORES", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let live = games.filter { $0.isLive }
        let final_ = games.filter { $0.status.lowercased().contains("final") }
        let upcoming = games.filter { !$0.isLive && !$0.status.lowercased().contains("final") }

        if !live.isEmpty {
            let liveHeader = NSMenuItem(title: "LIVE", action: nil, keyEquivalent: "")
            liveHeader.isEnabled = false
            menu.addItem(liveHeader)
            for g in live {
                let item = NSMenuItem(title: "  \(g.awayTeam) \(g.awayScore) - \(g.homeTeam) \(g.homeScore)  \(g.detail)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        if !final_.isEmpty {
            let finalHeader = NSMenuItem(title: "FINAL", action: nil, keyEquivalent: "")
            finalHeader.isEnabled = false
            menu.addItem(finalHeader)
            for g in final_ {
                let item = NSMenuItem(title: "  \(g.awayTeam) \(g.awayScore) - \(g.homeTeam) \(g.homeScore)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        if !upcoming.isEmpty {
            let upHeader = NSMenuItem(title: "UPCOMING", action: nil, keyEquivalent: "")
            upHeader.isEnabled = false
            menu.addItem(upHeader)
            for g in upcoming {
                let item = NSMenuItem(title: "  \(g.awayTeam) vs \(g.homeTeam)  \(g.detail)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if games.isEmpty {
            let noGames = NSMenuItem(title: "No games today", action: nil, keyEquivalent: "")
            noGames.isEnabled = false
            menu.addItem(noGames)
        }

        if games.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle games", action: nil, keyEquivalent: "")
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
