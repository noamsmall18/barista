import Cocoa

struct NowPlayingConfig: Codable, Equatable {
    var preferredPlayer: String // "system", "spotify", "music"
    var showArtist: Bool
    var scrollLongText: Bool
    var maxWidth: CGFloat

    static let `default` = NowPlayingConfig(
        preferredPlayer: "system",
        showArtist: true,
        scrollLongText: true,
        maxWidth: 200
    )
}

class NowPlayingWidget: BaristaWidget {
    static let widgetID = "now-playing"
    static let displayName = "Now Playing"
    static let subtitle = "Currently playing track from Spotify or Apple Music"
    static let iconName = "music.note"
    static let category = WidgetCategory.musicMedia
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = NowPlayingConfig.default

    var config: NowPlayingConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 5 }

    private var timer: Timer?
    private(set) var trackName: String = ""
    private(set) var artistName: String = ""
    private(set) var isPlaying: Bool = false
    private(set) var playerApp: String = ""

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
        // Listen for Apple Music/iTunes notifications
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerStateChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        // Poll fallback
        fetchNowPlaying()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.fetchNowPlaying()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func playerStateChanged(_ notification: Notification) {
        if let info = notification.userInfo {
            trackName = info["Name"] as? String ?? ""
            artistName = info["Artist"] as? String ?? ""
            let state = info["Player State"] as? String ?? ""
            isPlaying = state == "Playing"
            if notification.name.rawValue.contains("spotify") {
                playerApp = "Spotify"
            } else {
                playerApp = "Music"
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onDisplayUpdate?()
        }
    }

    private func fetchNowPlaying() {
        // Try Spotify first via AppleScript
        if config.preferredPlayer == "spotify" || config.preferredPlayer == "system" {
            if let info = runAppleScript("""
                tell application "System Events"
                    if exists (processes where name is "Spotify") then
                        tell application "Spotify"
                            if player state is playing then
                                return name of current track & "|||" & artist of current track & "|||playing"
                            else if player state is paused then
                                return name of current track & "|||" & artist of current track & "|||paused"
                            end if
                        end tell
                    end if
                end tell
                return ""
                """) {
                let parts = info.components(separatedBy: "|||")
                if parts.count >= 3 {
                    trackName = parts[0]
                    artistName = parts[1]
                    isPlaying = parts[2] == "playing"
                    playerApp = "Spotify"
                    return
                }
            }
        }

        // Try Apple Music
        if config.preferredPlayer == "music" || config.preferredPlayer == "system" {
            if let info = runAppleScript("""
                tell application "System Events"
                    if exists (processes where name is "Music") then
                        tell application "Music"
                            if player state is playing then
                                return name of current track & "|||" & artist of current track & "|||playing"
                            else if player state is paused then
                                return name of current track & "|||" & artist of current track & "|||paused"
                            end if
                        end tell
                    end if
                end tell
                return ""
                """) {
                let parts = info.components(separatedBy: "|||")
                if parts.count >= 3 {
                    trackName = parts[0]
                    artistName = parts[1]
                    isPlaying = parts[2] == "playing"
                    playerApp = "Music"
                    return
                }
            }
        }

        // Nothing playing
        if trackName.isEmpty {
            isPlaying = false
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        return result?.stringValue
    }

    func render() -> WidgetDisplayMode {
        guard !trackName.isEmpty else {
            return .text("\u{266B} --")
        }

        let icon = isPlaying ? "\u{25B6}" : "\u{23F8}"
        var display = trackName
        if config.showArtist && !artistName.isEmpty {
            display += " - \(artistName)"
        }

        let text = "\(icon) \(display)"

        if config.scrollLongText && text.count > 30 {
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: Theme.textPrimary,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ])
            return .scrollingText(attr, width: config.maxWidth)
        }

        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "NOW PLAYING", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if trackName.isEmpty {
            let empty = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let trackItem = NSMenuItem(title: "\u{266B} \(trackName)", action: nil, keyEquivalent: "")
            trackItem.isEnabled = false
            menu.addItem(trackItem)

            if !artistName.isEmpty {
                let artistItem = NSMenuItem(title: "  by \(artistName)", action: nil, keyEquivalent: "")
                artistItem.isEnabled = false
                menu.addItem(artistItem)
            }

            let statusItem = NSMenuItem(title: isPlaying ? "Status: Playing" : "Status: Paused", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            if !playerApp.isEmpty {
                let appItem = NSMenuItem(title: "Player: \(playerApp)", action: nil, keyEquivalent: "")
                appItem.isEnabled = false
                menu.addItem(appItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
