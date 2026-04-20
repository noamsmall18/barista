import Cocoa

struct DiskSpaceConfig: Codable, Equatable {
    var showPercentage: Bool
    var warnBelowGB: Int

    static let `default` = DiskSpaceConfig(showPercentage: false, warnBelowGB: 20)
}

class DiskSpaceWidget: BaristaWidget {
    static let widgetID = "disk-space"
    static let displayName = "Disk Space"
    static let subtitle = "Free storage remaining on your Mac"
    static let iconName = "internaldrive"
    static let category = WidgetCategory.system
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = DiskSpaceConfig.default

    var config: DiskSpaceConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 300 }

    private var timer: Timer?
    private(set) var freeGB: Double = 0
    private(set) var totalGB: Double = 0
    private(set) var usedPercent: Double = 0

    required init(config: DiskSpaceConfig) {
        self.config = config
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            let total = (attrs[.systemSize] as? Int64) ?? 0
            let free = (attrs[.systemFreeSize] as? Int64) ?? 0
            totalGB = Double(total) / 1_073_741_824
            freeGB = Double(free) / 1_073_741_824
            usedPercent = totalGB > 0 ? ((totalGB - freeGB) / totalGB) * 100 : 0
        } catch {}
    }

    func render() -> WidgetDisplayMode {
        if config.showPercentage {
            let text = String(format: "%.0f%% used", usedPercent)
            if freeGB < Double(config.warnBelowGB) {
                let attr = NSAttributedString(string: "\u{1F4BE} \(text)", attributes: [
                    .foregroundColor: Theme.red,
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
                ])
                return .attributedText(attr)
            }
            return .text("\u{1F4BE} \(text)")
        }

        let freeStr = freeGB >= 100 ? String(format: "%.0f GB", freeGB) : String(format: "%.1f GB", freeGB)
        if freeGB < Double(config.warnBelowGB) {
            let attr = NSAttributedString(string: "\u{1F4BE} \(freeStr) free", attributes: [
                .foregroundColor: Theme.red,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ])
            return .attributedText(attr)
        }
        return .text("\u{1F4BE} \(freeStr) free")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "DISK SPACE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let items: [(String, String)] = [
            ("Total", String(format: "%.0f GB", totalGB)),
            ("Free", String(format: "%.1f GB", freeGB)),
            ("Used", String(format: "%.1f GB (%.0f%%)", totalGB - freeGB, usedPercent)),
        ]
        for (label, value) in items {
            let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Visual bar
        let filled = min(Int(usedPercent / 10), 10)
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: 10 - filled)
        let barItem = NSMenuItem(title: "[\(bar)]", action: nil, keyEquivalent: "")
        barItem.isEnabled = false
        menu.addItem(barItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }
}
