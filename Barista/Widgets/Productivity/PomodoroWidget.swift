import Cocoa

struct PomodoroConfig: Codable, Equatable {
    var workMinutes: Int
    var shortBreakMinutes: Int
    var longBreakMinutes: Int
    var cyclesBeforeLong: Int
    var autoStartBreak: Bool
    var showEmoji: Bool

    static let `default` = PomodoroConfig(
        workMinutes: 25,
        shortBreakMinutes: 5,
        longBreakMinutes: 15,
        cyclesBeforeLong: 4,
        autoStartBreak: true,
        showEmoji: true
    )
}

enum PomodoroState: String, Codable {
    case idle
    case working
    case shortBreak
    case longBreak
}

class PomodoroWidget: BaristaWidget {
    static let widgetID = "pomodoro"
    static let displayName = "Pomodoro Timer"
    static let subtitle = "Focus timer with work/break cycles"
    static let iconName = "timer"
    static let category = WidgetCategory.productivity
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = PomodoroConfig.default

    var config: PomodoroConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { nil }

    private var timer: Timer?
    private(set) var state: PomodoroState = .idle
    private(set) var secondsRemaining: Int = 0
    private(set) var completedCycles: Int = 0
    private(set) var totalFocusToday: Int = 0 // seconds

    required init(config: PomodoroConfig) {
        self.config = config
        // Restore today's focus time
        let key = "barista.pomodoro.focusToday"
        let savedDate = UserDefaults.standard.string(forKey: "barista.pomodoro.focusDate") ?? ""
        let today = dateString()
        if savedDate == today {
            totalFocusToday = UserDefaults.standard.integer(forKey: key)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard state != .idle else { return }

        secondsRemaining -= 1

        if state == .working {
            totalFocusToday += 1
            saveFocusTime()
        }

        if secondsRemaining <= 0 {
            handlePhaseComplete()
        }

        onDisplayUpdate?()
    }

    private func handlePhaseComplete() {
        switch state {
        case .working:
            completedCycles += 1
            if completedCycles % config.cyclesBeforeLong == 0 {
                if config.autoStartBreak {
                    startPhase(.longBreak)
                } else {
                    state = .idle
                }
            } else {
                if config.autoStartBreak {
                    startPhase(.shortBreak)
                } else {
                    state = .idle
                }
            }
        case .shortBreak, .longBreak:
            state = .idle
        case .idle:
            break
        }
    }

    func startWork() {
        startPhase(.working)
        onDisplayUpdate?()
    }

    func pauseResume() {
        if state == .idle {
            startWork()
        } else {
            state = .idle
            onDisplayUpdate?()
        }
    }

    func skipPhase() {
        handlePhaseComplete()
        onDisplayUpdate?()
    }

    func resetTimer() {
        state = .idle
        secondsRemaining = 0
        completedCycles = 0
        onDisplayUpdate?()
    }

    private func startPhase(_ phase: PomodoroState) {
        state = phase
        switch phase {
        case .working: secondsRemaining = config.workMinutes * 60
        case .shortBreak: secondsRemaining = config.shortBreakMinutes * 60
        case .longBreak: secondsRemaining = config.longBreakMinutes * 60
        case .idle: secondsRemaining = 0
        }
    }

    func render() -> WidgetDisplayMode {
        let emoji = config.showEmoji ? (state == .working ? "\u{1F345} " : state == .idle ? "\u{1F345} " : "\u{2615} ") : ""

        if state == .idle {
            if completedCycles > 0 {
                return .text("\(emoji)x\(completedCycles)")
            }
            return .text("\(emoji)Ready")
        }

        let min = secondsRemaining / 60
        let sec = secondsRemaining % 60
        let timeStr = String(format: "%d:%02d", min, sec)

        if state == .working && secondsRemaining < 60 {
            let font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let attr = NSAttributedString(string: "\(emoji)\(timeStr)", attributes: [
                .font: font,
                .foregroundColor: NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
            ])
            return .attributedText(attr)
        }

        return .text("\(emoji)\(timeStr)")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "POMODORO", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Status
        let stateStr: String
        switch state {
        case .idle: stateStr = "Idle"
        case .working: stateStr = "Working"
        case .shortBreak: stateStr = "Short Break"
        case .longBreak: stateStr = "Long Break"
        }
        let statusItem = NSMenuItem(title: "Status: \(stateStr)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if state != .idle {
            let min = secondsRemaining / 60
            let sec = secondsRemaining % 60
            let timeItem = NSMenuItem(title: String(format: "Time left: %d:%02d", min, sec), action: nil, keyEquivalent: "")
            timeItem.isEnabled = false
            menu.addItem(timeItem)
        }

        let cycleItem = NSMenuItem(title: "Completed: \(completedCycles) sessions", action: nil, keyEquivalent: "")
        cycleItem.isEnabled = false
        menu.addItem(cycleItem)

        let focusMin = totalFocusToday / 60
        let focusItem = NSMenuItem(title: "Focus today: \(focusMin)m", action: nil, keyEquivalent: "")
        focusItem.isEnabled = false
        menu.addItem(focusItem)

        menu.addItem(NSMenuItem.separator())

        // Controls
        if state == .idle {
            menu.addItem(NSMenuItem(title: "Start Focus", action: #selector(AppDelegate.pomodoroStart), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Stop", action: #selector(AppDelegate.pomodoroStop), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Skip Phase", action: #selector(AppDelegate.pomodoroSkip), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(AppDelegate.pomodoroReset), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }

    private func dateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func saveFocusTime() {
        UserDefaults.standard.set(totalFocusToday, forKey: "barista.pomodoro.focusToday")
        UserDefaults.standard.set(dateString(), forKey: "barista.pomodoro.focusDate")
    }
}
