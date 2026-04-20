import Cocoa
import EventKit

struct RemindersConfig: Codable, Equatable {
    var showCount: Bool
    var showNextTitle: Bool

    static let `default` = RemindersConfig(showCount: true, showNextTitle: true)
}

class RemindersWidget: BaristaWidget, Cycleable {
    static let widgetID = "reminders"
    static let displayName = "Reminders"
    static let subtitle = "Pending reminders from Apple Reminders"
    static let iconName = "checklist"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = RemindersConfig.default

    var config: RemindersConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    private var timer: Timer?
    private let store = EKEventStore()
    private(set) var pendingCount: Int = 0
    private(set) var nextReminder: String = ""
    private(set) var reminders: [(String, Date?)] = []
    private(set) var hasAccess = false
    private(set) var displayIndex: Int = 0

    // MARK: - Cycleable

    var itemCount: Int { max(reminders.count, 1) }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 6 }

    func cycleNext() {
        guard !reminders.isEmpty else { return }
        displayIndex = (displayIndex + 1) % reminders.count
        onDisplayUpdate?()
    }

    required init(config: RemindersConfig) {
        self.config = config
    }

    func start() {
        requestAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchReminders()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { [weak self] granted, _ in
                self?.hasAccess = granted
                self?.fetchReminders()
            }
        } else {
            store.requestAccess(to: .reminder) { [weak self] granted, _ in
                self?.hasAccess = granted
                self?.fetchReminders()
            }
        }
    }

    private func fetchReminders() {
        guard hasAccess else { return }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )

        store.fetchReminders(matching: predicate) { [weak self] results in
            guard let self = self else { return }
            let items = results ?? []

            let sorted = items.sorted { a, b in
                let aDate = a.dueDateComponents?.date ?? Date.distantFuture
                let bDate = b.dueDateComponents?.date ?? Date.distantFuture
                return aDate < bDate
            }

            DispatchQueue.main.async {
                self.pendingCount = sorted.count
                self.reminders = sorted.prefix(8).map { ($0.title ?? "Untitled", $0.dueDateComponents?.date) }
                self.nextReminder = sorted.first?.title ?? ""
                if self.displayIndex >= self.reminders.count {
                    self.displayIndex = 0
                }
                self.onDisplayUpdate?()
            }
        }
    }

    func render() -> WidgetDisplayMode {
        guard hasAccess else { return .text("\u{2611}\u{FE0F} Grant Access") }

        if pendingCount == 0 {
            return .text("\u{2611}\u{FE0F} All done")
        }

        guard config.showNextTitle, !reminders.isEmpty else {
            if config.showCount {
                return .text("\u{2611}\u{FE0F} \(pendingCount) to-dos")
            }
            return .text("\u{2611}\u{FE0F} Pending")
        }

        let idx = displayIndex % reminders.count
        let title = reminders[idx].0
        let countPrefix = config.showCount ? "\(pendingCount): " : ""
        let text = "\u{2611}\u{FE0F} \(countPrefix)\(title)"

        if text.count > 28 {
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: Theme.textPrimary,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ])
            return .scrollingText(attr, width: 180)
        }
        return .text(text)
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "REMINDERS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard hasAccess else {
            let noAccess = NSMenuItem(title: "Grant reminders access in System Settings", action: nil, keyEquivalent: "")
            noAccess.isEnabled = false
            menu.addItem(noAccess)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
            return menu
        }

        if reminders.isEmpty {
            let done = NSMenuItem(title: "No pending reminders", action: nil, keyEquivalent: "")
            done.isEnabled = false
            menu.addItem(done)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"

            for (i, (title, dueDate)) in reminders.enumerated() {
                let dateStr = dueDate.map { formatter.string(from: $0) } ?? ""
                let prefix = dateStr.isEmpty ? "\u{25CB}" : "\u{25CB} \(dateStr):"
                let bullet = i == displayIndex ? "\u{25B6}" : " "
                let item = NSMenuItem(title: "\(bullet) \(prefix) \(title)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            if pendingCount > 8 {
                let more = NSMenuItem(title: "... and \(pendingCount - 8) more", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
        }

        if reminders.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle reminders", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Reminders", action: #selector(AppDelegate.openRemindersApp), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
