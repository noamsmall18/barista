import Cocoa

/// 4-step onboarding flow:
/// 1. Welcome - animated logo + tagline
/// 2. Pick a Style - preset profiles with live mock menu bar
/// 3. Customize - category-tabbed widget grid with live preview
/// 4. All Set - confirmation with final lineup
class OnboardingController {

    private var window: NSWindow?
    private var contentContainer: NSView?
    private var currentStep = 0
    private let totalSteps = 4

    // State
    private var selectedPresetIndex: Int? = nil
    private var selectedWidgets: Set<String> = []
    private var selectedCategory: WidgetCategory? = nil
    private let maxWidgets = 8

    // Callbacks
    var onFinish: ((Set<String>) -> Void)?

    private let presets = ProfileManager.presets
    private let registry = WidgetRegistry.shared

    // Layout constants
    private let winW: CGFloat = 600
    private let winH: CGFloat = 480
    private let pad: CGFloat = 32
    private let mockBarH: CGFloat = 28

    // MARK: - Show

    func show() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        window = NSWindow(
            contentRect: NSRect(
                x: (screenFrame.width - winW) / 2,
                y: (screenFrame.height - winH) / 2,
                width: winW, height: winH
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        guard let window = window else { return }
        window.title = "Welcome to Barista"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        let tint = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(red: 0.04, green: 0.03, blue: 0.06, alpha: 0.45).cgColor
        tint.autoresizingMask = [.width, .height]
        visualEffect.addSubview(tint)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        container.wantsLayer = true
        contentContainer = container
        visualEffect.addSubview(container)

        window.contentView = visualEffect
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        currentStep = 0
        showStep(0, animate: false)
    }

    func close() {
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Step Navigation

    private func showStep(_ step: Int, animate: Bool = true) {
        guard let container = contentContainer else { return }
        currentStep = step

        if animate {
            let snapshot = container.snapshot()
            let overlay = NSImageView(frame: container.bounds)
            overlay.image = snapshot
            overlay.autoresizingMask = [.width, .height]

            container.subviews.forEach { $0.removeFromSuperview() }
            buildStep(step, in: container)

            container.addSubview(overlay)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                overlay.removeFromSuperview()
            })
        } else {
            container.subviews.forEach { $0.removeFromSuperview() }
            buildStep(step, in: container)
        }
    }

    private func buildStep(_ step: Int, in container: NSView) {
        switch step {
        case 0: buildWelcome(in: container)
        case 1: buildPickStyle(in: container)
        case 2: buildCustomize(in: container)
        case 3: buildAllSet(in: container)
        default: break
        }
    }

    // MARK: - Step 0: Welcome

    private func buildWelcome(in container: NSView) {
        let centerX = winW / 2
        let centerY = winH / 2

        // App icon
        let logoSize: CGFloat = 96
        let logoView = NSImageView(frame: NSRect(x: centerX - logoSize / 2, y: centerY + 30, width: logoSize, height: logoSize))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            logoView.image = appIcon
            logoView.imageScaling = .scaleProportionallyUpOrDown
        }
        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 22
        logoView.layer?.masksToBounds = false
        Theme.applyGlow(to: logoView.layer!, color: Theme.brandAmber, radius: 20)
        logoView.alphaValue = 0
        container.addSubview(logoView)

        // Title
        let title = NSTextField(labelWithString: "Welcome to Barista")
        title.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center
        title.frame = NSRect(x: pad, y: centerY - 20, width: winW - pad * 2, height: 34)
        title.alphaValue = 0
        container.addSubview(title)

        // Subtitle
        let sub = NSTextField(labelWithString: "Your menu bar, your way")
        sub.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        sub.textColor = Theme.textMuted
        sub.alignment = .center
        sub.frame = NSRect(x: pad, y: centerY - 52, width: winW - pad * 2, height: 20)
        sub.alphaValue = 0
        container.addSubview(sub)

        // Get Started button
        let btnW: CGFloat = 180
        let btnH: CGFloat = 44
        let btn = NSButton(frame: NSRect(x: centerX - btnW / 2, y: centerY - 120, width: btnW, height: btnH))
        btn.wantsLayer = true
        btn.bezelStyle = .rounded
        btn.isBordered = false
        btn.title = "Get Started"
        btn.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        btn.contentTintColor = NSColor.black
        btn.layer?.backgroundColor = Theme.brandAmber.cgColor
        btn.layer?.cornerRadius = btnH / 2
        btn.target = self
        btn.action = #selector(nextStep)
        btn.alphaValue = 0
        container.addSubview(btn)

        // Step dots
        addStepDots(to: container, current: 0, y: 36)

        // Animate in
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            logoView.animator().alphaValue = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                title.animator().alphaValue = 1
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                sub.animator().alphaValue = 1
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                btn.animator().alphaValue = 1
            })
        }
    }

    // MARK: - Step 1: Pick a Style

    private func buildPickStyle(in container: NSView) {
        var y = winH - 50

        let title = NSTextField(labelWithString: "Pick a Style")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center
        title.frame = NSRect(x: pad, y: y - 28, width: winW - pad * 2, height: 28)
        container.addSubview(title)
        y -= 40

        let sub = NSTextField(labelWithString: "Choose a preset to start with - you can customize next")
        sub.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        sub.textColor = Theme.textMuted
        sub.alignment = .center
        sub.frame = NSRect(x: pad, y: y - 18, width: winW - pad * 2, height: 18)
        container.addSubview(sub)
        y -= 36

        // Mock menu bar strip
        let mockBar = buildMockMenuBar(widgets: currentPresetWidgetIDs())
        mockBar.frame = NSRect(x: pad, y: y - mockBarH, width: winW - pad * 2, height: mockBarH)
        mockBar.identifier = NSUserInterfaceItemIdentifier("mockBar")
        container.addSubview(mockBar)
        y -= mockBarH + 20

        // Preset cards
        let cardW: CGFloat = (winW - pad * 2 - 12) / 2
        let cardH: CGFloat = 72

        for (i, preset) in presets.enumerated() {
            let col = i % 2
            let row = i / 2
            let cx = pad + CGFloat(col) * (cardW + 12)
            let cy = y - CGFloat(row) * (cardH + 10) - cardH

            let isSelected = selectedPresetIndex == i
            let card = NSView(frame: NSRect(x: cx, y: cy, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.backgroundColor = isSelected ? Theme.accent.withAlphaComponent(0.12).cgColor : Theme.cardBg.cgColor
            card.layer?.cornerRadius = 14
            card.layer?.borderWidth = isSelected ? 1.5 : 0.5
            card.layer?.borderColor = isSelected ? Theme.accent.withAlphaComponent(0.6).cgColor : Theme.cardBorder.cgColor

            // Icon
            if let img = NSImage(systemSymbolName: preset.icon, accessibilityDescription: nil) {
                let iv = NSImageView(frame: NSRect(x: 14, y: cardH / 2 - 12, width: 24, height: 24))
                iv.image = img
                iv.contentTintColor = isSelected ? Theme.accent : Theme.textMuted
                iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                card.addSubview(iv)
            }

            // Name
            let nameLabel = NSTextField(labelWithString: preset.name)
            nameLabel.font = NSFont.systemFont(ofSize: 14, weight: isSelected ? .semibold : .medium)
            nameLabel.textColor = isSelected ? Theme.textPrimary : Theme.textSecondary
            nameLabel.frame = NSRect(x: 46, y: cardH / 2 + 2, width: cardW - 60, height: 18)
            card.addSubview(nameLabel)

            // Widget count
            let countLabel = NSTextField(labelWithString: "\(preset.widgetIDs.count) widgets")
            countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = Theme.textMuted
            countLabel.frame = NSRect(x: 46, y: cardH / 2 - 16, width: cardW - 60, height: 14)
            card.addSubview(countLabel)

            // Checkmark
            if isSelected {
                let check = NSTextField(labelWithString: "\u{2713}")
                check.font = NSFont.systemFont(ofSize: 16, weight: .bold)
                check.textColor = Theme.accent
                check.alignment = .center
                check.frame = NSRect(x: cardW - 30, y: cardH / 2 - 10, width: 20, height: 20)
                card.addSubview(check)
            }

            // Click handler
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: cardW, height: cardH))
            btn.isBordered = false
            btn.isTransparent = true
            btn.target = self
            btn.action = #selector(presetTapped(_:))
            btn.tag = i
            card.addSubview(btn)

            container.addSubview(card)
        }

        let gridRows = (presets.count + 1) / 2
        y -= CGFloat(gridRows) * (cardH + 10) + 10

        // Navigation buttons
        addNavButtons(to: container, y: 50, showBack: true, nextTitle: "Customize", nextEnabled: selectedPresetIndex != nil)
        addStepDots(to: container, current: 1, y: 36)
    }

    // MARK: - Step 2: Customize

    private func buildCustomize(in container: NSView) {
        var y = winH - 50

        let title = NSTextField(labelWithString: "Customize Your Picks")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center
        title.frame = NSRect(x: pad, y: y - 28, width: winW - pad * 2, height: 28)
        container.addSubview(title)
        y -= 38

        // Counter
        let counter = NSTextField(labelWithString: "\(selectedWidgets.count) of \(maxWidgets) widgets")
        counter.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        counter.textColor = selectedWidgets.count >= maxWidgets ? Theme.brandAmber : Theme.textMuted
        counter.alignment = .right
        counter.frame = NSRect(x: winW - pad - 140, y: y - 16, width: 130, height: 16)
        container.addSubview(counter)

        // Mock menu bar strip
        let mockBar = buildMockMenuBar(widgets: Array(selectedWidgets))
        mockBar.frame = NSRect(x: pad, y: y - 16 - mockBarH + 2, width: winW - pad * 2 - 140, height: mockBarH)
        mockBar.identifier = NSUserInterfaceItemIdentifier("mockBar")
        container.addSubview(mockBar)
        y -= mockBarH + 12

        // Category tabs
        let categories = relevantCategories()
        let tabScrollView = NSScrollView(frame: NSRect(x: pad, y: y - 26, width: winW - pad * 2, height: 26))
        tabScrollView.hasVerticalScroller = false
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.drawsBackground = false

        let tabContainer = NSView(frame: NSRect(x: 0, y: 0, width: max(winW - pad * 2, CGFloat(categories.count) * 90), height: 26))

        var tx: CGFloat = 0
        // "All" tab
        let allTab = makeCategoryTab(title: "All", isSelected: selectedCategory == nil, tag: -1)
        allTab.frame.origin = NSPoint(x: tx, y: 0)
        tabContainer.addSubview(allTab)
        tx += allTab.frame.width + 6

        for (i, cat) in categories.enumerated() {
            let tab = makeCategoryTab(title: cat.rawValue, isSelected: selectedCategory == cat, tag: i)
            tab.frame.origin = NSPoint(x: tx, y: 0)
            tabContainer.addSubview(tab)
            tx += tab.frame.width + 6
        }
        tabContainer.frame.size.width = tx
        tabScrollView.documentView = tabContainer
        container.addSubview(tabScrollView)
        y -= 36

        // Widget grid (scrollable)
        let gridH = y - 80
        let scrollView = NSScrollView(frame: NSRect(x: pad, y: 76, width: winW - pad * 2, height: gridH))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        let gridContent = NSView()
        let cardW: CGFloat = (winW - pad * 2 - 12) / 3
        let cardH: CGFloat = 56

        let filteredEntries = widgetsForCurrentCategory()
        let totalRows = (filteredEntries.count + 2) / 3
        let contentH = max(CGFloat(totalRows) * (cardH + 8) + 8, gridH)
        gridContent.frame = NSRect(x: 0, y: 0, width: winW - pad * 2, height: contentH)

        for (i, entry) in filteredEntries.enumerated() {
            let col = i % 3
            let row = i / 3
            let cx = CGFloat(col) * (cardW + 6)
            let cy = contentH - CGFloat(row + 1) * (cardH + 8)
            let isSelected = selectedWidgets.contains(entry.widgetID)

            let card = NSView(frame: NSRect(x: cx, y: cy, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.backgroundColor = isSelected ? Theme.accent.withAlphaComponent(0.10).cgColor : Theme.cardBg.cgColor
            card.layer?.cornerRadius = 10
            card.layer?.borderWidth = isSelected ? 1.2 : 0.5
            card.layer?.borderColor = isSelected ? Theme.accent.withAlphaComponent(0.5).cgColor : Theme.cardBorder.cgColor

            // Category color dot
            let dot = NSView(frame: NSRect(x: 10, y: cardH / 2 + 6, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = Theme.colorForCategory(entry.category).cgColor
            card.addSubview(dot)

            // Icon
            if let img = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: nil) {
                let iv = NSImageView(frame: NSRect(x: 8, y: cardH / 2 - 14, width: 16, height: 16))
                iv.image = img
                iv.contentTintColor = isSelected ? Theme.accent : Theme.textMuted
                card.addSubview(iv)
            }

            // Name
            let nameLabel = NSTextField(labelWithString: entry.displayName)
            nameLabel.font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .medium)
            nameLabel.textColor = isSelected ? Theme.textPrimary : Theme.textSecondary
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.frame = NSRect(x: 28, y: cardH / 2 - 2, width: cardW - 52, height: 16)
            card.addSubview(nameLabel)

            // Subtitle
            let subLabel = NSTextField(labelWithString: entry.subtitle)
            subLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            subLabel.textColor = Theme.textFaint
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.frame = NSRect(x: 28, y: cardH / 2 - 16, width: cardW - 52, height: 12)
            card.addSubview(subLabel)

            // Checkmark
            if isSelected {
                let check = NSTextField(labelWithString: "\u{2713}")
                check.font = NSFont.systemFont(ofSize: 12, weight: .bold)
                check.textColor = Theme.accent
                check.alignment = .center
                check.frame = NSRect(x: cardW - 22, y: cardH / 2 - 8, width: 16, height: 16)
                card.addSubview(check)
            }

            // Click handler
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: cardW, height: cardH))
            btn.isBordered = false
            btn.isTransparent = true
            btn.target = self
            btn.action = #selector(widgetTapped(_:))
            btn.identifier = NSUserInterfaceItemIdentifier("w:\(entry.widgetID)")
            card.addSubview(btn)

            gridContent.addSubview(card)
        }

        scrollView.documentView = gridContent
        container.addSubview(scrollView)

        // Navigation
        addNavButtons(to: container, y: 50, showBack: true, nextTitle: "Finish", nextEnabled: !selectedWidgets.isEmpty)
        addStepDots(to: container, current: 2, y: 36)
    }

    // MARK: - Step 3: All Set

    private func buildAllSet(in container: NSView) {
        let centerX = winW / 2
        let centerY = winH / 2

        // Checkmark circle
        let circleSize: CGFloat = 72
        let circle = NSView(frame: NSRect(x: centerX - circleSize / 2, y: centerY + 50, width: circleSize, height: circleSize))
        circle.wantsLayer = true
        circle.layer?.cornerRadius = circleSize / 2
        circle.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.15).cgColor
        circle.layer?.borderWidth = 2
        circle.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor

        let checkLabel = NSTextField(labelWithString: "\u{2713}")
        checkLabel.font = NSFont.systemFont(ofSize: 32, weight: .bold)
        checkLabel.textColor = Theme.brandAmber
        checkLabel.alignment = .center
        checkLabel.frame = NSRect(x: 0, y: 14, width: circleSize, height: 40)
        circle.addSubview(checkLabel)
        circle.alphaValue = 0
        container.addSubview(circle)

        // Title
        let title = NSTextField(labelWithString: "You're All Set!")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center
        title.frame = NSRect(x: pad, y: centerY + 10, width: winW - pad * 2, height: 30)
        title.alphaValue = 0
        container.addSubview(title)

        // Subtitle
        let sub = NSTextField(labelWithString: "Your menu bar is ready with \(selectedWidgets.count) widgets")
        sub.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        sub.textColor = Theme.textMuted
        sub.alignment = .center
        sub.frame = NSRect(x: pad, y: centerY - 16, width: winW - pad * 2, height: 20)
        sub.alphaValue = 0
        container.addSubview(sub)

        // Mock menu bar showing final lineup
        let mockBar = buildMockMenuBar(widgets: Array(selectedWidgets))
        mockBar.frame = NSRect(x: pad + 20, y: centerY - 60, width: winW - pad * 2 - 40, height: mockBarH)
        mockBar.alphaValue = 0
        container.addSubview(mockBar)

        // Open Barista button
        let btnW: CGFloat = 200
        let btnH: CGFloat = 44
        let btn = NSButton(frame: NSRect(x: centerX - btnW / 2, y: centerY - 130, width: btnW, height: btnH))
        btn.wantsLayer = true
        btn.bezelStyle = .rounded
        btn.isBordered = false
        btn.title = "Open Barista"
        btn.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        btn.contentTintColor = NSColor.black
        btn.layer?.backgroundColor = Theme.brandAmber.cgColor
        btn.layer?.cornerRadius = btnH / 2
        btn.target = self
        btn.action = #selector(finishOnboarding)
        btn.alphaValue = 0
        container.addSubview(btn)

        // Open Settings link
        let settingsLink = NSButton(frame: NSRect(x: centerX - 60, y: centerY - 166, width: 120, height: 20))
        settingsLink.isBordered = false
        settingsLink.title = ""
        let linkAttr = NSAttributedString(string: "Open Settings", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Theme.textMuted,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        settingsLink.attributedTitle = linkAttr
        settingsLink.target = self
        settingsLink.action = #selector(openSettingsFromOnboarding)
        settingsLink.alphaValue = 0
        container.addSubview(settingsLink)

        addStepDots(to: container, current: 3, y: 36)

        // Staggered animate in
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            circle.animator().alphaValue = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                title.animator().alphaValue = 1
                sub.animator().alphaValue = 1
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                mockBar.animator().alphaValue = 1
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                btn.animator().alphaValue = 1
                settingsLink.animator().alphaValue = 1
            })
        }
    }

    // MARK: - Mock Menu Bar

    private func buildMockMenuBar(widgets: [String]) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.9).cgColor
        bar.layer?.cornerRadius = 6
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = Theme.glassBorder.cgColor

        var x: CGFloat = 10
        for widgetID in widgets {
            guard let entry = registry.entry(for: widgetID) else { continue }
            if let img = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: nil) {
                let iv = NSImageView(frame: NSRect(x: x, y: 5, width: 14, height: 14))
                iv.image = img
                iv.contentTintColor = Theme.textSecondary
                iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                bar.addSubview(iv)
                x += 16
            }
            let label = NSTextField(labelWithString: shortLabel(for: entry))
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = Theme.textSecondary
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x, y: 7)
            bar.addSubview(label)
            x += label.frame.width + 12
        }

        return bar
    }

    private func shortLabel(for entry: WidgetRegistryEntry) -> String {
        // Short placeholder labels for the mock bar
        switch entry.widgetID {
        case "system-health": return "HEALTH 92"
        case "today-brief": return "TODAY 4 2h"
        case "world-clock": return "3:42 PM"
        case "weather-current": return "72\u{00B0}F"
        case "stock-ticker": return "AAPL +1.2%"
        case "cpu-monitor": return "CPU 23%"
        case "battery-health": return "87%"
        case "calendar-next": return "Standup 2pm"
        case "now-playing": return "Now Playing"
        case "meeting-joiner": return "Join"
        case "focus-task": return "Ship v2"
        case "keep-awake": return "Awake"
        case "pomodoro": return "25:00"
        case "daily-quote": return "Quote"
        case "ram-monitor": return "RAM 6.2G"
        case "moon-phase": return "Waxing"
        case "countdown": return "14d"
        case "git-branch": return "main"
        case "docker-status": return "Docker"
        case "server-ping": return "12ms"
        case "network-speed": return "45Mbps"
        case "sunrise-sunset": return "6:42am"
        default: return entry.displayName.prefix(8).description
        }
    }

    // MARK: - Category Helpers

    private func relevantCategories() -> [WidgetCategory] {
        // Show categories that have at least 2 registered widgets, sorted by count
        let counts = Dictionary(grouping: registry.entries, by: { $0.category })
        return WidgetCategory.allCases.filter { (counts[$0]?.count ?? 0) >= 2 }
    }

    private func widgetsForCurrentCategory() -> [WidgetRegistryEntry] {
        let entries: [WidgetRegistryEntry]
        if let cat = selectedCategory {
            entries = registry.entries(in: cat)
        } else {
            entries = registry.entries
        }
        // Sort: selected first, then alphabetical
        return entries.sorted { a, b in
            let aSelected = selectedWidgets.contains(a.widgetID)
            let bSelected = selectedWidgets.contains(b.widgetID)
            if aSelected != bSelected { return aSelected }
            return a.displayName < b.displayName
        }
    }

    private func currentPresetWidgetIDs() -> [String] {
        guard let idx = selectedPresetIndex else { return [] }
        return presets[idx].widgetIDs
    }

    // MARK: - UI Helpers

    private func makeCategoryTab(title: String, isSelected: Bool, tag: Int) -> NSView {
        let font = NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .medium)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let tabW = textWidth + 20
        let tabH: CGFloat = 26

        let tab = NSView(frame: NSRect(x: 0, y: 0, width: tabW, height: tabH))
        tab.wantsLayer = true
        tab.layer?.cornerRadius = tabH / 2
        tab.layer?.backgroundColor = isSelected ? Theme.accent.withAlphaComponent(0.15).cgColor : NSColor.clear.cgColor
        tab.layer?.borderWidth = isSelected ? 1 : 0.5
        tab.layer?.borderColor = isSelected ? Theme.accent.withAlphaComponent(0.4).cgColor : Theme.cardBorder.cgColor

        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = isSelected ? Theme.accent : Theme.textMuted
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 4, width: tabW, height: 16)
        tab.addSubview(label)

        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: tabW, height: tabH))
        btn.isBordered = false
        btn.isTransparent = true
        btn.target = self
        btn.action = #selector(categoryTapped(_:))
        btn.tag = tag
        tab.addSubview(btn)

        return tab
    }

    private func addStepDots(to container: NSView, current: Int, y: CGFloat) {
        let dotSize: CGFloat = 6
        let dotGap: CGFloat = 10
        let totalW = CGFloat(totalSteps) * dotSize + CGFloat(totalSteps - 1) * dotGap
        let startX = (winW - totalW) / 2

        for i in 0..<totalSteps {
            let dot = NSView(frame: NSRect(
                x: startX + CGFloat(i) * (dotSize + dotGap),
                y: y,
                width: dotSize, height: dotSize
            ))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = dotSize / 2
            if i == current {
                dot.layer?.backgroundColor = Theme.brandAmber.cgColor
            } else if i < current {
                dot.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
            } else {
                dot.layer?.backgroundColor = Theme.textFaint.cgColor
            }
            container.addSubview(dot)
        }
    }

    private func addNavButtons(to container: NSView, y: CGFloat, showBack: Bool, nextTitle: String, nextEnabled: Bool) {
        let btnH: CGFloat = 38
        let btnW: CGFloat = 130

        if showBack {
            let backBtn = NSButton(frame: NSRect(x: pad, y: y, width: 80, height: btnH))
            backBtn.wantsLayer = true
            backBtn.bezelStyle = .rounded
            backBtn.isBordered = false
            backBtn.title = "Back"
            backBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            backBtn.contentTintColor = Theme.textMuted
            backBtn.layer?.backgroundColor = Theme.cardBg.cgColor
            backBtn.layer?.cornerRadius = btnH / 2
            backBtn.layer?.borderWidth = 0.5
            backBtn.layer?.borderColor = Theme.cardBorder.cgColor
            backBtn.target = self
            backBtn.action = #selector(prevStep)
            container.addSubview(backBtn)
        }

        let nextBtn = NSButton(frame: NSRect(x: winW - pad - btnW, y: y, width: btnW, height: btnH))
        nextBtn.wantsLayer = true
        nextBtn.bezelStyle = .rounded
        nextBtn.isBordered = false
        nextBtn.title = nextTitle
        nextBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nextBtn.contentTintColor = nextEnabled ? NSColor.black : Theme.textFaint
        nextBtn.layer?.backgroundColor = nextEnabled ? Theme.brandAmber.cgColor : Theme.cardBg.cgColor
        nextBtn.layer?.cornerRadius = btnH / 2
        nextBtn.isEnabled = nextEnabled
        nextBtn.target = self
        nextBtn.action = #selector(nextStep)
        container.addSubview(nextBtn)
    }

    // MARK: - Actions

    @objc private func nextStep() {
        if currentStep < totalSteps - 1 {
            // When going from step 1 to step 2, seed selected widgets from preset
            if currentStep == 1, let idx = selectedPresetIndex {
                selectedWidgets = Set(presets[idx].widgetIDs)
            }
            showStep(currentStep + 1)
        }
    }

    @objc private func prevStep() {
        if currentStep > 0 {
            showStep(currentStep - 1)
        }
    }

    @objc private func presetTapped(_ sender: NSButton) {
        selectedPresetIndex = sender.tag
        // Rebuild step 1 to show selection
        showStep(1, animate: false)
    }

    @objc private func widgetTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let widgetID = String(id.dropFirst("w:".count))

        if selectedWidgets.contains(widgetID) {
            selectedWidgets.remove(widgetID)
        } else if selectedWidgets.count < maxWidgets {
            selectedWidgets.insert(widgetID)
        }
        showStep(2, animate: false)
    }

    @objc private func categoryTapped(_ sender: NSButton) {
        if sender.tag == -1 {
            selectedCategory = nil
        } else {
            let categories = relevantCategories()
            if sender.tag < categories.count {
                selectedCategory = categories[sender.tag]
            }
        }
        showStep(2, animate: false)
    }

    @objc private func finishOnboarding() {
        onFinish?(selectedWidgets)
        close()
    }

    @objc private func openSettingsFromOnboarding() {
        onFinish?(selectedWidgets)
        close()
        // Settings will be opened by the callback in AppDelegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
        }
    }
}

// MARK: - NSView Snapshot Helper

private extension NSView {
    func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
}
