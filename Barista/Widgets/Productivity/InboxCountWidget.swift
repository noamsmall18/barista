import Cocoa

struct InboxCountConfig: Codable, Equatable {
    var hideWhenZero: Bool

    static let `default` = InboxCountConfig(hideWhenZero: false)
}

class InboxCountWidget: BaristaWidget {
    static let widgetID = "inbox-count"
    static let displayName = "Inbox Count"
    static let subtitle = "Unread email count from Apple Mail"
    static let iconName = "envelope.badge"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = InboxCountConfig.default

    var config: InboxCountConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 30 }

    private var timer: Timer?
    private(set) var unreadCount: Int = 0
    private(set) var mailRunning: Bool = false

    required init(config: InboxCountConfig) {
        self.config = config
    }

    func start() {
        fetchCount()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchCount()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchCount() {
        let script = """
        tell application "System Events"
            if not (exists process "Mail") then
                return "not_running"
            end if
        end tell
        tell application "Mail"
            return (unread count of inbox) as string
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return }
        let descriptor = appleScript.executeAndReturnError(&error)
        if let result = descriptor.stringValue {
            if result == "not_running" {
                mailRunning = false
                unreadCount = 0
            } else {
                mailRunning = true
                unreadCount = Int(result) ?? 0
            }
        }
    }

    func render() -> WidgetDisplayMode {
        if !mailRunning {
            return .text("\u{2709}\u{FE0F} Mail closed")
        }

        if unreadCount == 0 && config.hideWhenZero {
            return .text("\u{2709}\u{FE0F} Inbox Zero")
        }

        if unreadCount == 0 {
            return .text("\u{2709}\u{FE0F} 0")
        }

        if unreadCount > 10 {
            let attr = NSAttributedString(string: "\u{2709}\u{FE0F} \(unreadCount)", attributes: [
                .foregroundColor: Theme.red,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ])
            return .attributedText(attr)
        }

        return .text("\u{2709}\u{FE0F} \(unreadCount)")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "INBOX", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if !mailRunning {
            let item = NSMenuItem(title: "Mail is not running", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if unreadCount == 0 {
            let item = NSMenuItem(title: "Inbox Zero! \u{1F389}", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "\(unreadCount) unread emails", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Mail", action: #selector(AppDelegate.openMailApp), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
