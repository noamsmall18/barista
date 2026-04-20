import Cocoa

struct DiceRollerConfig: Codable, Equatable {
    var sides: Int
    var diceCount: Int

    static let `default` = DiceRollerConfig(sides: 6, diceCount: 2)
}

class DiceRollerWidget: BaristaWidget, Cycleable {
    static let widgetID = "dice-roller"
    static let displayName = "Dice Roller"
    static let subtitle = "Roll dice with a click"
    static let iconName = "dice"
    static let category = WidgetCategory.funLifestyle
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = DiceRollerConfig.default

    var config: DiceRollerConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { nil }

    private var timer: Timer?
    private(set) var currentRoll: [Int] = []
    private(set) var rollHistory: [[Int]] = []

    // MARK: - Cycleable

    var itemCount: Int { 1 }
    var currentIndex: Int { 0 }
    var cycleInterval: TimeInterval { 0 }

    func cycleNext() {
        roll()
    }

    required init(config: DiceRollerConfig) {
        self.config = config
        roll()
    }

    func start() {
        if currentRoll.isEmpty {
            roll()
        }
        onDisplayUpdate?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func roll() {
        var dice: [Int] = []
        for _ in 0..<config.diceCount {
            dice.append(Int.random(in: 1...config.sides))
        }
        currentRoll = dice

        rollHistory.insert(dice, at: 0)
        if rollHistory.count > 5 {
            rollHistory = Array(rollHistory.prefix(5))
        }

        onDisplayUpdate?()
    }

    private var total: Int {
        currentRoll.reduce(0, +)
    }

    func render() -> WidgetDisplayMode {
        if currentRoll.isEmpty {
            return .text("\u{1F3B2} Roll")
        }
        return .text("\u{1F3B2} \(total)")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "DICE ROLLER", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if !currentRoll.isEmpty {
            let diceStr = currentRoll.map { String($0) }.joined(separator: ", ")
            let diceItem = NSMenuItem(title: "Dice: \(diceStr)", action: nil, keyEquivalent: "")
            diceItem.isEnabled = false
            menu.addItem(diceItem)

            let totalItem = NSMenuItem(title: "Total: \(total)", action: nil, keyEquivalent: "")
            totalItem.isEnabled = false
            menu.addItem(totalItem)

            let configItem = NSMenuItem(title: "\(config.diceCount)d\(config.sides)", action: nil, keyEquivalent: "")
            configItem.isEnabled = false
            menu.addItem(configItem)
        }

        if rollHistory.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let histHeader = NSMenuItem(title: "Recent Rolls", action: nil, keyEquivalent: "")
            histHeader.isEnabled = false
            menu.addItem(histHeader)

            for (i, roll) in rollHistory.enumerated() {
                let sum = roll.reduce(0, +)
                let diceStr = roll.map { String($0) }.joined(separator: ", ")
                let prefix = i == 0 ? "\u{25B6}" : " "
                let item = NSMenuItem(title: "\(prefix) [\(diceStr)] = \(sum)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let hint = NSMenuItem(title: "Click menu bar to roll", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
