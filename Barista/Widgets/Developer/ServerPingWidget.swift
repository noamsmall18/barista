import Cocoa

struct ServerEntry: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
}

struct ServerPingConfig: Codable, Equatable {
    var servers: [ServerEntry]
    var refreshRate: TimeInterval

    static let `default` = ServerPingConfig(
        servers: [ServerEntry(name: "Google", host: "google.com", port: 443)],
        refreshRate: 30
    )
}

class ServerPingWidget: BaristaWidget, Cycleable {
    static let widgetID = "server-ping"
    static let displayName = "Server Ping"
    static let subtitle = "Ping servers and monitor latency"
    static let iconName = "antenna.radiowaves.left.and.right"
    static let category = WidgetCategory.developer
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = ServerPingConfig.default

    var config: ServerPingConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var results: [(name: String, latencyMs: Double?, isUp: Bool)] = []
    private(set) var displayIndex: Int = 0

    // MARK: - Cycleable

    var itemCount: Int { max(config.servers.count, 1) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 5 }

    func cycleNext() {
        guard !config.servers.isEmpty else { return }
        displayIndex = (displayIndex + 1) % config.servers.count
        onDisplayUpdate?()
    }

    required init(config: ServerPingConfig) {
        self.config = config
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshRate, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        var newResults: [(name: String, latencyMs: Double?, isUp: Bool)] = []

        for server in config.servers {
            let latency = pingHost(server.host)
            if let ms = latency {
                newResults.append((name: server.name, latencyMs: ms, isUp: true))
            } else {
                newResults.append((name: server.name, latencyMs: nil, isUp: false))
            }
        }

        results = newResults
        if displayIndex >= results.count {
            displayIndex = 0
        }
    }

    private func pingHost(_ host: String) -> Double? {
        // Sanitize host: only allow alphanumeric, dots, hyphens, and colons (IPv6)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        let sanitized = host.unicodeScalars.filter { allowed.contains($0) }.map { Character($0) }
        let safeHost = String(sanitized)
        guard !safeHost.isEmpty, safeHost.count == host.count else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        proc.arguments = ["-c", "1", "-t", "5", safeHost]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()

            guard proc.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Parse "time=XX.X ms" from ping output
            if let range = output.range(of: "time=") {
                let after = output[range.upperBound...]
                if let msRange = after.range(of: " ms") {
                    let msStr = String(after[after.startIndex..<msRange.lowerBound])
                    return Double(msStr)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func render() -> WidgetDisplayMode {
        guard !results.isEmpty else {
            return .text("Ping: --")
        }

        let idx = displayIndex % results.count
        let result = results[idx]

        if result.isUp, let ms = result.latencyMs {
            let msInt = Int(ms)
            return .text("\u{1F7E2} \(result.name) \(msInt)ms")
        } else {
            return .text("\u{1F534} \(result.name) DOWN")
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "SERVER PING", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if results.isEmpty {
            let none = NSMenuItem(title: "No servers configured", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for (i, result) in results.enumerated() {
                let bullet = i == displayIndex ? "\u{25B6}" : " "
                let status: String
                if result.isUp, let ms = result.latencyMs {
                    status = "\(Int(ms))ms"
                } else {
                    status = "DOWN"
                }
                let icon = result.isUp ? "\u{1F7E2}" : "\u{1F534}"
                let item = NSMenuItem(title: "\(bullet) \(icon) \(result.name) - \(status)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if config.servers.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle servers", action: nil, keyEquivalent: "")
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
