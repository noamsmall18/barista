import Cocoa

/// Spotlight-style command palette for quick widget search and actions.
/// Triggered by Cmd+Shift+Space.
class QuickActionsPanel: NSObject {
    private var window: NSWindow?
    private var searchField: NSTextField?
    private var resultsContainer: NSView?
    private var query = ""
    private var results: [QuickAction] = []
    private var selectedIndex = 0
    private var eventMonitor: Any?
    private let maxVisibleResults = 9

    struct QuickAction {
        let title: String
        let subtitle: String
        let icon: String
        let iconColor: NSColor
        let keywords: [String]
        let action: () -> Void

        init(
            title: String,
            subtitle: String,
            icon: String,
            iconColor: NSColor,
            keywords: [String] = [],
            action: @escaping () -> Void
        ) {
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.iconColor = iconColor
            self.keywords = keywords
            self.action = action
        }
    }

    var onDismiss: (() -> Void)?

    func toggle() {
        if window?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        let panelW: CGFloat = 540
        let panelH: CGFloat = 52  // starts small, grows with results

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = (screenFrame.width - panelW) / 2
        let y = screenFrame.height * 0.65

        window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: panelW, height: panelH),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        guard let window = window else { return }
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.08, green: 0.07, blue: 0.1, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowRadius = 30
        container.layer?.shadowOpacity = 0.6
        container.layer?.shadowOffset = CGSize(width: 0, height: -8)

        // Search icon
        if let searchImg = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            let searchIcon = NSImageView(frame: NSRect(x: 14, y: 16, width: 18, height: 18))
            searchIcon.image = searchImg
            searchIcon.contentTintColor = Theme.textMuted
            searchIcon.identifier = NSUserInterfaceItemIdentifier("searchIcon")
            container.addSubview(searchIcon)
        }

        // Search field
        let field = NSTextField(frame: NSRect(x: 38, y: 12, width: panelW - 52, height: 28))
        field.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        field.textColor = Theme.textPrimary
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Search widgets and actions..."
        field.placeholderAttributedString = NSAttributedString(
            string: "Search widgets and actions...",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: Theme.textFaint
            ]
        )
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.delegate = self
        searchField = field
        container.addSubview(field)

        // Results container (added below search)
        let rc = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: 0))
        rc.wantsLayer = true
        resultsContainer = rc
        container.addSubview(rc)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(field)

        query = ""
        selectedIndex = 0
        updateResults()

        // Remove any previous monitor to prevent stacking
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        // Monitor for escape key and arrow keys
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else { return event }
            if event.keyCode == 53 { // Escape
                self.dismiss()
                return nil
            }
            if event.keyCode == 125 { // Down arrow
                guard !self.results.isEmpty else { return nil }
                self.selectedIndex = min(self.selectedIndex + 1, self.results.count - 1)
                self.renderResults()
                return nil
            }
            if event.keyCode == 126 { // Up arrow
                guard !self.results.isEmpty else { return nil }
                self.selectedIndex = max(self.selectedIndex - 1, 0)
                self.renderResults()
                return nil
            }
            if event.keyCode == 36 { // Return
                if self.selectedIndex >= 0 && self.selectedIndex < self.results.count {
                    let action = self.results[self.selectedIndex].action
                    self.dismiss()
                    action()
                }
                return nil
            }
            return event
        }
    }

    func dismiss() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        onDismiss?()
    }

    @objc private func searchChanged(_ sender: NSTextField) {
        query = sender.stringValue
        selectedIndex = 0
        updateResults()
    }

    private func updateResults() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = Array(buildQuickActions().prefix(maxVisibleResults))
        } else {
            let all = buildQuickActions() + buildActiveWidgetActions() + buildWidgetActions()
            results = all
                .compactMap { action -> (QuickAction, Int)? in
                    let score = matchScore(for: action, query: trimmed)
                    return score > 0 ? (action, score) : nil
                }
                .sorted { lhs, rhs in
                    if lhs.1 == rhs.1 {
                        return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                    }
                    return lhs.1 > rhs.1
                }
                .map(\.0)
        }
        if results.count > maxVisibleResults {
            results = Array(results.prefix(maxVisibleResults))
        }
        selectedIndex = min(max(selectedIndex, 0), max(results.count - 1, 0))
        renderResults()
    }

    private func matchScore(for action: QuickAction, query rawQuery: String) -> Int {
        let q = rawQuery.lowercased()
        let terms = q.split(separator: " ").map(String.init)
        let title = action.title.lowercased()
        let subtitle = action.subtitle.lowercased()
        let keywords = action.keywords.map { $0.lowercased() }
        let corpus = ([title, subtitle] + keywords).joined(separator: " ")

        guard terms.allSatisfy({ corpus.contains($0) }) else { return 0 }

        var score = 10
        if title == q { score += 120 }
        if title.hasPrefix(q) { score += 80 }
        if title.contains(q) { score += 45 }
        if subtitle.contains(q) { score += 20 }
        if keywords.contains(q) { score += 35 }
        score += max(0, 24 - title.count / 4)
        return score
    }

    private func renderResults() {
        guard let window = window,
              let container = window.contentView,
              let rc = resultsContainer else { return }

        rc.subviews.forEach { $0.removeFromSuperview() }

        let panelW = container.frame.width
        let rowH: CGFloat = 42
        let emptyH: CGFloat = 58
        let resultsH = results.isEmpty ? emptyH : CGFloat(results.count) * rowH
        let totalH = 52 + resultsH + (results.isEmpty ? 0 : 8)

        // Resize window
        var frame = window.frame
        let oldH = frame.height
        frame.size.height = totalH
        frame.origin.y += oldH - totalH
        window.setFrame(frame, display: true, animate: false)
        container.frame = NSRect(x: 0, y: 0, width: panelW, height: totalH)

        rc.frame = NSRect(x: 0, y: 0, width: panelW, height: resultsH)

        if results.isEmpty {
            let row = NSView(frame: NSRect(x: 8, y: 8, width: panelW - 16, height: emptyH - 12))
            row.wantsLayer = true
            row.layer?.cornerRadius = 10
            row.layer?.backgroundColor = Theme.cardBg.cgColor

            if let img = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) {
                let iv = NSImageView(frame: NSRect(x: 12, y: 16, width: 18, height: 18))
                iv.image = img
                iv.contentTintColor = Theme.textFaint
                row.addSubview(iv)
            }

            let title = NSTextField(labelWithString: "No command found")
            title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            title.textColor = Theme.textSecondary
            title.frame = NSRect(x: 40, y: 22, width: panelW - 80, height: 16)
            row.addSubview(title)

            let sub = NSTextField(labelWithString: "Try widget names, categories, presets, or settings.")
            sub.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
            sub.textColor = Theme.textFaint
            sub.frame = NSRect(x: 40, y: 8, width: panelW - 80, height: 14)
            row.addSubview(sub)

            rc.addSubview(row)
        }

        for (i, result) in results.enumerated() {
            let isSelected = i == selectedIndex
            let rowY = resultsH - CGFloat(i + 1) * rowH

            let row = NSView(frame: NSRect(x: 8, y: rowY, width: panelW - 16, height: rowH - 2))
            row.wantsLayer = true
            row.layer?.cornerRadius = 10
            row.layer?.backgroundColor = isSelected ? Theme.accent.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor

            // Icon
            if let img = NSImage(systemSymbolName: result.icon, accessibilityDescription: nil) {
                let iv = NSImageView(frame: NSRect(x: 10, y: 11, width: 18, height: 18))
                iv.image = img
                iv.contentTintColor = isSelected ? Theme.accent : result.iconColor
                row.addSubview(iv)
            }

            // Title
            let title = NSTextField(labelWithString: result.title)
            title.font = NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .medium)
            title.textColor = isSelected ? Theme.textPrimary : Theme.textSecondary
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 38, y: 13, width: panelW - 205, height: 18)
            row.addSubview(title)

            // Subtitle
            let sub = NSTextField(labelWithString: result.subtitle)
            sub.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            sub.textColor = Theme.textFaint
            sub.alignment = .right
            sub.lineBreakMode = .byTruncatingTail
            sub.frame = NSRect(x: panelW - 182, y: 14, width: 152, height: 14)
            row.addSubview(sub)

            // Click handler
            let btn = NSButton(frame: row.bounds)
            btn.isBordered = false
            btn.isTransparent = true
            btn.target = self
            btn.action = #selector(resultClicked(_:))
            btn.tag = i
            row.addSubview(btn)

            rc.addSubview(row)
        }

        // Reposition search field and icon to top of resized container
        searchField?.frame.origin.y = totalH - 40
        if let searchIcon = container.subviews.first(where: { $0.identifier?.rawValue == "searchIcon" }) {
            searchIcon.frame.origin.y = totalH - 36
        }
    }

    @objc private func resultClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < results.count else { return }
        let action = results[idx].action
        dismiss()
        action()
    }

    private func buildQuickActions() -> [QuickAction] {
        var actions: [QuickAction] = []
        guard let delegate = NSApp.delegate as? AppDelegate else { return actions }
        let activeCount = delegate.statusBarController.widgetCount

        actions.append(
            QuickAction(
                title: "Open Command Center",
                subtitle: "\(activeCount) active widget\(activeCount == 1 ? "" : "s")",
                icon: "slider.horizontal.3",
                iconColor: Theme.brandAmber,
                keywords: ["settings", "preferences", "manage", "barista", "command center"],
                action: {
                    delegate.showSettingsWindow()
                }
            )
        )

        actions.append(
            QuickAction(
                title: "Open Widget Gallery",
                subtitle: "\(WidgetRegistry.shared.entries.count) widgets",
                icon: "square.grid.2x2",
                iconColor: Theme.brandCyan,
                keywords: ["add", "browse", "gallery", "widgets", "catalog"],
                action: {
                    delegate.gallerySearchText = ""
                    delegate.gallerySelectedCategory = nil
                    delegate.showSettingsWindow()
                }
            )
        )

        if let stockInstance = delegate.statusBarController.activeInstances.first(where: { $0.widgetID == "stock-ticker" }) {
            actions.append(
                QuickAction(
                    title: "Configure Market Ticker",
                    subtitle: "Finance widget",
                    icon: "chart.line.uptrend.xyaxis",
                    iconColor: Theme.green,
                    keywords: ["stocks", "ticker", "premarket", "portfolio", "watchlist", "quotes"],
                    action: {
                        delegate.expandedWidgets.insert(stockInstance.id)
                        delegate.showSettingsWindow()
                    }
                )
            )
            actions.append(
                QuickAction(
                    title: "Refresh Market Data",
                    subtitle: "Stocks & crypto",
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: Theme.brandCyan,
                    keywords: ["stocks", "ticker", "quotes", "premarket", "reload", "price"],
                    action: {
                        stockInstance.widget.refresh()
                        stockInstance.updateStatusItem()
                    }
                )
            )
        } else {
            actions.append(
                QuickAction(
                    title: "Add Market Ticker",
                    subtitle: "Stocks & crypto",
                    icon: "chart.line.uptrend.xyaxis",
                    iconColor: Theme.green,
                    keywords: ["stocks", "ticker", "finance", "premarket", "portfolio", "watchlist"],
                    action: {
                        if let id = delegate.statusBarController.addWidget(widgetID: "stock-ticker") {
                            delegate.expandedWidgets.insert(id)
                            delegate.showSettingsWindow()
                        }
                    }
                )
            )
        }

        actions.append(contentsOf: [
            QuickAction(
                title: "Save Current Layout",
                subtitle: "New profile",
                icon: "bookmark",
                iconColor: Theme.brandAmber,
                keywords: ["profile", "preset", "layout", "save", "snapshot"],
                action: {
                    delegate.saveCurrentProfile()
                }
            ),
            QuickAction(
                title: "Refresh All Widgets",
                subtitle: "Force refresh",
                icon: "arrow.clockwise",
                iconColor: Theme.brandCyan,
                keywords: ["reload", "sync", "update", "all"],
                action: {
                    delegate.statusBarController.refreshAll()
                }
            ),
            QuickAction(
                title: "Toggle Dark Mode",
                subtitle: "System appearance",
                icon: "circle.lefthalf.filled",
                iconColor: Theme.purple,
                keywords: ["appearance", "theme", "light", "dark", "system"],
                action: {
                    let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
                    if let appleScript = NSAppleScript(source: script) {
                        appleScript.executeAndReturnError(nil)
                    }
                }
            ),
            QuickAction(
                title: "Export Layout",
                subtitle: "Save to file",
                icon: "square.and.arrow.up",
                iconColor: Theme.brandAmber,
                keywords: ["profile", "backup", "share", "layout", "json"],
                action: {
                    ProfileExporter.exportCurrent(name: "My Barista Layout")
                }
            ),
            QuickAction(
                title: "Import Layout",
                subtitle: "Load from file",
                icon: "square.and.arrow.down",
                iconColor: Theme.brandCyan,
                keywords: ["profile", "restore", "layout", "json"],
                action: {
                    ProfileExporter.importProfile()
                }
            ),
        ])

        for (idx, preset) in ProfileManager.presets.enumerated() {
            let validCount = preset.widgetIDs.filter { WidgetRegistry.shared.entry(for: $0) != nil }.count
            let color = Theme.colorForCategory(
                WidgetRegistry.shared.entry(for: preset.widgetIDs.first ?? "")?.category ?? .utility
            )
            actions.append(
                QuickAction(
                    title: "Apply \(preset.name) Layout",
                    subtitle: "\(validCount) widgets",
                    icon: preset.icon,
                    iconColor: color,
                    keywords: ["profile", "preset", "layout", preset.name.lowercased()] + preset.widgetIDs,
                    action: {
                        delegate.activateProfilePreset(at: idx)
                    }
                )
            )
        }

        return actions
    }

    private func buildActiveWidgetActions() -> [QuickAction] {
        guard let delegate = NSApp.delegate as? AppDelegate else { return [] }
        return delegate.statusBarController.activeInstances.map { instance in
            QuickAction(
                title: "Configure \(instance.widget.displayName)",
                subtitle: "Active widget",
                icon: instance.widget.iconName,
                iconColor: Theme.colorForCategory(instance.widget.category),
                keywords: [
                    "configure",
                    "settings",
                    "active",
                    instance.widgetID,
                    instance.widget.category.rawValue.lowercased()
                ],
                action: {
                    delegate.expandedWidgets.insert(instance.id)
                    delegate.showSettingsWindow()
                }
            )
        }
    }

    private func buildWidgetActions() -> [QuickAction] {
        let registry = WidgetRegistry.shared
        return registry.entries.map { entry in
            let catColor = Theme.colorForCategory(entry.category)
            return QuickAction(
                title: entry.displayName,
                subtitle: "Add \(entry.category.rawValue) widget",
                icon: entry.iconName,
                iconColor: catColor,
                keywords: [
                    "add",
                    "widget",
                    entry.widgetID,
                    entry.category.rawValue.lowercased(),
                    entry.subtitle.lowercased()
                ],
                action: {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        if let existing = delegate.statusBarController.activeInstances.first(where: { $0.widgetID == entry.widgetID }),
                           !entry.allowsMultiple {
                            delegate.expandedWidgets.insert(existing.id)
                            delegate.showSettingsWindow()
                            return
                        }
                        if let id = delegate.statusBarController.addWidget(widgetID: entry.widgetID) {
                            delegate.expandedWidgets.insert(id)
                            delegate.showSettingsWindow()
                        } else {
                            delegate.showSettingsWindow()
                        }
                    }
                }
            )
        }
    }
}

extension QuickActionsPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            query = field.stringValue
            selectedIndex = 0
            updateResults()
        }
    }
}
