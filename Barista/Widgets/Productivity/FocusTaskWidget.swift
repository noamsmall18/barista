import Cocoa

struct FocusTaskConfig: Codable, Equatable {
    var currentTask: String
    var maxLength: Int
    var history: [String]
    var maxHistory: Int

    static let `default` = FocusTaskConfig(
        currentTask: "",
        maxLength: 60,
        history: [],
        maxHistory: 20
    )
}

class FocusTaskWidget: BaristaWidget {
    static let widgetID = "focus-task"
    static let displayName = "Focus Task"
    static let subtitle = "Pin one task to your menu bar"
    static let iconName = "target"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = FocusTaskConfig.default

    var config: FocusTaskConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { nil }

    required init(config: FocusTaskConfig) {
        self.config = config
    }

    func start() {
        onDisplayUpdate?()
    }

    func stop() {}

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        if config.currentTask.isEmpty {
            return .text("\u{1F3AF} Set a task...")
        }

        let task = config.currentTask
        if task.count > 30 {
            let attr = NSAttributedString(string: "\u{1F3AF} \(task)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: Theme.textPrimary
            ])
            return .scrollingText(attr, width: 200)
        }

        return .text("\u{1F3AF} \(task)")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "FOCUS TASK", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if !config.currentTask.isEmpty {
            let current = NSMenuItem(title: "\u{1F3AF} \(config.currentTask)", action: nil, keyEquivalent: "")
            current.isEnabled = false
            menu.addItem(current)
            menu.addItem(NSMenuItem.separator())

            let doneItem = NSMenuItem(title: "Mark Done", action: #selector(markDone), keyEquivalent: "d")
            doneItem.target = self
            menu.addItem(doneItem)

            let clearItem = NSMenuItem(title: "Clear Task", action: #selector(clearTask), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        let editItem = NSMenuItem(title: config.currentTask.isEmpty ? "Set Task..." : "Edit Task...", action: #selector(editTask), keyEquivalent: "e")
        editItem.target = self
        menu.addItem(editItem)

        // History
        if !config.history.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let histHeader = NSMenuItem(title: "RECENT", action: nil, keyEquivalent: "")
            histHeader.isEnabled = false
            menu.addItem(histHeader)

            for (i, task) in config.history.prefix(5).enumerated() {
                let item = NSMenuItem(title: "\u{2705} \(task)", action: #selector(restoreTask(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func editTask() {
        let alert = NSAlert()
        alert.messageText = "Focus Task"
        alert.informativeText = "What are you working on?"
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = config.currentTask
        input.placeholderString = "e.g. Ship the login page"
        alert.accessoryView = input

        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                config.currentTask = String(text.prefix(config.maxLength))
                onDisplayUpdate?()
            }
        }
    }

    @objc private func markDone() {
        guard !config.currentTask.isEmpty else { return }
        config.history.insert(config.currentTask, at: 0)
        if config.history.count > config.maxHistory {
            config.history = Array(config.history.prefix(config.maxHistory))
        }
        config.currentTask = ""
        onDisplayUpdate?()
    }

    @objc private func clearTask() {
        config.currentTask = ""
        onDisplayUpdate?()
    }

    @objc private func restoreTask(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < config.history.count else { return }
        if !config.currentTask.isEmpty {
            config.history.insert(config.currentTask, at: 0)
        }
        config.currentTask = config.history.remove(at: idx + (config.currentTask.isEmpty ? 0 : 1))
        if config.history.count > config.maxHistory {
            config.history = Array(config.history.prefix(config.maxHistory))
        }
        onDisplayUpdate?()
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
