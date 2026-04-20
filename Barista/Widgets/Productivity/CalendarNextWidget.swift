import Cocoa
import EventKit

struct CalendarNextConfig: Codable, Equatable {
    var showTimeUntil: Bool
    var minuteWarning: Int
    var showAllDay: Bool

    static let `default` = CalendarNextConfig(
        showTimeUntil: true,
        minuteWarning: 5,
        showAllDay: false
    )
}

class CalendarNextWidget: BaristaWidget {
    static let widgetID = "calendar-next"
    static let displayName = "Next Meeting"
    static let subtitle = "Countdown to your next calendar event"
    static let iconName = "calendar"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CalendarNextConfig.default

    var config: CalendarNextConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 30 }

    private var timer: Timer?
    private let store = EKEventStore()
    private(set) var nextEvent: EKEvent?
    private(set) var currentEvent: EKEvent?
    private(set) var todayEvents: [EKEvent] = []
    private(set) var hasAccess = false

    required init(config: CalendarNextConfig) {
        self.config = config
    }

    func start() {
        requestAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchEvents()
            self?.onDisplayUpdate?()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                self?.hasAccess = granted
                DispatchQueue.main.async {
                    self?.fetchEvents()
                    self?.onDisplayUpdate?()
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                self?.hasAccess = granted
                DispatchQueue.main.async {
                    self?.fetchEvents()
                    self?.onDisplayUpdate?()
                }
            }
        }
    }

    private func fetchEvents() {
        guard hasAccess else { return }

        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: endOfDay) ?? endOfDay

        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: tomorrow, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay || config.showAllDay }
            .sorted { $0.startDate < $1.startDate }

        todayEvents = events

        // Find current event (happening now)
        currentEvent = events.first { event in
            !event.isAllDay && event.startDate <= now && event.endDate > now
        }

        // Find next upcoming event
        nextEvent = events.first { event in
            !event.isAllDay && event.startDate > now
        }
    }

    func render() -> WidgetDisplayMode {
        guard hasAccess else { return .text("Cal: Grant Access") }

        let now = Date()

        // Currently in a meeting
        if let current = currentEvent {
            let minsLeft = Int(current.endDate.timeIntervalSince(now) / 60)
            let title = current.title ?? "Meeting"
            let text = "NOW: \(title) (\(minsLeft)m left)"
            let attr = NSAttributedString(string: text, attributes: [
                .foregroundColor: Theme.red,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ])
            if text.count > 28 {
                return .scrollingText(attr, width: 200)
            }
            return .attributedText(attr)
        }

        // Upcoming meeting
        if let next = nextEvent {
            let minsUntil = Int(next.startDate.timeIntervalSince(now) / 60)
            let title = next.title ?? "Meeting"

            let text: String
            if config.showTimeUntil {
                let timeStr: String
                if minsUntil <= 0 {
                    timeStr = "now"
                } else if minsUntil < 60 {
                    timeStr = "\(minsUntil)m"
                } else {
                    let h = minsUntil / 60
                    let m = minsUntil % 60
                    timeStr = m > 0 ? "\(h)h \(m)m" : "\(h)h"
                }
                text = "\(title) in \(timeStr)"
            } else {
                text = title
            }

            // Urgent warning
            if minsUntil <= config.minuteWarning {
                let attr = NSAttributedString(string: text, attributes: [
                    .foregroundColor: Theme.brandAmber,
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
                ])
                if text.count > 28 {
                    return .scrollingText(attr, width: 200)
                }
                return .attributedText(attr)
            }

            if text.count > 28 {
                let attr = NSAttributedString(string: text, attributes: [
                    .foregroundColor: Theme.textPrimary,
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                ])
                return .scrollingText(attr, width: 200)
            }

            return .text(text)
        }

        return .text("No more meetings")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "CALENDAR", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard hasAccess else {
            let noAccess = NSMenuItem(title: "Grant calendar access in System Settings", action: nil, keyEquivalent: "")
            noAccess.isEnabled = false
            menu.addItem(noAccess)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
            return menu
        }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        // Current event
        if let current = currentEvent {
            let item = NSMenuItem(title: "\u{1F534} NOW: \(current.title ?? "Meeting")", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let endStr = formatter.string(from: current.endDate)
            let endsItem = NSMenuItem(title: "  Ends at \(endStr)", action: nil, keyEquivalent: "")
            endsItem.isEnabled = false
            menu.addItem(endsItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Upcoming events
        let upcoming = todayEvents.filter { !$0.isAllDay && $0.startDate > now }
        if upcoming.isEmpty && currentEvent == nil {
            let free = NSMenuItem(title: "No more meetings today", action: nil, keyEquivalent: "")
            free.isEnabled = false
            menu.addItem(free)
        } else {
            for event in upcoming.prefix(5) {
                let time = formatter.string(from: event.startDate)
                let minsUntil = Int(event.startDate.timeIntervalSince(now) / 60)
                let untilStr = minsUntil < 60 ? "in \(minsUntil)m" : "in \(minsUntil/60)h \(minsUntil%60)m"
                let item = NSMenuItem(title: "\(time) - \(event.title ?? "Event") (\(untilStr))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Calendar", action: #selector(AppDelegate.openCalendarApp), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
