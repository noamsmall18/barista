import Cocoa

struct GitHubNotificationsConfig: Codable, Equatable {
    var personalAccessToken: String
    var refreshRate: TimeInterval
    var maxAge: TimeInterval

    static let `default` = GitHubNotificationsConfig(
        personalAccessToken: "",
        refreshRate: 120,
        maxAge: 60
    )
}

class GitHubNotificationsWidget: BaristaWidget {
    static let widgetID = "github-notifications"
    static let displayName = "GitHub Notifications"
    static let subtitle = "Unread GitHub notifications"
    static let iconName = "bell.badge"
    static let category = WidgetCategory.social
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = GitHubNotificationsConfig.default

    var config: GitHubNotificationsConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var notifications: [(title: String, repo: String, type: String)] = []
    private(set) var lastFetchFailed = false

    required init(config: GitHubNotificationsConfig) {
        self.config = config
    }

    func start() {
        fetchNotifications()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.fetchNotifications()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchNotifications() {
        guard !config.personalAccessToken.isEmpty else {
            DispatchQueue.main.async {
                self.notifications = []
                self.onDisplayUpdate?()
            }
            return
        }

        guard let url = URL(string: "https://api.github.com/notifications") else { return }

        let request = DataFetcher.FetchRequest(
            url: url,
            method: "GET",
            headers: [
                "Authorization": "Bearer \(config.personalAccessToken)",
                "Accept": "application/vnd.github+json"
            ],
            maxAge: config.maxAge
        )

        DataFetcher.shared.fetch(request) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.parseNotifications(data: data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    self.onDisplayUpdate?()
                }
            }
        }
    }

    private func parseNotifications(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            DispatchQueue.main.async {
                self.lastFetchFailed = true
                self.onDisplayUpdate?()
            }
            return
        }

        let parsed: [(title: String, repo: String, type: String)] = json.compactMap { item in
            guard let subject = item["subject"] as? [String: Any],
                  let title = subject["title"] as? String,
                  let type = subject["type"] as? String,
                  let repo = item["repository"] as? [String: Any],
                  let repoName = repo["full_name"] as? String else { return nil }
            return (title: title, repo: repoName, type: type)
        }

        DispatchQueue.main.async {
            self.notifications = parsed
            self.onDisplayUpdate?()
        }
    }

    func render() -> WidgetDisplayMode {
        if config.personalAccessToken.isEmpty {
            return .text("GH: Set Token")
        }
        if lastFetchFailed && notifications.isEmpty {
            return .text("GH: Offline")
        }
        return .text("GH \(notifications.count)")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "GITHUB NOTIFICATIONS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if config.personalAccessToken.isEmpty {
            let noToken = NSMenuItem(title: "No token configured", action: nil, keyEquivalent: "")
            noToken.isEnabled = false
            menu.addItem(noToken)

            let hint = NSMenuItem(title: "Set token in Customize...", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else if notifications.isEmpty {
            let none = NSMenuItem(title: "No unread notifications", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for notification in notifications.prefix(10) {
                let title = notification.title.count > 50
                    ? String(notification.title.prefix(47)) + "..."
                    : notification.title
                let item = NSMenuItem(title: "[\(notification.repo)] \(title)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            if notifications.count > 10 {
                let more = NSMenuItem(title: "... and \(notifications.count - 10) more", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
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
