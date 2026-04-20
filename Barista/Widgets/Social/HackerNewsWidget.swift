import Cocoa

struct HackerNewsConfig: Codable, Equatable {
    var showScore: Bool
    var scrollTitle: Bool

    static let `default` = HackerNewsConfig(showScore: true, scrollTitle: true)
}

class HackerNewsWidget: BaristaWidget, Cycleable {
    static let widgetID = "hn-top"
    static let displayName = "Hacker News Top"
    static let subtitle = "Top stories on Hacker News"
    static let iconName = "newspaper"
    static let category = WidgetCategory.social
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = HackerNewsConfig.default

    var config: HackerNewsConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 300 }

    private var timer: Timer?
    private(set) var topItems: [(String, Int, String)] = [] // (title, score, url)
    private(set) var displayIndex: Int = 0
    private(set) var lastFetchFailed = false

    // Convenience accessors for the current top story (used by config panel)
    var topTitle: String { topItems.first?.0 ?? "" }
    var topScore: Int { topItems.first?.1 ?? 0 }
    var topURL: String { topItems.first?.2 ?? "" }

    // MARK: - Cycleable

    var itemCount: Int { max(topItems.count, 1) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 8 }

    func cycleNext() {
        guard !topItems.isEmpty else { return }
        displayIndex = (displayIndex + 1) % topItems.count
        onDisplayUpdate?()
    }

    required init(config: HackerNewsConfig) {
        self.config = config
    }

    func start() {
        fetchTop()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchTop()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchTop() {
        guard let url = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data, error == nil,
                  let ids = try? JSONSerialization.jsonObject(with: data) as? [Int] else {
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.topItems.isEmpty { self.onDisplayUpdate?() }
                }
                return
            }

            let topIDs = Array(ids.prefix(5))
            let itemsQueue = DispatchQueue(label: "barista.hn.items")
            var items: [(String, Int, String)] = []
            let group = DispatchGroup()

            for id in topIDs {
                group.enter()
                guard let itemURL = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json") else {
                    group.leave()
                    continue
                }
                URLSession.shared.dataTask(with: itemURL) { data, _, _ in
                    defer { group.leave() }
                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let title = json["title"] as? String else { return }
                    let score = json["score"] as? Int ?? 0
                    let url = json["url"] as? String ?? "https://news.ycombinator.com/item?id=\(id)"
                    itemsQueue.sync { items.append((title, score, url)) }
                }.resume()
            }

            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                self.lastFetchFailed = false
                let sorted = itemsQueue.sync { items.sorted { $0.1 > $1.1 } }
                self.topItems = sorted
                if self.displayIndex >= sorted.count {
                    self.displayIndex = 0
                }
                self.onDisplayUpdate?()
            }
        }.resume()
    }

    func render() -> WidgetDisplayMode {
        if topItems.isEmpty && lastFetchFailed {
            return .text("HN: Offline")
        }
        if topItems.isEmpty {
            return .text("HN: Loading...")
        }

        let item = topItems[displayIndex % topItems.count]
        let title = item.0
        let score = item.1
        let scoreStr = config.showScore ? " (\(score)pts)" : ""
        let text = "HN: \(title)\(scoreStr)"

        if config.scrollTitle && text.count > 35 {
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: Theme.textPrimary,
                .font: NSFont.systemFont(ofSize: 12, weight: .regular)
            ])
            return .scrollingText(attr, width: 250)
        }

        let truncated = text.count > 40 ? String(text.prefix(37)) + "..." : text
        return .text(truncated)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "HACKER NEWS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for (i, item) in topItems.prefix(5).enumerated() {
            let title = item.0.count > 60 ? String(item.0.prefix(57)) + "..." : item.0
            let bullet = i == displayIndex ? "\u{25B6}" : " "
            let menuItem = NSMenuItem(title: "\(bullet) \(i + 1). \(title) (\(item.1)pts)", action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            menu.addItem(menuItem)
        }

        if topItems.isEmpty {
            let loading = NSMenuItem(title: "Loading stories...", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }

        if topItems.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle stories", action: nil, keyEquivalent: "")
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
