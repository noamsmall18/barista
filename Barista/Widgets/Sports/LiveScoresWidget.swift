import Cocoa

// MARK: - Config

struct LiveScoresConfig: Codable, Equatable {
    var sport: String
    var league: String
    var displayMode: ScoresDisplayMode
    var favoriteTeam: String
    var showCompleted: Bool
    var showUpcoming: Bool
    var showGameTime: Bool
    var showVenue: Bool
    var showOdds: Bool
    var refreshRate: TimeInterval
    var liveRefreshRate: TimeInterval
    var autoFastRefresh: Bool
    var accentColor: ScoresAccentPreset
    var colorMode: ScoresColorMode
    var cycleSpeed: TimeInterval
    var showRecords: Bool

    static let `default` = LiveScoresConfig(
        sport: "basketball",
        league: "nba",
        displayMode: .scores,
        favoriteTeam: "",
        showCompleted: true,
        showUpcoming: true,
        showGameTime: true,
        showVenue: false,
        showOdds: false,
        refreshRate: 30,
        liveRefreshRate: 10,
        autoFastRefresh: true,
        accentColor: .green,
        colorMode: .dynamic,
        cycleSpeed: 5,
        showRecords: false
    )

    enum ScoresDisplayMode: String, Codable, Equatable {
        case scores    // "NYK 102 - BOS 98 Q4"
        case compact   // "NYK 102-98"
        case ticker    // cycle through games
        case favoriteOnly // only show favorite team's game
        case record    // "NYK 45-37"
    }

    enum ScoresAccentPreset: String, Codable, Equatable, CaseIterable {
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

    enum ScoresColorMode: String, Codable, Equatable {
        case dynamic // winning score green, losing red
        case fixed   // always uses accentColor
    }

    // Map sport+league to ESPN path segments
    static let leagueMap: [(title: String, sport: String, league: String)] = [
        ("NBA", "basketball", "nba"),
        ("NFL", "football", "nfl"),
        ("MLB", "baseball", "mlb"),
        ("NHL", "hockey", "nhl"),
        ("EPL", "soccer", "eng.1"),
        ("MLS", "soccer", "usa.1"),
        ("La Liga", "soccer", "esp.1"),
        ("Serie A", "soccer", "ita.1"),
        ("Bundesliga", "soccer", "ger.1"),
        ("Ligue 1", "soccer", "fra.1"),
        ("NCAAF", "football", "college-football"),
        ("NCAAB", "basketball", "mens-college-basketball"),
    ]
}

// MARK: - Game Info

struct GameInfo {
    var homeTeam: String
    var awayTeam: String
    var homeFullName: String
    var awayFullName: String
    var homeScore: Int
    var awayScore: Int
    var homeRecord: String
    var awayRecord: String
    var status: GameStatus
    var detail: String          // "Q4 2:31", "Final", "7:30 PM ET"
    var shortDetail: String     // "Q4 2:31"
    var venue: String
    var odds: String
    var broadcast: String
    var startTime: Date?

    enum GameStatus: String {
        case pregame = "pre"
        case live = "in"
        case final_ = "post"
        case postponed = "postponed"
        case delayed = "delayed"
        case canceled = "canceled"

        var isLive: Bool { self == .live }
        var isFinal: Bool { self == .final_ }
        var isPregame: Bool { self == .pregame }
    }

    var isLive: Bool { status.isLive }
    var isFinal: Bool { status.isFinal }
    var isPregame: Bool { status.isPregame }

    var winningTeam: String? {
        guard isFinal || isLive else { return nil }
        if homeScore > awayScore { return homeTeam }
        if awayScore > homeScore { return awayTeam }
        return nil
    }
}

// MARK: - Widget

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
    var refreshInterval: TimeInterval? { effectiveRefreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    private(set) var games: [GameInfo] = []
    private(set) var filteredGames: [GameInfo] = []
    private(set) var displayIndex: Int = 0
    private(set) var lastFetchFailed = false
    private(set) var hasAnyLiveGames = false
    private(set) var lastFetchTime: Date?

    /// Effective refresh rate: faster when live games exist.
    private var effectiveRefreshRate: TimeInterval {
        if config.autoFastRefresh && hasAnyLiveGames {
            return config.liveRefreshRate
        }
        return config.refreshRate
    }

    // MARK: - Cycleable

    var itemCount: Int { max(filteredGames.count, 1) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { config.cycleSpeed }

    func cycleNext() {
        guard !filteredGames.isEmpty else { return }
        displayIndex = (displayIndex + 1) % filteredGames.count
        onDisplayUpdate?()
    }

    required init(config: LiveScoresConfig) {
        self.config = config
    }

    func start() {
        fetchScores()
        let rate = effectiveRefreshRate
        currentTimerInterval = rate
        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.tick()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Self-correcting timer: adjust if refresh rate changed
        let desired = effectiveRefreshRate
        if currentTimerInterval != desired {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = desired
            timer = Timer.scheduledTimer(withTimeInterval: desired, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        fetchScores()
    }

    // MARK: - ESPN API

    private func fetchScores() {
        let safeSport = config.sport.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let safeLeague = config.league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let urlStr = "https://site.api.espn.com/apis/site/v2/sports/\(safeSport)/\(safeLeague)/scoreboard"
        guard let url = URL(string: urlStr) else { return }

        let maxAge: TimeInterval = hasAnyLiveGames ? min(config.liveRefreshRate * 0.8, 8) : min(config.refreshRate * 0.8, 20)
        DataFetcher.shared.fetch(url: url, maxAge: maxAge) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.games.isEmpty { self.onDisplayUpdate?() }
                }
            case .success(let data):
                self.parseScoreboard(data)
            }
        }
    }

    private func parseScoreboard(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            DispatchQueue.main.async { [weak self] in
                self?.lastFetchFailed = true
                if self?.games.isEmpty == true { self?.onDisplayUpdate?() }
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

            let homeTeamDict = home["team"] as? [String: Any]
            let awayTeamDict = away["team"] as? [String: Any]

            let homeAbbr = homeTeamDict?["abbreviation"] as? String ?? "?"
            let awayAbbr = awayTeamDict?["abbreviation"] as? String ?? "?"
            let homeName = homeTeamDict?["displayName"] as? String ?? homeAbbr
            let awayName = awayTeamDict?["displayName"] as? String ?? awayAbbr

            let homeScore = Int(home["score"] as? String ?? "0") ?? 0
            let awayScore = Int(away["score"] as? String ?? "0") ?? 0

            // Records
            let homeRecords = home["records"] as? [[String: Any]]
            let awayRecords = away["records"] as? [[String: Any]]
            let homeRecord = homeRecords?.first?["summary"] as? String ?? ""
            let awayRecord = awayRecords?.first?["summary"] as? String ?? ""

            // Status
            let stateStr = statusType["state"] as? String ?? "pre"
            let descr = statusType["description"] as? String ?? ""
            let shortDetail = statusType["shortDetail"] as? String ?? descr

            var gameStatus: GameInfo.GameStatus
            let descrLower = descr.lowercased()
            if descrLower.contains("postponed") {
                gameStatus = .postponed
            } else if descrLower.contains("delayed") {
                gameStatus = .delayed
            } else if descrLower.contains("canceled") || descrLower.contains("cancelled") {
                gameStatus = .canceled
            } else {
                switch stateStr {
                case "in": gameStatus = .live
                case "post": gameStatus = .final_
                default: gameStatus = .pregame
                }
            }

            // Venue
            let venue = (comp["venue"] as? [String: Any])?["fullName"] as? String ?? ""

            // Odds
            var oddsStr = ""
            if let oddsArr = comp["odds"] as? [[String: Any]], let firstOdds = oddsArr.first {
                oddsStr = firstOdds["details"] as? String ?? ""
            }

            // Broadcast
            var broadcastStr = ""
            if let broadcasts = comp["broadcasts"] as? [[String: Any]], let first = broadcasts.first,
               let names = first["names"] as? [String], let firstName = names.first {
                broadcastStr = firstName
            }

            // Start time
            var startTime: Date?
            if let dateStr = event["date"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                startTime = formatter.date(from: dateStr)
                if startTime == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    startTime = formatter.date(from: dateStr)
                }
            }

            parsed.append(GameInfo(
                homeTeam: homeAbbr,
                awayTeam: awayAbbr,
                homeFullName: homeName,
                awayFullName: awayName,
                homeScore: homeScore,
                awayScore: awayScore,
                homeRecord: homeRecord,
                awayRecord: awayRecord,
                status: gameStatus,
                detail: descr,
                shortDetail: shortDetail,
                venue: venue,
                odds: oddsStr,
                broadcast: broadcastStr,
                startTime: startTime
            ))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastFetchFailed = false
            self.lastFetchTime = Date()
            self.games = parsed
            self.hasAnyLiveGames = parsed.contains { $0.isLive }
            self.applyFilters()
            if self.displayIndex >= self.filteredGames.count {
                self.displayIndex = 0
            }
            self.onDisplayUpdate?()
        }
    }

    // MARK: - Filtering

    private func applyFilters() {
        var result = games

        // Filter by completed/upcoming toggles
        if !config.showCompleted {
            result = result.filter { !$0.isFinal }
        }
        if !config.showUpcoming {
            result = result.filter { !$0.isPregame }
        }

        // Favorite-only mode
        if config.displayMode == .favoriteOnly && !config.favoriteTeam.isEmpty {
            let fav = config.favoriteTeam.uppercased()
            let favFiltered = result.filter { $0.homeTeam.uppercased() == fav || $0.awayTeam.uppercased() == fav }
            if !favFiltered.isEmpty {
                result = favFiltered
            }
        }

        // Sort: live first, then upcoming, then final
        result.sort { a, b in
            let orderA = a.isLive ? 0 : (a.isPregame ? 1 : 2)
            let orderB = b.isLive ? 0 : (b.isPregame ? 1 : 2)
            return orderA < orderB
        }

        filteredGames = result
    }

    // MARK: - Color helpers

    private func accentColor() -> NSColor {
        config.accentColor.color
    }

    private func scoreColor(team: String, game: GameInfo) -> NSColor {
        guard config.colorMode == .dynamic else { return accentColor() }
        guard let winner = game.winningTeam else { return Theme.textPrimary }
        return team == winner ? Theme.green : Theme.red
    }

    // MARK: - League display name

    private var leagueName: String {
        LiveScoresConfig.leagueMap.first { $0.league == config.league }?.title ?? config.league.uppercased()
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        guard !filteredGames.isEmpty else {
            if lastFetchFailed {
                return .text("\(leagueName): Offline")
            }
            return .text("\(leagueName): No games")
        }

        let game = filteredGames[displayIndex % filteredGames.count]

        switch config.displayMode {
        case .compact:
            return renderCompact(game)
        case .scores, .ticker, .favoriteOnly:
            return renderFull(game)
        case .record:
            return renderRecord(game)
        }
    }

    private func renderFull(_ game: GameInfo) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()

        let awayColor = scoreColor(team: game.awayTeam, game: game)
        let homeColor = scoreColor(team: game.homeTeam, game: game)
        let weight: NSFont.Weight = game.isLive ? .bold : .medium

        // Away team + score
        str.append(NSAttributedString(string: game.awayTeam, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: awayColor
        ]))
        if !game.isPregame {
            str.append(NSAttributedString(string: " \(game.awayScore)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: weight),
                .foregroundColor: awayColor
            ]))
        }

        str.append(NSAttributedString(string: " - ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.textMuted
        ]))

        // Home team + score
        if !game.isPregame {
            str.append(NSAttributedString(string: "\(game.homeScore) ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: weight),
                .foregroundColor: homeColor
            ]))
        }
        str.append(NSAttributedString(string: game.homeTeam, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: homeColor
        ]))

        // Detail (quarter/period/time)
        if config.showGameTime && !game.shortDetail.isEmpty {
            let detailColor: NSColor = game.isLive ? Theme.accent : Theme.textFaint
            str.append(NSAttributedString(string: " \(game.shortDetail)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: detailColor
            ]))
        }

        let fullText = str.string
        if fullText.count > 32 {
            return .scrollingText(str, width: 220)
        }
        return .attributedText(str)
    }

    private func renderCompact(_ game: GameInfo) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        let awayColor = scoreColor(team: game.awayTeam, game: game)
        let homeColor = scoreColor(team: game.homeTeam, game: game)

        str.append(NSAttributedString(string: game.awayTeam, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: awayColor
        ]))
        if !game.isPregame {
            str.append(NSAttributedString(string: " \(game.awayScore)-\(game.homeScore) ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.textPrimary
            ]))
        } else {
            str.append(NSAttributedString(string: " vs ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: Theme.textMuted
            ]))
        }
        str.append(NSAttributedString(string: game.homeTeam, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: homeColor
        ]))

        if game.isLive {
            str.append(NSAttributedString(string: " \u{25CF}", attributes: [
                .font: NSFont.systemFont(ofSize: 6, weight: .bold),
                .foregroundColor: Theme.green
            ]))
        }

        return .attributedText(str)
    }

    private func renderRecord(_ game: GameInfo) -> WidgetDisplayMode {
        let fav = config.favoriteTeam.uppercased()
        var team = game.homeTeam
        var rec = game.homeRecord
        if game.awayTeam.uppercased() == fav {
            team = game.awayTeam
            rec = game.awayRecord
        } else if game.homeTeam.uppercased() != fav && !fav.isEmpty {
            // Not the favorite's game, show away team
            team = game.awayTeam
            rec = game.awayRecord
        }

        if rec.isEmpty {
            return .text("\(team)")
        }
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: "\(team) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: accentColor()
        ]))
        str.append(NSAttributedString(string: rec, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.textMuted
        ]))
        return .attributedText(str)
    }

    // MARK: - Dropdown Menu (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "\(leagueName) SCORES", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if filteredGames.isEmpty {
            let noGames = NSMenuItem(title: lastFetchFailed ? "Unable to load scores" : "No games today", action: nil, keyEquivalent: "")
            noGames.isEnabled = false
            menu.addItem(noGames)
        } else {
            for game in filteredGames {
                let prefix: String
                if game.isLive { prefix = "\u{25CF} " }
                else if game.isFinal { prefix = "  " }
                else { prefix = "  " }

                let title: String
                if game.isPregame {
                    title = "\(prefix)\(game.awayTeam) vs \(game.homeTeam)  \(game.shortDetail)"
                } else {
                    title = "\(prefix)\(game.awayTeam) \(game.awayScore) - \(game.homeTeam) \(game.homeScore)  \(game.shortDetail)"
                }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
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

extension LiveScoresWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 80 // header
        // Hero card for favorite team
        if favoriteGame != nil { h += 110 }
        // Game list
        let gameCount = filteredGames.count
        h += CGFloat(min(gameCount, 10)) * 36 + 30
        h += SuperWidgetKit.panelHeight + 8
        // Footer
        h += 30
        return NSSize(width: 360, height: min(max(h, 260), 780))
    }

    private var favoriteGame: GameInfo? {
        let fav = config.favoriteTeam.uppercased()
        guard !fav.isEmpty else { return nil }
        return games.first { $0.homeTeam.uppercased() == fav || $0.awayTeam.uppercased() == fav }
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 360
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        // Header
        y = buildPopoverHeader(in: container, y: y, pad: pad, cw: cw)

        // Hero card for favorite team's game
        if let favGame = favoriteGame {
            y = buildHeroCard(in: container, game: favGame, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)

        // All games list
        y = buildGamesList(in: container, y: y, pad: pad, cw: cw)

        // Footer
        buildPopoverFooter(in: container, y: y, pad: pad, cw: cw)

        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let liveCount = filteredGames.filter { $0.isLive }.count
        let finalCount = filteredGames.filter { $0.isFinal }.count
        let upcomingCount = filteredGames.filter { $0.isPregame }.count
        let featured = favoriteGame ?? filteredGames.first
        let featuredText: String
        if let game = featured {
            featuredText = game.isPregame
                ? "\(game.awayTeam) at \(game.homeTeam) \(game.shortDetail)"
                : "\(game.awayTeam) \(game.awayScore)-\(game.homeScore) \(game.homeTeam)"
        } else {
            featuredText = lastFetchFailed ? "Score fetch failed" : "No games scheduled"
        }
        let fetchText: String
        if let fetchTime = lastFetchTime {
            let ago = Int(Date().timeIntervalSince(fetchTime))
            fetchText = ago < 60 ? "Updated \(ago)s ago" : "Updated \(ago / 60)m ago"
        } else {
            fetchText = "Awaiting first fetch"
        }

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Live", value: "\(liveCount)", color: liveCount > 0 ? Theme.green : Theme.textMuted),
                SuperWidgetMetric(label: "Games", value: "\(filteredGames.count)", color: accentColor()),
                SuperWidgetMetric(label: "Finals", value: "\(finalCount)", color: Theme.textSecondary),
                SuperWidgetMetric(label: "Upcoming", value: "\(upcomingCount)", color: Theme.textMuted)
            ],
            insights: [
                featuredText,
                fetchText,
                config.favoriteTeam.isEmpty ? "Favorite team not set" : "Favorite \(config.favoriteTeam.uppercased())"
            ],
            actions: [
                leagueName,
                "Refresh \(Int(effectiveRefreshRate))s",
                "Source ESPN"
            ],
            accent: liveCount > 0 ? Theme.green : accentColor()
        )
    }

    // MARK: - Popover Header

    private func buildPopoverHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "\(leagueName) Scoreboard")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 220, height: 20)
        container.addSubview(title)

        let liveCount = filteredGames.filter { $0.isLive }.count
        let totalCount = filteredGames.count
        let subtitle: String
        if liveCount > 0 {
            subtitle = "\(liveCount) live \u{00B7} \(totalCount) games"
        } else {
            subtitle = "\(totalCount) games today"
        }
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = liveCount > 0 ? Theme.green : Theme.textMuted
        sub.frame = NSRect(x: pad, y: y - 36, width: cw, height: 14)
        container.addSubview(sub)

        // Live indicator dot
        if liveCount > 0 {
            let dot = NSTextField(labelWithString: "\u{25CF} LIVE")
            dot.font = .systemFont(ofSize: 9, weight: .bold)
            dot.textColor = Theme.green
            dot.alignment = .right
            dot.frame = NSRect(x: pad + cw - 60, y: y - 20, width: 60, height: 14)
            container.addSubview(dot)
        }

        y -= 44
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Hero Card (Favorite Team)

    private func buildHeroCard(in container: NSView, game: GameInfo, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 100
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        let innerPad: CGFloat = 12

        // Favorite badge
        let badge = NSTextField(labelWithString: "\u{2605} YOUR TEAM")
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = Theme.accent
        badge.frame = NSRect(x: innerPad, y: cardH - 18, width: 100, height: 12)
        card.addSubview(badge)

        // Teams and score - centered layout
        let teamFontSize: CGFloat = 18
        let scoreFontSize: CGFloat = 24

        let awayColor = scoreColor(team: game.awayTeam, game: game)
        let homeColor = scoreColor(team: game.homeTeam, game: game)

        // Away team abbreviation (left)
        let awayLabel = NSTextField(labelWithString: game.awayTeam)
        awayLabel.font = .monospacedSystemFont(ofSize: teamFontSize, weight: .bold)
        awayLabel.textColor = awayColor
        awayLabel.alignment = .center
        awayLabel.frame = NSRect(x: innerPad, y: cardH - 55, width: 70, height: 26)
        card.addSubview(awayLabel)

        // Score or "vs"
        if game.isPregame {
            let vs = NSTextField(labelWithString: "vs")
            vs.font = .systemFont(ofSize: 14, weight: .medium)
            vs.textColor = Theme.textMuted
            vs.alignment = .center
            vs.frame = NSRect(x: cw / 2 - 40, y: cardH - 52, width: 80, height: 22)
            card.addSubview(vs)
        } else {
            let scoreStr = "\(game.awayScore)  -  \(game.homeScore)"
            let scoreLabel = NSTextField(labelWithString: scoreStr)
            scoreLabel.font = .monospacedDigitSystemFont(ofSize: scoreFontSize, weight: .heavy)
            scoreLabel.textColor = Theme.textPrimary
            scoreLabel.alignment = .center
            scoreLabel.frame = NSRect(x: innerPad + 70, y: cardH - 58, width: cw - innerPad * 2 - 140, height: 30)
            card.addSubview(scoreLabel)
        }

        // Home team abbreviation (right)
        let homeLabel = NSTextField(labelWithString: game.homeTeam)
        homeLabel.font = .monospacedSystemFont(ofSize: teamFontSize, weight: .bold)
        homeLabel.textColor = homeColor
        homeLabel.alignment = .center
        homeLabel.frame = NSRect(x: cw - innerPad - 70, y: cardH - 55, width: 70, height: 26)
        card.addSubview(homeLabel)

        // Status/period line
        let statusStr: String
        let statusColor: NSColor
        if game.isLive {
            statusStr = game.shortDetail
            statusColor = Theme.green
        } else if game.isFinal {
            statusStr = "Final"
            statusColor = Theme.textMuted
        } else {
            statusStr = game.shortDetail
            statusColor = Theme.textFaint
        }
        let statusLabel = NSTextField(labelWithString: statusStr)
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = statusColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: innerPad, y: cardH - 76, width: cw - innerPad * 2, height: 16)
        card.addSubview(statusLabel)

        // Bottom info row: venue + broadcast
        var infoItems: [String] = []
        if config.showVenue && !game.venue.isEmpty { infoItems.append(game.venue) }
        if !game.broadcast.isEmpty { infoItems.append(game.broadcast) }
        if config.showOdds && !game.odds.isEmpty { infoItems.append(game.odds) }

        if !infoItems.isEmpty {
            let infoStr = infoItems.joined(separator: "  \u{00B7}  ")
            let infoLabel = NSTextField(labelWithString: infoStr)
            infoLabel.font = .systemFont(ofSize: 9, weight: .regular)
            infoLabel.textColor = Theme.textFaint
            infoLabel.alignment = .center
            infoLabel.lineBreakMode = .byTruncatingTail
            infoLabel.frame = NSRect(x: innerPad, y: 4, width: cw - innerPad * 2, height: 14)
            card.addSubview(infoLabel)
        }

        y -= cardH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Games List

    private func buildGamesList(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("ALL GAMES")
        header.frame = NSRect(x: pad, y: y - 12, width: 120, height: 12)
        container.addSubview(header)
        y -= 20

        if filteredGames.isEmpty {
            let emptyLabel = NSTextField(labelWithString: lastFetchFailed ? "Unable to load scores" : "No games scheduled")
            emptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
            emptyLabel.textColor = Theme.textFaint
            emptyLabel.frame = NSRect(x: pad, y: y - 18, width: cw, height: 18)
            container.addSubview(emptyLabel)
            y -= 24
            return y
        }

        let visibleGames = Array(filteredGames.prefix(10))
        for (i, game) in visibleGames.enumerated() {
            let rowH: CGFloat = 32
            let rowBg = NSView(frame: NSRect(x: pad, y: y - rowH, width: cw, height: rowH))
            rowBg.wantsLayer = true
            rowBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.025 : 0.0).cgColor
            rowBg.layer?.cornerRadius = 6
            container.addSubview(rowBg)

            // Live indicator
            if game.isLive {
                let dot = NSView(frame: NSRect(x: pad + 4, y: y - rowH / 2 - 3, width: 6, height: 6))
                dot.wantsLayer = true
                dot.layer?.backgroundColor = Theme.green.cgColor
                dot.layer?.cornerRadius = 3
                container.addSubview(dot)
            }

            let xOff: CGFloat = game.isLive ? 16 : 4

            // Away team
            let awayColor = scoreColor(team: game.awayTeam, game: game)
            let awayLbl = NSTextField(labelWithString: game.awayTeam)
            awayLbl.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            awayLbl.textColor = awayColor
            awayLbl.frame = NSRect(x: pad + xOff, y: y - rowH + 8, width: 40, height: 16)
            container.addSubview(awayLbl)

            // Score or "vs"
            if game.isPregame {
                let vs = NSTextField(labelWithString: "vs")
                vs.font = .systemFont(ofSize: 9, weight: .regular)
                vs.textColor = Theme.textFaint
                vs.alignment = .center
                vs.frame = NSRect(x: pad + xOff + 40, y: y - rowH + 8, width: 30, height: 16)
                container.addSubview(vs)
            } else {
                let scoreStr = "\(game.awayScore) - \(game.homeScore)"
                let scoreLbl = NSTextField(labelWithString: scoreStr)
                scoreLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
                scoreLbl.textColor = Theme.textPrimary
                scoreLbl.alignment = .center
                scoreLbl.frame = NSRect(x: pad + xOff + 40, y: y - rowH + 8, width: 60, height: 16)
                container.addSubview(scoreLbl)
            }

            // Home team
            let homeColor = scoreColor(team: game.homeTeam, game: game)
            let homeLbl = NSTextField(labelWithString: game.homeTeam)
            homeLbl.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            homeLbl.textColor = homeColor
            homeLbl.alignment = .left
            homeLbl.frame = NSRect(x: pad + xOff + 100, y: y - rowH + 8, width: 40, height: 16)
            container.addSubview(homeLbl)

            // Status/detail (right aligned)
            let detailColor: NSColor
            if game.isLive { detailColor = Theme.green }
            else if game.isFinal { detailColor = Theme.textFaint }
            else if game.status == .postponed || game.status == .delayed { detailColor = Theme.orange }
            else { detailColor = Theme.textMuted }

            let detailLbl = NSTextField(labelWithString: game.shortDetail)
            detailLbl.font = .systemFont(ofSize: 9, weight: game.isLive ? .semibold : .regular)
            detailLbl.textColor = detailColor
            detailLbl.alignment = .right
            detailLbl.lineBreakMode = .byTruncatingTail
            detailLbl.frame = NSRect(x: pad + xOff + 145, y: y - rowH + 9, width: cw - xOff - 150, height: 14)
            container.addSubview(detailLbl)

            y -= rowH + 4
        }

        if filteredGames.count > 10 {
            let more = NSTextField(labelWithString: "+\(filteredGames.count - 10) more games")
            more.font = .systemFont(ofSize: 9, weight: .regular)
            more.textColor = Theme.textFaint
            more.alignment = .center
            more.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
            container.addSubview(more)
            y -= 18
        }

        return y
    }

    // MARK: - Footer

    @discardableResult
    private func buildPopoverFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y - 4
        addDivider(in: container, y: &y, pad: pad, cw: cw)

        var footerParts: [String] = []
        if let fetchTime = lastFetchTime {
            let ago = Int(Date().timeIntervalSince(fetchTime))
            if ago < 60 {
                footerParts.append("Updated \(ago)s ago")
            } else {
                footerParts.append("Updated \(ago / 60)m ago")
            }
        }
        let rate = Int(effectiveRefreshRate)
        footerParts.append("Refresh: \(rate)s")

        let footer = NSTextField(labelWithString: footerParts.joined(separator: "  \u{00B7}  "))
        footer.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost
        footer.alignment = .center
        footer.frame = NSRect(x: pad, y: y - 14, width: cw, height: 14)
        container.addSubview(footer)
        return y - 18
    }

    // MARK: - UI Helpers

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

extension LiveScoresWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "League"),
            .picker(label: "Sport", key: "sport", options: [
                (title: "Basketball", value: "basketball"),
                (title: "Football", value: "football"),
                (title: "Baseball", value: "baseball"),
                (title: "Hockey", value: "hockey"),
                (title: "Soccer", value: "soccer"),
            ], get: { [weak self] in self?.config.sport ?? "basketball" },
               set: { [weak self] in self?.config.sport = $0 }),

            .picker(label: "League", key: "league", options:
                LiveScoresConfig.leagueMap.map { (title: $0.title, value: $0.league) },
               get: { [weak self] in self?.config.league ?? "nba" },
               set: { [weak self] in self?.config.league = $0 }),

            .text(label: "Favorite Team", key: "favoriteTeam", placeholder: "e.g. NYK, LAL, BOS",
                  get: { [weak self] in self?.config.favoriteTeam ?? "" },
                  set: { [weak self] in self?.config.favoriteTeam = $0 }),

            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Full Scores (NYK 102 - BOS 98 Q4)", value: "scores"),
                (title: "Compact (NYK 102-98)", value: "compact"),
                (title: "Ticker (cycle all games)", value: "ticker"),
                (title: "Favorite Team Only", value: "favoriteOnly"),
                (title: "Team Record (NYK 45-37)", value: "record"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "scores" },
               set: { [weak self] in self?.config.displayMode = LiveScoresConfig.ScoresDisplayMode(rawValue: $0) ?? .scores }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (green/red for win/loss)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = LiveScoresConfig.ScoresColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "green" },
               set: { [weak self] in self?.config.accentColor = LiveScoresConfig.ScoresAccentPreset(rawValue: $0) ?? .green }),

            .section(title: "Filters"),
            .toggle(label: "Show Completed Games", key: "showCompleted",
                    get: { [weak self] in self?.config.showCompleted ?? true },
                    set: { [weak self] in self?.config.showCompleted = $0 }),
            .toggle(label: "Show Upcoming Games", key: "showUpcoming",
                    get: { [weak self] in self?.config.showUpcoming ?? true },
                    set: { [weak self] in self?.config.showUpcoming = $0 }),
            .toggle(label: "Show Game Time/Period", key: "showGameTime",
                    get: { [weak self] in self?.config.showGameTime ?? true },
                    set: { [weak self] in self?.config.showGameTime = $0 }),
            .toggle(label: "Show Venue", key: "showVenue",
                    get: { [weak self] in self?.config.showVenue ?? false },
                    set: { [weak self] in self?.config.showVenue = $0 }),
            .toggle(label: "Show Odds/Spread", key: "showOdds",
                    get: { [weak self] in self?.config.showOdds ?? false },
                    set: { [weak self] in self?.config.showOdds = $0 }),
            .toggle(label: "Show Team Records", key: "showRecords",
                    get: { [weak self] in self?.config.showRecords ?? false },
                    set: { [weak self] in self?.config.showRecords = $0 }),

            .section(title: "Refresh"),
            .slider(label: "Default Refresh Rate", key: "refreshRate", min: 15, max: 120, step: 5,
                    get: { [weak self] in self?.config.refreshRate ?? 30 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
            .slider(label: "Live Game Refresh Rate", key: "liveRefreshRate", min: 5, max: 60, step: 5,
                    get: { [weak self] in self?.config.liveRefreshRate ?? 10 },
                    set: { [weak self] in self?.config.liveRefreshRate = $0 },
                    format: "%.0f s"),
            .toggle(label: "Auto Fast Refresh (live games)", key: "autoFastRefresh",
                    get: { [weak self] in self?.config.autoFastRefresh ?? true },
                    set: { [weak self] in self?.config.autoFastRefresh = $0 }),
            .slider(label: "Cycle Speed", key: "cycleSpeed", min: 2, max: 15, step: 1,
                    get: { [weak self] in self?.config.cycleSpeed ?? 5 },
                    set: { [weak self] in self?.config.cycleSpeed = $0 },
                    format: "%.0f s"),

            .section(title: "Info"),
            .info(label: "Games Loaded", value: { [weak self] in
                let total = self?.games.count ?? 0
                let live = self?.games.filter { $0.isLive }.count ?? 0
                if live > 0 { return "\(total) (\(live) live)" }
                return "\(total)"
            }),
            .info(label: "Current League", value: { [weak self] in
                self?.leagueName ?? "N/A"
            }),
        ]
    }
}
