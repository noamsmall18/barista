import Cocoa

struct WorldClockConfig: Codable, Equatable {
    var timezoneIDs: [String]
    var labels: [String]
    var use24Hour: Bool
    var showFlags: Bool
    var showSeconds: Bool
    var compactMode: Bool

    static let `default` = WorldClockConfig(
        timezoneIDs: ["America/New_York", "Europe/London", "Asia/Tokyo"],
        labels: ["NYC", "LON", "TYO"],
        use24Hour: false,
        showFlags: false,
        showSeconds: false,
        compactMode: false
    )
}

class WorldClockWidget: BaristaWidget, Cycleable, InteractiveDropdown {
    static let widgetID = "world-clock"
    static let displayName = "World Clock"
    static let subtitle = "Time across multiple zones"
    static let iconName = "clock"
    static let category = WidgetCategory.timeCalendar
    static let allowsMultiple = true
    static let isPremium = false
    static let defaultConfig = WorldClockConfig.default

    var config: WorldClockConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 1 }

    private var timer: Timer?
    private(set) var displayIndex: Int = 0

    // MARK: - Cycleable

    var itemCount: Int { config.timezoneIDs.count }
    var currentIndex: Int { displayIndex }
    var cycleInterval: TimeInterval { 4 }

    func cycleNext() {
        guard config.timezoneIDs.count > 1 else { return }
        displayIndex = (displayIndex + 1) % config.timezoneIDs.count
        onDisplayUpdate?()
    }

    required init(config: WorldClockConfig) {
        self.config = config
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.onDisplayUpdate?()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func render() -> WidgetDisplayMode {
        let now = Date()

        if config.compactMode {
            // Compact mode: show all zones in one line
            var parts: [String] = []
            for (i, tzID) in config.timezoneIDs.enumerated() {
                guard let tz = TimeZone(identifier: tzID) else { continue }
                let label = i < config.labels.count ? config.labels[i] : String(tzID.split(separator: "/").last ?? "")
                let timeStr = formatTime(for: tz, date: now)
                if config.showFlags {
                    parts.append("\(flagForTimezone(tzID)) \(timeStr)")
                } else {
                    parts.append("\(label) \(timeStr)")
                }
            }
            return .text(parts.joined(separator: " | "))
        }

        // Cycling mode: show one zone at a time
        let idx = displayIndex % max(config.timezoneIDs.count, 1)
        guard idx < config.timezoneIDs.count else { return .text("No zones") }

        let tzID = config.timezoneIDs[idx]
        guard let tz = TimeZone(identifier: tzID) else { return .text("Invalid zone") }

        let label = idx < config.labels.count ? config.labels[idx] : String(tzID.split(separator: "/").last ?? "")
        let timeStr = formatTime(for: tz, date: now)

        let prefix = config.showFlags ? flagForTimezone(tzID) : label
        return .text("\(prefix) \(timeStr)")
    }

    private func formatTime(for tz: TimeZone, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = tz
        if config.use24Hour {
            formatter.dateFormat = config.showSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            formatter.dateFormat = config.showSeconds ? "h:mm:ss a" : "h:mma"
        }
        return formatter.string(from: date).lowercased()
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let now = Date()

        let header = NSMenuItem(title: "WORLD CLOCK", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for (i, tzID) in config.timezoneIDs.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            let label = i < config.labels.count ? config.labels[i] : String(tzID.split(separator: "/").last ?? "")
            let flag = flagForTimezone(tzID)

            let formatter = DateFormatter()
            formatter.timeZone = tz
            formatter.dateFormat = "h:mm:ss a"
            let timeStr = formatter.string(from: now)

            formatter.dateFormat = "EEE, MMM d"
            let dateStr = formatter.string(from: now)

            let offset = tz.secondsFromGMT(for: now)
            let hours = offset / 3600
            let mins = abs(offset % 3600) / 60
            let utcStr = mins > 0 ? String(format: "UTC%+d:%02d", hours, mins) : String(format: "UTC%+d", hours)

            let bullet = i == displayIndex ? "\u{25B6}" : " "
            let title = "\(bullet) \(flag) \(label)    \(timeStr)    \(dateStr)    \(utcStr)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if config.timezoneIDs.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let hint = NSMenuItem(title: "Click menu bar to cycle zones", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy All Times", action: #selector(copyTimes), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ",")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func copyTimes() {
        let now = Date()
        var lines: [String] = []
        for (i, tzID) in config.timezoneIDs.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            let label = i < config.labels.count ? config.labels[i] : String(tzID.split(separator: "/").last ?? "")
            let formatter = DateFormatter()
            formatter.timeZone = tz
            formatter.dateFormat = "h:mm a, EEE MMM d"
            lines.append("\(label): \(formatter.string(from: now))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] {
        return []
    }

    // MARK: - Interactive Dropdown (Time Scroller)

    /// Offset hours from the time scroller (0 = now)
    private var scrollerOffset: Int = 0

    func buildDropdownPopover() -> NSView {
        let width: CGFloat = 360
        let rowH: CGFloat = 36
        let padding: CGFloat = 16
        let zoneCount = CGFloat(config.timezoneIDs.count)
        let height = padding + 28 + 8 + zoneCount * rowH + 16 + 44 + 16 + padding

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        let now = Date()
        let displayDate = Calendar.current.date(byAdding: .hour, value: scrollerOffset, to: now) ?? now

        var y = height - padding

        // Title + date
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        let dateStr = scrollerOffset == 0 ? "Now" : formatter.string(from: displayDate)
        let offsetStr = scrollerOffset == 0 ? "" : " (\(scrollerOffset > 0 ? "+" : "")\(scrollerOffset)h)"

        let title = NSTextField(labelWithString: "World Clock - \(dateStr)\(offsetStr)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.textPrimary
        title.frame = NSRect(x: padding, y: y - 18, width: width - padding * 2, height: 18)
        container.addSubview(title)
        y -= 28

        // Zone rows
        for (i, tzID) in config.timezoneIDs.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            let label = i < config.labels.count ? config.labels[i] : String(tzID.split(separator: "/").last ?? "")
            let flag = flagForTimezone(tzID)
            let isActive = i == displayIndex

            // Background highlight for active
            if isActive {
                let highlight = NSView(frame: NSRect(x: padding - 4, y: y - rowH + 4, width: width - padding * 2 + 8, height: rowH - 2))
                highlight.wantsLayer = true
                highlight.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.08).cgColor
                highlight.layer?.cornerRadius = 6
                container.addSubview(highlight)
            }

            // Flag + Name
            let nameLabel = NSTextField(labelWithString: "\(flag) \(label)")
            nameLabel.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
            nameLabel.textColor = isActive ? Theme.accent : Theme.textPrimary
            nameLabel.frame = NSRect(x: padding + 4, y: y - 18, width: 120, height: 18)
            container.addSubview(nameLabel)

            // Time
            let timeFormatter = DateFormatter()
            timeFormatter.timeZone = tz
            timeFormatter.dateFormat = config.use24Hour ? "HH:mm" : "h:mm a"
            let timeStr = timeFormatter.string(from: displayDate)

            let timeLabel = NSTextField(labelWithString: timeStr)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            timeLabel.textColor = isActive ? Theme.accent : Theme.textSecondary
            timeLabel.alignment = .right
            timeLabel.frame = NSRect(x: width - padding - 140, y: y - 18, width: 80, height: 18)
            container.addSubview(timeLabel)

            // Date + UTC offset
            let dateFormatter = DateFormatter()
            dateFormatter.timeZone = tz
            dateFormatter.dateFormat = "EEE d"
            let dayStr = dateFormatter.string(from: displayDate)

            let offset = tz.secondsFromGMT(for: displayDate)
            let hrs = offset / 3600
            let utcStr = String(format: "UTC%+d", hrs)

            let detailLabel = NSTextField(labelWithString: "\(dayStr) | \(utcStr)")
            detailLabel.font = .systemFont(ofSize: 10)
            detailLabel.textColor = Theme.textMuted
            detailLabel.alignment = .right
            detailLabel.frame = NSRect(x: width - padding - 56, y: y - 18, width: 56, height: 18)
            container.addSubview(detailLabel)

            y -= rowH
        }

        y -= 8

        // Time scroller
        let divider = NSView(frame: NSRect(x: padding, y: y, width: width - padding * 2, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        container.addSubview(divider)
        y -= 12

        let scrubLabel = NSTextField(labelWithString: "TIME TRAVEL")
        scrubLabel.font = .systemFont(ofSize: 9, weight: .medium)
        scrubLabel.textColor = Theme.textMuted
        scrubLabel.frame = NSRect(x: padding, y: y - 12, width: 100, height: 12)
        container.addSubview(scrubLabel)
        y -= 16

        // Slider: -24h to +24h
        let slider = NSSlider(frame: NSRect(x: padding, y: y - 20, width: width - padding * 2 - 60, height: 20))
        slider.minValue = -24
        slider.maxValue = 24
        slider.doubleValue = Double(scrollerOffset)
        slider.target = self
        slider.action = #selector(scrollerChanged(_:))
        slider.isContinuous = true
        container.addSubview(slider)

        // Reset button
        let resetBtn = NSButton(frame: NSRect(x: width - padding - 50, y: y - 22, width: 50, height: 24))
        resetBtn.title = "Now"
        resetBtn.bezelStyle = .inline
        resetBtn.font = .systemFont(ofSize: 10, weight: .medium)
        resetBtn.target = self
        resetBtn.action = #selector(resetScroller)
        container.addSubview(resetBtn)

        return container
    }

    var dropdownSize: NSSize {
        let rowH: CGFloat = 36
        let padding: CGFloat = 16
        let zoneCount = CGFloat(config.timezoneIDs.count)
        let height = padding + 28 + 8 + zoneCount * rowH + 16 + 44 + 16 + padding
        return NSSize(width: 360, height: max(height, 200))
    }

    @objc private func scrollerChanged(_ sender: NSSlider) {
        scrollerOffset = Int(sender.doubleValue)
        onDisplayUpdate?()
    }

    @objc private func resetScroller() {
        scrollerOffset = 0
        onDisplayUpdate?()
    }

    private func flagForTimezone(_ tzID: String) -> String {
        let countryMap: [String: String] = [
            "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US",
            "America/Los_Angeles": "US", "America/Anchorage": "US", "Pacific/Honolulu": "US",
            "Europe/London": "GB", "Europe/Paris": "FR", "Europe/Berlin": "DE",
            "Europe/Rome": "IT", "Europe/Madrid": "ES", "Europe/Amsterdam": "NL",
            "Europe/Zurich": "CH", "Europe/Stockholm": "SE", "Europe/Oslo": "NO",
            "Europe/Moscow": "RU", "Europe/Istanbul": "TR",
            "Asia/Tokyo": "JP", "Asia/Shanghai": "CN", "Asia/Hong_Kong": "HK",
            "Asia/Seoul": "KR", "Asia/Singapore": "SG", "Asia/Dubai": "AE",
            "Asia/Kolkata": "IN", "Asia/Bangkok": "TH",
            "Australia/Sydney": "AU", "Pacific/Auckland": "NZ",
            "America/Toronto": "CA", "America/Sao_Paulo": "BR",
            "America/Mexico_City": "MX", "Africa/Johannesburg": "ZA",
            "Asia/Jerusalem": "IL", "Asia/Taipei": "TW",
        ]

        guard let code = countryMap[tzID] else { return "\u{1F310}" }
        let base: UInt32 = 127397
        let flag = code.unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }.map(String.init).joined()
        return flag
    }
}
