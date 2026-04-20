import Cocoa

struct ClipboardConfig: Codable, Equatable {
    var maxPreviewLength: Int
    var historySize: Int
    var showInMenuBar: Bool

    static let `default` = ClipboardConfig(
        maxPreviewLength: 30,
        historySize: 10,
        showInMenuBar: true
    )
}

class ClipboardWidget: BaristaWidget {
    static let widgetID = "clipboard-peek"
    static let displayName = "Clipboard Peek"
    static let subtitle = "See your last copied item at a glance"
    static let iconName = "doc.on.clipboard"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = ClipboardConfig.default

    var config: ClipboardConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 2 }

    private var timer: Timer?
    private(set) var currentClip: String = ""
    private(set) var history: [String] = []
    private var lastChangeCount: Int = 0

    required init(config: ClipboardConfig) {
        self.config = config
    }

    func start() {
        checkClipboard()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string), !text.isEmpty else { return }

        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return }

        // Avoid duplicates at top
        if history.first != cleaned {
            history.insert(cleaned, at: 0)
            if history.count > config.historySize {
                history = Array(history.prefix(config.historySize))
            }
        }

        currentClip = cleaned
        onDisplayUpdate?()
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        guard config.showInMenuBar else {
            return .text("\u{1F4CB} Clipboard")
        }

        if currentClip.isEmpty {
            return .text("\u{1F4CB} Empty")
        }

        let preview = String(currentClip.prefix(config.maxPreviewLength))
        let suffix = currentClip.count > config.maxPreviewLength ? "..." : ""
        return .text("\u{1F4CB} \(preview)\(suffix)")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "CLIPBOARD", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if history.isEmpty {
            let empty = NSMenuItem(title: "No clipboard history", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, clip) in history.enumerated() {
                let preview = String(clip.prefix(50))
                let suffix = clip.count > 50 ? "..." : ""
                let marker = i == 0 ? "\u{25B6} " : "  "
                let item = NSMenuItem(title: "\(marker)\(preview)\(suffix)", action: #selector(pasteItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func pasteItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < history.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history[idx], forType: .string)
        currentClip = history[idx]
        onDisplayUpdate?()
    }

    @objc private func clearHistory() {
        history.removeAll()
        onDisplayUpdate?()
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
