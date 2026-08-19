import Cocoa

// MARK: - Config

struct NowPlayingConfig: Codable, Equatable {
    var displayMode: NowPlayingDisplayMode
    var preferredPlayer: PreferredPlayer
    var showArtist: Bool
    var showAlbum: Bool
    var showElapsed: Bool
    var maxTitleLength: Int
    var scrollSpeed: Double
    var maxWidth: CGFloat
    var refreshRate: TimeInterval
    var accentColor: AccentPreset
    var colorMode: ColorMode
    var showRecentTracks: Bool
    var recentTrackCount: Int
    var showProgressInBar: Bool
    var showArtwork: Bool
    var artworkSize: Double

    static let `default` = NowPlayingConfig(
        displayMode: .titleArtist,
        preferredPlayer: .system,
        showArtist: true,
        showAlbum: false,
        showElapsed: false,
        maxTitleLength: 30,
        scrollSpeed: 40,
        maxWidth: 200,
        refreshRate: 1,
        accentColor: .purple,
        colorMode: .fixed,
        showRecentTracks: true,
        recentTrackCount: 5,
        showProgressInBar: false,
        showArtwork: true,
        artworkSize: 80
    )

    enum NowPlayingDisplayMode: String, Codable, Equatable {
        case titleArtist  // "Song - Artist"
        case titleOnly    // "Song"
        case artistOnly   // "Artist"
        case scrolling    // scrolling marquee
        case compact      // music note icon + truncated title
    }

    enum PreferredPlayer: String, Codable, Equatable {
        case system   // try Spotify, then Music
        case spotify
        case music
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

    enum ColorMode: String, Codable, Equatable {
        case dynamic // shifts based on playback state
        case fixed   // always uses accentColor
    }
}

// MARK: - Track Info

private struct TrackInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var position: Double = 0      // seconds elapsed
    var duration: Double = 0      // seconds total
    var isPlaying: Bool = false
    var playerApp: String = ""

    var isEmpty: Bool { title.isEmpty }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(position / duration, 1.0)
    }

    func formatTime(_ secs: Double) -> String {
        guard secs >= 0 && secs.isFinite else { return "0:00" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    var elapsedStr: String { formatTime(position) }
    var durationStr: String { formatTime(duration) }
}

// MARK: - Widget

class NowPlayingWidget: BaristaWidget {
    static let widgetID = "now-playing"
    static let displayName = "Now Playing"
    static let subtitle = "Track info, artwork & controls from Spotify or Music"
    static let iconName = "music.note"
    static let category = WidgetCategory.musicMedia
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = NowPlayingConfig.default

    var config: NowPlayingConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    private var track = TrackInfo()
    private var recentTracks: [TrackInfo] = []
    private var artworkImage: NSImage?
    private var lastArtworkKey: String = ""

    // Public accessors for compatibility
    var trackName: String { track.title }
    var artistName: String { track.artist }
    var isPlaying: Bool { track.isPlaying }
    var playerApp: String { track.playerApp }

    required init(config: NowPlayingConfig) {
        self.config = config
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func start() {
        // Listen for Spotify notifications
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerStateChanged(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
        // Listen for Apple Music notifications
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerStateChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        currentTimerInterval = config.refreshRate
        fetchNowPlaying()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Self-correcting timer

    private func tick() {
        if currentTimerInterval != config.refreshRate {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = config.refreshRate
            timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        fetchNowPlaying()
    }

    // MARK: - Notification handler

    @objc private func playerStateChanged(_ notification: Notification) {
        if let info = notification.userInfo {
            let newTitle = info["Name"] as? String ?? ""
            let newArtist = info["Artist"] as? String ?? ""
            let state = info["Player State"] as? String ?? ""
            let app = notification.name.rawValue.contains("spotify") ? "Spotify" : "Music"

            if !newTitle.isEmpty {
                addToRecent(track)
                track.title = newTitle
                track.artist = newArtist
                track.isPlaying = state == "Playing"
                track.playerApp = app
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onDisplayUpdate?()
        }
    }

    // MARK: - AppleScript data fetch

    private func fetchNowPlaying() {
        let player = config.preferredPlayer
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var info = TrackInfo()

            // Try Spotify
            if player == .spotify || player == .system {
                if let result = self.runAppleScript("""
                    tell application "System Events"
                        if exists (processes where name is "Spotify") then
                            tell application "Spotify"
                                if player state is playing or player state is paused then
                                    set t to name of current track
                                    set a to artist of current track
                                    set al to album of current track
                                    set pos to player position
                                    set dur to (duration of current track) / 1000
                                    set st to player state as string
                                    return t & "|||" & a & "|||" & al & "|||" & (pos as string) & "|||" & (dur as string) & "|||" & st
                                end if
                            end tell
                        end if
                    end tell
                    return ""
                    """) {
                    info = self.parseTrackResult(result, app: "Spotify")
                }
            }

            // Try Music
            if info.isEmpty && (player == .music || player == .system) {
                if let result = self.runAppleScript("""
                    tell application "System Events"
                        if exists (processes where name is "Music") then
                            tell application "Music"
                                if player state is playing or player state is paused then
                                    set t to name of current track
                                    set a to artist of current track
                                    set al to album of current track
                                    set pos to player position
                                    set dur to duration of current track
                                    set st to player state as string
                                    return t & "|||" & a & "|||" & al & "|||" & (pos as string) & "|||" & (dur as string) & "|||" & st
                                end if
                            end tell
                        end if
                    end tell
                    return ""
                    """) {
                    info = self.parseTrackResult(result, app: "Music")
                }
            }

            // Fetch artwork if track changed
            let artKey = "\(info.title)|\(info.artist)|\(info.playerApp)"
            var newArtwork: NSImage? = nil
            if !info.isEmpty && artKey != self.lastArtworkKey {
                newArtwork = self.fetchArtwork(for: info)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !info.isEmpty {
                    // Track changed - add old to recent
                    if info.title != self.track.title || info.artist != self.track.artist {
                        self.addToRecent(self.track)
                    }
                    self.track = info
                    if let art = newArtwork {
                        self.artworkImage = art
                        self.lastArtworkKey = artKey
                    }
                } else if self.track.isEmpty {
                    self.track.isPlaying = false
                } else {
                    // Update position even if main fetch returned empty (player closed)
                    // Keep existing track data but mark as not playing
                }
                self.onDisplayUpdate?()
            }
        }
    }

    private func parseTrackResult(_ raw: String, app: String) -> TrackInfo {
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return TrackInfo() }
        var info = TrackInfo()
        info.title = parts[0]
        info.artist = parts[1]
        info.album = parts[2]
        info.position = Double(parts[3]) ?? 0
        info.duration = Double(parts[4]) ?? 0
        info.isPlaying = parts[5].lowercased() == "playing"
        info.playerApp = app
        return info
    }

    private func fetchArtwork(for info: TrackInfo) -> NSImage? {
        guard config.showArtwork else { return nil }

        if info.playerApp == "Spotify" {
            // Spotify artwork URL via AppleScript
            if let urlStr = runAppleScript("""
                tell application "System Events"
                    if exists (processes where name is "Spotify") then
                        tell application "Spotify"
                            return artwork url of current track
                        end tell
                    end if
                end tell
                return ""
                """), !urlStr.isEmpty, let url = URL(string: urlStr),
               let data = try? Data(contentsOf: url) {
                return NSImage(data: data)
            }
        } else if info.playerApp == "Music" {
            // Music artwork via AppleScript raw data
            if let rawData = runAppleScriptData("""
                tell application "Music"
                    set artworks_ to artworks of current track
                    if (count of artworks_) > 0 then
                        return raw data of item 1 of artworks_
                    end if
                end tell
                """) {
                return NSImage(data: rawData)
            }
        }
        return nil
    }

    private func addToRecent(_ t: TrackInfo) {
        guard !t.isEmpty else { return }
        // Avoid duplicates at top
        if let first = recentTracks.first, first.title == t.title && first.artist == t.artist { return }
        recentTracks.insert(t, at: 0)
        let maxRecent = config.recentTrackCount
        if recentTracks.count > maxRecent {
            recentTracks = Array(recentTracks.prefix(maxRecent))
        }
    }

    // MARK: - AppleScript helpers

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        return result?.stringValue
    }

    private func runAppleScriptData(_ source: String) -> Data? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        return result?.data
    }

    // MARK: - Playback controls

    private func sendCommand(_ command: String) {
        let app: String
        if track.playerApp == "Music" {
            app = "Music"
        } else {
            app = "Spotify"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runAppleScript("""
                tell application "\(app)"
                    \(command)
                end tell
                """)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.fetchNowPlaying()
            }
        }
    }

    @objc private func playPause() { sendCommand("playpause") }
    @objc private func nextTrack() { sendCommand("next track") }
    @objc private func prevTrack() { sendCommand("previous track") }

    // MARK: - Accent color

    private var accent: NSColor {
        switch config.colorMode {
        case .fixed: return config.accentColor.color
        case .dynamic:
            if track.isPlaying {
                return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1) // green when playing
            } else {
                return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1) // amber when paused
            }
        }
    }

    // MARK: - Render (Menu Bar)

    func render() -> WidgetDisplayMode {
        guard !track.isEmpty else {
            return .text("\u{266B} --")
        }

        let icon = track.isPlaying ? "\u{25B6}" : "\u{23F8}"
        let maxLen = config.maxTitleLength

        switch config.displayMode {
        case .titleArtist:
            var display = truncate(track.title, max: maxLen)
            if config.showArtist && !track.artist.isEmpty {
                display += " - \(track.artist)"
            }
            if config.showElapsed && track.duration > 0 {
                display += " \(track.elapsedStr)/\(track.durationStr)"
            }
            return renderAttributedBar(icon: icon, text: display)

        case .titleOnly:
            let display = truncate(track.title, max: maxLen)
            return renderAttributedBar(icon: icon, text: display)

        case .artistOnly:
            let display = truncate(track.artist.isEmpty ? track.title : track.artist, max: maxLen)
            return renderAttributedBar(icon: icon, text: display)

        case .scrolling:
            var display = "\(icon) \(track.title)"
            if config.showArtist && !track.artist.isEmpty {
                display += " - \(track.artist)"
            }
            if config.showAlbum && !track.album.isEmpty {
                display += " [\(track.album)]"
            }
            if config.showElapsed && track.duration > 0 {
                display += " \(track.elapsedStr)/\(track.durationStr)"
            }
            let attr = NSAttributedString(string: display, attributes: [
                .foregroundColor: Theme.textPrimary,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ])
            return .scrollingText(attr, width: config.maxWidth)

        case .compact:
            return renderAttributedBar(icon: "\u{266B}", text: truncate(track.title, max: 15))
        }
    }

    private func renderAttributedBar(icon: String, text: String) -> WidgetDisplayMode {
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: "\(icon) ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: accent
        ]))
        str.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Theme.textPrimary
        ]))
        if config.showProgressInBar && track.duration > 0 {
            let pct = Int(track.progressFraction * 100)
            str.append(NSAttributedString(string: " \(pct)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]))
        }
        return .attributedText(str)
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "\u{2026}"
    }

    // MARK: - Dropdown Menu (fallback)

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let h = NSMenuItem(title: "NOW PLAYING", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(NSMenuItem.separator())

        if track.isEmpty {
            let empty = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let ti = NSMenuItem(title: "\u{266B} \(track.title)", action: nil, keyEquivalent: "")
            ti.isEnabled = false; menu.addItem(ti)
            if !track.artist.isEmpty {
                let ai = NSMenuItem(title: "  by \(track.artist)", action: nil, keyEquivalent: "")
                ai.isEnabled = false; menu.addItem(ai)
            }
            if !track.album.isEmpty {
                let ali = NSMenuItem(title: "  \(track.album)", action: nil, keyEquivalent: "")
                ali.isEnabled = false; menu.addItem(ali)
            }
            let si = NSMenuItem(title: track.isPlaying ? "Status: Playing" : "Status: Paused", action: nil, keyEquivalent: "")
            si.isEnabled = false; menu.addItem(si)
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

extension NowPlayingWidget: InteractiveDropdown {
    var dropdownSize: NSSize {
        var h: CGFloat = 220 // header + track card + progress + controls
        if config.showRecentTracks && !recentTracks.isEmpty {
            h += CGFloat(min(recentTracks.count, config.recentTrackCount)) * 28 + 30
        }
        h += SuperWidgetKit.panelHeight + 8
        h += 40 // footer
        return NSSize(width: 340, height: min(max(h, 280), 720))
    }

    func buildDropdownPopover() -> NSView {
        let w: CGFloat = 340
        let h = dropdownSize.height
        let pad: CGFloat = 16
        let cw = w - pad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        var y = h - pad

        y = buildHeader(in: container, y: y, pad: pad, cw: cw)

        if track.isEmpty {
            let lbl = NSTextField(labelWithString: "No music playing")
            lbl.font = .systemFont(ofSize: 13, weight: .medium)
            lbl.textColor = Theme.textMuted
            lbl.alignment = .center
            lbl.frame = NSRect(x: pad, y: y - 40, width: cw, height: 20)
            container.addSubview(lbl)

            let hint = NSTextField(labelWithString: "Play a track in Spotify or Music to see it here")
            hint.font = .systemFont(ofSize: 10, weight: .regular)
            hint.textColor = Theme.textFaint
            hint.alignment = .center
            hint.frame = NSRect(x: pad, y: y - 58, width: cw, height: 14)
            container.addSubview(hint)
            y -= 70
            y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
            buildFooter(in: container, y: y, pad: pad, cw: cw)
            return container
        }

        y = buildTrackCard(in: container, y: y, pad: pad, cw: cw)
        y = buildProgressBar(in: container, y: y, pad: pad, cw: cw)
        y = buildControls(in: container, y: y, pad: pad, cw: cw)

        if config.showRecentTracks && !recentTracks.isEmpty {
            y = buildRecentTracks(in: container, y: y, pad: pad, cw: cw)
        }

        y = buildTerminalReadout(in: container, y: y, pad: pad, cw: cw)
        buildFooter(in: container, y: y, pad: pad, cw: cw)
        return container
    }

    private func buildTerminalReadout(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let status = track.isEmpty ? "Idle" : (track.isPlaying ? "Playing" : "Paused")
        let progressText = track.duration > 0 ? "\(Int(track.progressFraction * 100))%" : "--"
        let durationText = track.duration > 0 ? track.durationStr : "--"
        let titleText = track.isEmpty ? "No track loaded" : track.title
        let artistText = track.artist.isEmpty ? "Artist unavailable" : track.artist
        let albumText = track.album.isEmpty ? "Album unavailable" : track.album

        return SuperWidgetKit.addTerminalPanel(
            to: container,
            y: y,
            pad: pad,
            cw: cw,
            metrics: [
                SuperWidgetMetric(label: "Player", value: track.playerApp.isEmpty ? "--" : track.playerApp, color: accent),
                SuperWidgetMetric(label: "State", value: status, color: track.isPlaying ? Theme.green : Theme.textMuted),
                SuperWidgetMetric(label: "Progress", value: progressText, color: accent),
                SuperWidgetMetric(label: "Length", value: durationText, color: Theme.textSecondary)
            ],
            insights: [
                titleText,
                artistText,
                albumText
            ],
            actions: [
                "Recent \(recentTracks.count)",
                "Refresh \(Int(config.refreshRate))s",
                config.showArtwork ? "Artwork on" : "Artwork off"
            ],
            accent: accent
        )
    }

    // MARK: - Header

    private func buildHeader(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let title = NSTextField(labelWithString: "Now Playing")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: pad, y: y - 20, width: 160, height: 20)
        container.addSubview(title)

        // Player badge
        if !track.playerApp.isEmpty {
            let badge = NSTextField(labelWithString: track.playerApp)
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = accent
            badge.alignment = .right
            badge.frame = NSRect(x: pad + cw - 100, y: y - 18, width: 100, height: 16)
            container.addSubview(badge)
        }

        y -= 28
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    // MARK: - Track Card (artwork + info)

    private func buildTrackCard(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        let artSize = CGFloat(config.artworkSize)
        let cardH: CGFloat = max(artSize + 16, 80)
        let card = makeCard(x: pad, y: y - cardH, w: cw, h: cardH)
        container.addSubview(card)

        // Album artwork or placeholder
        let imgSize: CGFloat = artSize
        let imgX: CGFloat = 8
        let imgY: CGFloat = (cardH - imgSize) / 2
        let imgView = NSImageView(frame: NSRect(x: imgX, y: imgY, width: imgSize, height: imgSize))
        imgView.wantsLayer = true
        imgView.layer?.cornerRadius = 8
        imgView.layer?.masksToBounds = true
        imgView.imageScaling = .scaleProportionallyUpOrDown

        if let art = artworkImage {
            imgView.image = art
        } else {
            // Placeholder: dark card with music note
            let placeholder = NSImage(size: NSSize(width: imgSize, height: imgSize))
            placeholder.lockFocus()
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: imgSize, height: imgSize), xRadius: 8, yRadius: 8).fill()
            let noteStr = "\u{266B}"
            let noteAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: imgSize * 0.4, weight: .ultraLight),
                .foregroundColor: NSColor.white.withAlphaComponent(0.15)
            ]
            let noteSize = noteStr.size(withAttributes: noteAttr)
            noteStr.draw(at: NSPoint(x: (imgSize - noteSize.width) / 2, y: (imgSize - noteSize.height) / 2), withAttributes: noteAttr)
            placeholder.unlockFocus()
            imgView.image = placeholder
        }

        imgView.layer?.borderWidth = 0.5
        imgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        card.addSubview(imgView)

        // Track info to the right of artwork
        let tx: CGFloat = imgX + imgSize + 12
        let tw: CGFloat = cw - tx - 8
        var ty = cardH - 16

        // Title
        let titleLabel = NSTextField(labelWithString: track.title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: tx, y: ty - 18, width: tw, height: 18)
        card.addSubview(titleLabel)
        ty -= 22

        // Artist
        if !track.artist.isEmpty {
            let artistLabel = NSTextField(labelWithString: track.artist)
            artistLabel.font = .systemFont(ofSize: 12, weight: .medium)
            artistLabel.textColor = Theme.textSecondary
            artistLabel.lineBreakMode = .byTruncatingTail
            artistLabel.frame = NSRect(x: tx, y: ty - 16, width: tw, height: 16)
            card.addSubview(artistLabel)
            ty -= 20
        }

        // Album
        if !track.album.isEmpty {
            let albumLabel = NSTextField(labelWithString: track.album)
            albumLabel.font = .systemFont(ofSize: 10, weight: .regular)
            albumLabel.textColor = Theme.textMuted
            albumLabel.lineBreakMode = .byTruncatingTail
            albumLabel.frame = NSRect(x: tx, y: ty - 14, width: tw, height: 14)
            card.addSubview(albumLabel)
            ty -= 18
        }

        // Playback state indicator
        let stateStr = track.isPlaying ? "\u{25B6} Playing" : "\u{23F8} Paused"
        let stateLabel = NSTextField(labelWithString: stateStr)
        stateLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        stateLabel.textColor = track.isPlaying ? Theme.green : Theme.textFaint
        stateLabel.frame = NSRect(x: tx, y: ty - 12, width: tw, height: 12)
        card.addSubview(stateLabel)

        y -= cardH + 8
        return y
    }

    // MARK: - Progress Bar

    private func buildProgressBar(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y
        guard track.duration > 0 else { return y }

        // Time labels
        let elapsed = NSTextField(labelWithString: track.elapsedStr)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        elapsed.textColor = Theme.textMuted
        elapsed.frame = NSRect(x: pad, y: y - 12, width: 40, height: 12)
        container.addSubview(elapsed)

        let remaining = NSTextField(labelWithString: track.durationStr)
        remaining.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        remaining.textColor = Theme.textMuted
        remaining.alignment = .right
        remaining.frame = NSRect(x: pad + cw - 40, y: y - 12, width: 40, height: 12)
        container.addSubview(remaining)

        y -= 16

        // Progress bar track
        let barH: CGFloat = 4
        let barBg = NSView(frame: NSRect(x: pad, y: y - barH, width: cw, height: barH))
        barBg.wantsLayer = true
        barBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        barBg.layer?.cornerRadius = 2
        container.addSubview(barBg)

        // Progress bar fill
        let fillW = cw * CGFloat(track.progressFraction)
        if fillW > 0 {
            let fill = NSView(frame: NSRect(x: pad, y: y - barH, width: fillW, height: barH))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
            fill.layer?.cornerRadius = 2
            container.addSubview(fill)

            // Dot at current position
            let dotSize: CGFloat = 8
            let dot = NSView(frame: NSRect(x: pad + fillW - dotSize / 2, y: y - barH - 2, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = accent.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            container.addSubview(dot)
        }

        y -= barH + 8
        return y
    }

    // MARK: - Playback Controls

    private func buildControls(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let btnW: CGFloat = 36
        let btnH: CGFloat = 28
        let gap: CGFloat = 12
        let totalW = btnW * 3 + gap * 2
        let startX = pad + (cw - totalW) / 2

        // Previous
        let prevBtn = makeControlButton(title: "\u{23EE}", x: startX, y: y - btnH, w: btnW, h: btnH)
        prevBtn.target = self
        prevBtn.action = #selector(prevTrack)
        container.addSubview(prevBtn)

        // Play/Pause
        let ppTitle = track.isPlaying ? "\u{23F8}" : "\u{25B6}"
        let ppBtn = makeControlButton(title: ppTitle, x: startX + btnW + gap, y: y - btnH, w: btnW, h: btnH)
        ppBtn.target = self
        ppBtn.action = #selector(playPause)
        // Highlight play/pause button
        ppBtn.wantsLayer = true
        ppBtn.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        ppBtn.layer?.borderColor = accent.withAlphaComponent(0.3).cgColor
        container.addSubview(ppBtn)

        // Next
        let nextBtn = makeControlButton(title: "\u{23ED}", x: startX + (btnW + gap) * 2, y: y - btnH, w: btnW, h: btnH)
        nextBtn.target = self
        nextBtn.action = #selector(nextTrack)
        container.addSubview(nextBtn)

        y -= btnH + 8
        addDivider(in: container, y: &y, pad: pad, cw: cw)
        return y
    }

    private func makeControlButton(title: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: y, width: w, height: h))
        btn.title = title
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        btn.layer?.cornerRadius = 6
        btn.layer?.borderWidth = 0.5
        btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        btn.font = .systemFont(ofSize: 14)
        btn.contentTintColor = Theme.textPrimary
        return btn
    }

    // MARK: - Recent Tracks

    private func buildRecentTracks(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        var y = y

        let header = Theme.sectionHeader("RECENTLY PLAYED")
        header.frame = NSRect(x: pad, y: y - 12, width: 150, height: 12)
        container.addSubview(header)
        y -= 18

        let recent = Array(recentTracks.prefix(config.recentTrackCount))
        for (i, t) in recent.enumerated() {
            let rowH: CGFloat = 24
            let rowBg = NSView(frame: NSRect(x: pad, y: y - rowH, width: cw, height: rowH))
            rowBg.wantsLayer = true
            rowBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.02 : 0.0).cgColor
            rowBg.layer?.cornerRadius = 4
            container.addSubview(rowBg)

            // Number
            let num = NSTextField(labelWithString: "\(i + 1)")
            num.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
            num.textColor = Theme.textFaint
            num.frame = NSRect(x: pad + 6, y: y - rowH + 5, width: 14, height: 14)
            container.addSubview(num)

            // Title - Artist
            var displayStr = t.title
            if !t.artist.isEmpty { displayStr += " - \(t.artist)" }
            let maxLen = 38
            if displayStr.count > maxLen { displayStr = String(displayStr.prefix(maxLen - 2)) + ".." }

            let name = NSTextField(labelWithString: displayStr)
            name.font = .systemFont(ofSize: 10.5, weight: .medium)
            name.textColor = Theme.textSecondary
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: pad + 22, y: y - rowH + 5, width: cw - 70, height: 14)
            container.addSubview(name)

            // Duration
            if t.duration > 0 {
                let durLabel = NSTextField(labelWithString: t.durationStr)
                durLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
                durLabel.textColor = Theme.textFaint
                durLabel.alignment = .right
                durLabel.frame = NSRect(x: pad + cw - 42, y: y - rowH + 5, width: 36, height: 14)
                container.addSubview(durLabel)
            }

            y -= rowH + 2
        }

        return y
    }

    // MARK: - Footer

    @discardableResult
    private func buildFooter(in container: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let y = y - 4
        var parts: [String] = []
        if !track.playerApp.isEmpty { parts.append(track.playerApp) }
        if track.duration > 0 { parts.append(track.durationStr) }
        if !track.album.isEmpty { parts.append(track.album) }
        if parts.isEmpty { parts.append("No playback") }

        let footer = NSTextField(labelWithString: parts.joined(separator: "  \u{00B7}  "))
        footer.font = .systemFont(ofSize: 9, weight: .regular)
        footer.textColor = Theme.textGhost
        footer.alignment = .center
        footer.lineBreakMode = .byTruncatingTail
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

extension NowPlayingWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Title - Artist", value: "titleArtist"),
                (title: "Title Only", value: "titleOnly"),
                (title: "Artist Only", value: "artistOnly"),
                (title: "Scrolling Marquee", value: "scrolling"),
                (title: "Compact (icon + title)", value: "compact"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "titleArtist" },
               set: { [weak self] in self?.config.displayMode = NowPlayingConfig.NowPlayingDisplayMode(rawValue: $0) ?? .titleArtist }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (play/pause)", value: "dynamic"),
                (title: "Fixed Accent", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "fixed" },
               set: { [weak self] in self?.config.colorMode = NowPlayingConfig.ColorMode(rawValue: $0) ?? .fixed }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "purple" },
               set: { [weak self] in self?.config.accentColor = NowPlayingConfig.AccentPreset(rawValue: $0) ?? .purple }),

            .section(title: "Menu Bar Info"),
            .toggle(label: "Show Artist", key: "showArtist",
                    get: { [weak self] in self?.config.showArtist ?? true },
                    set: { [weak self] in self?.config.showArtist = $0 }),
            .toggle(label: "Show Album", key: "showAlbum",
                    get: { [weak self] in self?.config.showAlbum ?? false },
                    set: { [weak self] in self?.config.showAlbum = $0 }),
            .toggle(label: "Show Elapsed/Duration", key: "showElapsed",
                    get: { [weak self] in self?.config.showElapsed ?? false },
                    set: { [weak self] in self?.config.showElapsed = $0 }),
            .toggle(label: "Show Progress %", key: "showProgressInBar",
                    get: { [weak self] in self?.config.showProgressInBar ?? false },
                    set: { [weak self] in self?.config.showProgressInBar = $0 }),
            .slider(label: "Max Title Length", key: "maxTitleLength", min: 10, max: 60, step: 5,
                    get: { [weak self] in Double(self?.config.maxTitleLength ?? 30) },
                    set: { [weak self] in self?.config.maxTitleLength = Int($0) },
                    format: "%.0f chars"),
            .slider(label: "Scroll Width", key: "maxWidth", min: 80, max: 400, step: 10,
                    get: { [weak self] in Double(self?.config.maxWidth ?? 200) },
                    set: { [weak self] in self?.config.maxWidth = CGFloat($0) },
                    format: "%.0f px"),

            .section(title: "Player"),
            .picker(label: "Preferred Player", key: "preferredPlayer", options: [
                (title: "System (auto-detect)", value: "system"),
                (title: "Spotify", value: "spotify"),
                (title: "Apple Music", value: "music"),
            ], get: { [weak self] in self?.config.preferredPlayer.rawValue ?? "system" },
               set: { [weak self] in self?.config.preferredPlayer = NowPlayingConfig.PreferredPlayer(rawValue: $0) ?? .system }),

            .section(title: "Dropdown"),
            .toggle(label: "Show Album Artwork", key: "showArtwork",
                    get: { [weak self] in self?.config.showArtwork ?? true },
                    set: { [weak self] in self?.config.showArtwork = $0 }),
            .slider(label: "Artwork Size", key: "artworkSize", min: 40, max: 120, step: 10,
                    get: { [weak self] in self?.config.artworkSize ?? 80 },
                    set: { [weak self] in self?.config.artworkSize = $0 },
                    format: "%.0f px"),
            .toggle(label: "Show Recent Tracks", key: "showRecentTracks",
                    get: { [weak self] in self?.config.showRecentTracks ?? true },
                    set: { [weak self] in self?.config.showRecentTracks = $0 }),
            .slider(label: "Recent Track Count", key: "recentTrackCount", min: 1, max: 10, step: 1,
                    get: { [weak self] in Double(self?.config.recentTrackCount ?? 5) },
                    set: { [weak self] in self?.config.recentTrackCount = Int($0) },
                    format: "%.0f"),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshRate", min: 1, max: 10, step: 1,
                    get: { [weak self] in self?.config.refreshRate ?? 2 },
                    set: { [weak self] in self?.config.refreshRate = $0 },
                    format: "%.0f s"),
        ]
    }
}
