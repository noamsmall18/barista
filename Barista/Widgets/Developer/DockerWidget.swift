import Cocoa

struct DockerConfig: Codable, Equatable {
    var refreshRate: TimeInterval

    static let `default` = DockerConfig(refreshRate: 10)
}

class DockerWidget: BaristaWidget {
    static let widgetID = "docker-status"
    static let displayName = "Docker Status"
    static let subtitle = "Running Docker containers"
    static let iconName = "shippingbox"
    static let category = WidgetCategory.developer
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = DockerConfig.default

    var config: DockerConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshRate }

    private var timer: Timer?
    private(set) var containers: [(name: String, status: String, image: String)] = []
    private(set) var dockerInstalled = true
    private(set) var lastError: String?

    required init(config: DockerConfig) {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        proc.arguments = ["ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Image}}"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 {
                // Try /opt/homebrew/bin/docker as fallback
                let proc2 = Process()
                proc2.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/docker")
                proc2.arguments = ["ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Image}}"]
                let pipe2 = Pipe()
                proc2.standardOutput = pipe2
                proc2.standardError = Pipe()

                do {
                    try proc2.run()
                    proc2.waitUntilExit()
                    parseOutput(pipe: pipe2)
                } catch {
                    dockerInstalled = false
                    containers = []
                }
                return
            }

            parseOutput(pipe: pipe)
        } catch {
            dockerInstalled = false
            containers = []
        }
    }

    private func parseOutput(pipe: Pipe) {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            containers = []
            return
        }

        dockerInstalled = true
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        containers = lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return (name: parts[0], status: parts[1], image: parts[2])
        }
    }

    func render() -> WidgetDisplayMode {
        guard dockerInstalled else {
            return .text("Docker N/A")
        }
        let count = containers.count
        return .text("\u{1F433} \(count) running")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "DOCKER STATUS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard dockerInstalled else {
            let noDocker = NSMenuItem(title: "Docker not installed", action: nil, keyEquivalent: "")
            noDocker.isEnabled = false
            menu.addItem(noDocker)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return menu
        }

        if containers.isEmpty {
            let none = NSMenuItem(title: "No running containers", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for container in containers {
                let nameItem = NSMenuItem(title: "\(container.name)", action: nil, keyEquivalent: "")
                nameItem.isEnabled = false
                menu.addItem(nameItem)

                let detailItem = NSMenuItem(title: "  \(container.status) - \(container.image)", action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                menu.addItem(detailItem)
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
