import Cocoa

struct DadJokeConfig: Codable, Equatable {
    var refreshRate: TimeInterval

    static let `default` = DadJokeConfig(refreshRate: 3600)
}

class DadJokeWidget: BaristaWidget, Cycleable {
    static let widgetID = "dad-joke"
    static let displayName = "Dad Joke"
    static let subtitle = "Random dad jokes on demand"
    static let iconName = "face.smiling"
    static let category = WidgetCategory.funLifestyle
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = DadJokeConfig.default

    var config: DadJokeConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var currentJoke: String = ""
    private(set) var lastFetchFailed = false

    // MARK: - Cycleable

    var itemCount: Int { 1 }
    var currentIndex: Int { 0 }
    var cycleInterval: TimeInterval { 0 }

    func cycleNext() {
        fetchJoke()
    }

    required init(config: DadJokeConfig) {
        self.config = config
    }

    func start() {
        fetchJoke()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.fetchJoke()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchJoke() {
        guard let url = URL(string: "https://icanhazdadjoke.com/") else { return }

        let request = DataFetcher.FetchRequest(
            url: url,
            method: "GET",
            headers: ["Accept": "application/json"],
            maxAge: 0
        )

        DataFetcher.shared.fetch(request) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.parseJoke(data: data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    self.onDisplayUpdate?()
                }
            }
        }
    }

    private func parseJoke(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let joke = json["joke"] as? String else {
            DispatchQueue.main.async {
                self.lastFetchFailed = true
                self.onDisplayUpdate?()
            }
            return
        }

        DispatchQueue.main.async {
            self.currentJoke = joke
            self.onDisplayUpdate?()
        }
    }

    func render() -> WidgetDisplayMode {
        if currentJoke.isEmpty && lastFetchFailed {
            return .text("Joke: Offline")
        }
        if currentJoke.isEmpty {
            return .text("Joke: Loading...")
        }

        let truncated = currentJoke.count > 35
            ? String(currentJoke.prefix(32)) + "..."
            : currentJoke
        return .text(truncated)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "DAD JOKE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if currentJoke.isEmpty {
            let loading = NSMenuItem(title: "Loading joke...", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        } else {
            // Word-wrap the joke into lines of ~60 chars
            let words = currentJoke.components(separatedBy: " ")
            var line = ""
            for word in words {
                if line.isEmpty {
                    line = word
                } else if (line + " " + word).count <= 60 {
                    line += " " + word
                } else {
                    let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                    line = word
                }
            }
            if !line.isEmpty {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let hint = NSMenuItem(title: "Click menu bar for new joke", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
