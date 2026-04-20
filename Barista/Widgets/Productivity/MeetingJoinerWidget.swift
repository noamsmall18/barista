import Cocoa
import EventKit

struct MeetingJoinerConfig: Codable, Equatable {
    var minutesBefore: Int
    var showNotification: Bool
    var autoDetectLinks: Bool

    static let `default` = MeetingJoinerConfig(
        minutesBefore: 5,
        showNotification: true,
        autoDetectLinks: true
    )
}

class MeetingJoinerWidget: BaristaWidget {
    static let widgetID = "meeting-joiner"
    static let displayName = "Meeting Joiner"
    static let subtitle = "One-click join for Zoom, Meet & Teams"
    static let iconName = "video.fill"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = MeetingJoinerConfig.default

    var config: MeetingJoinerConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 30 }

    private var timer: Timer?
    private let store = EKEventStore()
    private(set) var hasAccess = false
    private(set) var nextMeeting: EKEvent?
    private(set) var meetingLink: String?
    private(set) var meetingPlatform: MeetingPlatform = .unknown
    private(set) var todayMeetings: [(event: EKEvent, link: String, platform: MeetingPlatform)] = []

    enum MeetingPlatform: String {
        case zoom = "Zoom"
        case googleMeet = "Meet"
        case teams = "Teams"
        case facetime = "FaceTime"
        case webex = "Webex"
        case slack = "Slack"
        case unknown = "Link"

        var icon: String {
            switch self {
            case .zoom: return "\u{1F4F9}"
            case .googleMeet: return "\u{1F4F9}"
            case .teams: return "\u{1F4AC}"
            case .facetime: return "\u{1F4DE}"
            case .webex: return "\u{1F4F9}"
            case .slack: return "\u{1F4AC}"
            case .unknown: return "\u{1F517}"
            }
        }
    }

    required init(config: MeetingJoinerConfig) {
        self.config = config
    }

    func start() {
        requestAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchMeetings()
            self?.onDisplayUpdate?()
        }
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
                    self?.fetchMeetings()
                    self?.onDisplayUpdate?()
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                self?.hasAccess = granted
                DispatchQueue.main.async {
                    self?.fetchMeetings()
                    self?.onDisplayUpdate?()
                }
            }
        }
    }

    // MARK: - Meeting Link Detection

    /// Regex patterns for video call links
    private static let linkPatterns: [(pattern: String, platform: MeetingPlatform)] = [
        ("https?://[\\w.-]*zoom\\.us/[jw]/\\S+", .zoom),
        ("https?://meet\\.google\\.com/[a-z-]+", .googleMeet),
        ("https?://teams\\.microsoft\\.com/l/meetup-join/\\S+", .teams),
        ("https?://teams\\.live\\.com/meet/\\S+", .teams),
        ("https?://facetime\\.apple\\.com/join\\S*", .facetime),
        ("https?://[\\w.-]*webex\\.com/\\S+", .webex),
        ("https?://app\\.slack\\.com/huddle/\\S+", .slack),
    ]

    private func extractMeetingLink(from event: EKEvent) -> (String, MeetingPlatform)? {
        // Check event URL first
        if let url = event.url?.absoluteString {
            for (pattern, platform) in Self.linkPatterns {
                if url.range(of: pattern, options: .regularExpression) != nil {
                    return (url, platform)
                }
            }
        }

        // Check notes/description
        let searchText = [event.notes, event.location].compactMap { $0 }.joined(separator: " ")
        for (pattern, platform) in Self.linkPatterns {
            if let range = searchText.range(of: pattern, options: .regularExpression) {
                return (String(searchText[range]), platform)
            }
        }

        // Check location field for simple URL
        if let location = event.location,
           location.hasPrefix("http"),
           let url = URL(string: location) {
            return (url.absoluteString, .unknown)
        }

        return nil
    }

    private func fetchMeetings() {
        guard hasAccess else { return }

        let now = Date()
        let cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now

        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-1800), end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Build meetings with links
        todayMeetings = []
        for event in events {
            if let (link, platform) = extractMeetingLink(from: event) {
                todayMeetings.append((event: event, link: link, platform: platform))
            }
        }

        // Find the most relevant next meeting with a link
        nextMeeting = nil
        meetingLink = nil
        meetingPlatform = .unknown

        for meeting in todayMeetings {
            let timeUntil = meeting.event.startDate.timeIntervalSince(now)
            let isOngoing = meeting.event.startDate <= now && meeting.event.endDate > now
            let isUpcoming = timeUntil > 0

            if isOngoing || isUpcoming {
                nextMeeting = meeting.event
                meetingLink = meeting.link
                meetingPlatform = meeting.platform
                break
            }
        }
    }

    // MARK: - Render

    func render() -> WidgetDisplayMode {
        guard hasAccess else { return .text("\u{1F4F9} Grant Access") }

        let now = Date()

        guard let meeting = nextMeeting else {
            return .text("\u{1F4F9} No meetings")
        }

        let isOngoing = meeting.startDate <= now && meeting.endDate > now
        let minsUntil = Int(meeting.startDate.timeIntervalSince(now) / 60)
        let title = (meeting.title ?? "Meeting").prefix(14)

        if isOngoing {
            let minsLeft = Int(meeting.endDate.timeIntervalSince(now) / 60)
            let text = "\(meetingPlatform.icon) JOIN: \(title) (\(minsLeft)m)"
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Theme.green
            ])
            return .attributedText(attr)
        }

        if minsUntil <= config.minutesBefore {
            let text = "\(meetingPlatform.icon) \(title) in \(minsUntil)m"
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Theme.brandAmber
            ])
            return .attributedText(attr)
        }

        let timeStr: String
        if minsUntil < 60 {
            timeStr = "\(minsUntil)m"
        } else {
            timeStr = "\(minsUntil / 60)h \(minsUntil % 60)m"
        }

        return .text("\(meetingPlatform.icon) \(title) in \(timeStr)")
    }

    // MARK: - Dropdown

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "MEETING JOINER", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        guard hasAccess else {
            let noAccess = NSMenuItem(title: "Grant calendar access in System Settings", action: nil, keyEquivalent: "")
            noAccess.isEnabled = false
            menu.addItem(noAccess)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return menu
        }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        if todayMeetings.isEmpty {
            let noMeetings = NSMenuItem(title: "No video meetings today", action: nil, keyEquivalent: "")
            noMeetings.isEnabled = false
            menu.addItem(noMeetings)
        }

        for (i, meeting) in todayMeetings.enumerated() {
            let time = formatter.string(from: meeting.event.startDate)
            let title = meeting.event.title ?? "Meeting"
            let isOngoing = meeting.event.startDate <= now && meeting.event.endDate > now

            let prefix = isOngoing ? "\u{1F7E2} NOW" : time
            let joinItem = NSMenuItem(
                title: "\(prefix) - \(meeting.platform.icon) \(title)",
                action: #selector(joinMeeting(_:)),
                keyEquivalent: i == 0 ? "j" : ""
            )
            joinItem.target = self
            joinItem.tag = i
            joinItem.isEnabled = true
            menu.addItem(joinItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Calendar", action: #selector(AppDelegate.openCalendarApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func joinMeeting(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < todayMeetings.count else { return }
        let link = todayMeetings[idx].link
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
