import Cocoa

struct ScriptWidgetConfig: Codable, Equatable {
    var scriptPath: String
    var inlineScript: String
    var shell: String
    var refreshInterval: TimeInterval
    var timeout: TimeInterval
    var useXBarFormat: Bool
    var label: String

    static let `default` = ScriptWidgetConfig(
        scriptPath: "",
        inlineScript: "echo \"Hello | color=green\"",
        shell: "/bin/zsh",
        refreshInterval: 60,
        timeout: 30,
        useXBarFormat: true,
        label: "Script"
    )
}

class ScriptWidget: BaristaWidget {
    static let widgetID = "script-widget"
    static let displayName = "Script Widget"
    static let subtitle = "Run any script in your menu bar (xbar compatible)"
    static let iconName = "terminal"
    static let category = WidgetCategory.utility
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = ScriptWidgetConfig.default

    var config: ScriptWidgetConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshInterval }

    private var timer: Timer?
    private(set) var lastOutput: String = ""
    private(set) var lastError: String = ""
    private(set) var parsed: XBarParser.ParsedOutput?
    private(set) var isRunning = false

    required init(config: ScriptWidgetConfig) {
        self.config = config
    }

    func start() {
        runScript()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
            self?.runScript()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Script Execution

    private func runScript() {
        isRunning = true
        onDisplayUpdate?()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result: ScriptRunner.Result
            if !self.config.scriptPath.isEmpty {
                result = ScriptRunner.runFile(
                    path: self.config.scriptPath,
                    shell: self.config.shell,
                    timeout: self.config.timeout
                )
            } else {
                result = ScriptRunner.run(
                    command: self.config.inlineScript,
                    shell: self.config.shell,
                    timeout: self.config.timeout
                )
            }

            DispatchQueue.main.async {
                self.lastOutput = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                self.lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.isRunning = false

                if self.config.useXBarFormat && !self.lastOutput.isEmpty {
                    self.parsed = XBarParser.parse(self.lastOutput)
                } else {
                    self.parsed = nil
                }

                self.onDisplayUpdate?()
            }
        }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        if isRunning && lastOutput.isEmpty {
            return .text("\u{23F3} \(config.label)...")
        }

        if let parsed = parsed, config.useXBarFormat {
            let line = parsed.menuBarLine
            if line.text.isEmpty {
                return .text(config.label)
            }
            return .attributedText(line.attributedString)
        }

        if !lastOutput.isEmpty {
            let firstLine = lastOutput.components(separatedBy: "\n").first ?? lastOutput
            let preview = String(firstLine.prefix(40))
            return .text(preview)
        }

        if !lastError.isEmpty {
            let attr = NSAttributedString(string: "\u{26A0} \(config.label)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: Theme.red
            ])
            return .attributedText(attr)
        }

        return .text(config.label)
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "SCRIPT: \(config.label.uppercased())", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // xbar-parsed menu items
        if let parsed = parsed, config.useXBarFormat, !parsed.menuItems.isEmpty {
            let xbarMenu = XBarParser.buildMenu(from: parsed.menuItems, refreshAction: nil, target: self)
            for item in xbarMenu.items {
                let copy = item.copy() as! NSMenuItem
                menu.addItem(copy)
            }
            menu.addItem(NSMenuItem.separator())
        } else if !lastOutput.isEmpty {
            // Plain text output
            let lines = lastOutput.components(separatedBy: "\n").prefix(15)
            for line in lines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Error display
        if !lastError.isEmpty {
            let errItem = NSMenuItem(title: "\u{26A0} \(String(lastError.prefix(60)))", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Script info
        let source = !config.scriptPath.isEmpty ? config.scriptPath : "Inline script"
        let infoItem = NSMenuItem(title: "Source: \(source)", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func refreshNow() {
        runScript()
    }

    /// Handle xbar item clicks (href / bash)
    @objc func xbarItemClicked(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? XBarParser.ParsedLine else { return }

        if let href = line.href, let url = URL(string: href),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }

        if let bash = line.bash {
            if line.terminal {
                // Open in Terminal - use NSAppleEventDescriptor for safe parameter passing
                let escaped = bash
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                let script = "tell application \"Terminal\" to do script \"\(escaped)\""
                if let as_ = NSAppleScript(source: script) {
                    var err: NSDictionary?
                    as_.executeAndReturnError(&err)
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = ScriptRunner.run(command: bash)
                }
            }

            if line.refresh {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.runScript()
                }
            }
        }
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
