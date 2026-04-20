import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBarController = StatusBarController()
    var settingsWindow: NSWindow?
    var settingsScrollView: NSScrollView!
    var settingsContentView: NSView!
    let windowWidth: CGFloat = 520
    let windowHeight: CGFloat = 650

    var settingsRefreshTimer: Timer?
    var gallerySearchText: String = ""
    var gallerySelectedCategory: WidgetCategory? = nil
    var onboardingWindow: NSWindow?
    var onboardingSelectedWidgets: Set<String> = ["world-clock", "weather-current"]
    var globalHotkeyMonitor: Any?
    private var sparkleUpdater: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register all widget types
        WidgetRegistry.shared.registerAll()

        // Load and activate saved widgets
        statusBarController.syncMenuBar()

        // Apply saved menu bar appearance (color/gradient)
        let savedAppearance = MenuBarAppearance.load()
        MenuBarOverlay.shared.apply(savedAppearance)

        // Reapply hidden menu bar items after a short delay (let other apps load)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if MenuBarManager.hasAccessibilityPermission {
                MenuBarManager.shared.reapplyHidden()
                MenuBarManager.shared.loadAutoHideInterval()
                if MenuBarManager.shared.isHoverRevealEnabled {
                    MenuBarManager.shared.enableHoverReveal()
                }
            }
        }

        // Global hotkey: Cmd+Shift+B to toggle settings
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "b" {
                DispatchQueue.main.async {
                    self?.showSettingsWindow()
                }
            }
        }

        // Local hotkey (when app is active)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "b" {
                if let w = self?.settingsWindow, w.isVisible {
                    w.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                    self?.stopSettingsRefreshTimer()
                } else {
                    self?.showSettingsWindow()
                }
                return nil
            }
            return event
        }

        // Show onboarding on first launch, settings on subsequent
        if !UserDefaults.standard.bool(forKey: "barista.hasLaunched") {
            showOnboardingWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    // MARK: - Onboarding Window

    func showOnboardingWindow() {
        let obW: CGFloat = 480
        let obH: CGFloat = 580
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        onboardingWindow = NSWindow(
            contentRect: NSRect(
                x: (screenFrame.width - obW) / 2,
                y: (screenFrame.height - obH) / 2,
                width: obW, height: obH
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        guard let window = onboardingWindow else { return }
        window.title = "Welcome to Barista"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: obW, height: obH))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        let tint = NSView(frame: NSRect(x: 0, y: 0, width: obW, height: obH))
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(red: 0.04, green: 0.03, blue: 0.06, alpha: 0.45).cgColor
        tint.autoresizingMask = [.width, .height]
        visualEffect.addSubview(tint)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: obW, height: obH))
        buildOnboardingContent(in: container, width: obW, height: obH)
        visualEffect.addSubview(container)

        window.contentView = visualEffect
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildOnboardingContent(in container: NSView, width: CGFloat, height: CGFloat) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let pad: CGFloat = 32
        var y = height - 60

        // App icon
        let logoSize: CGFloat = 64
        let logoView = NSImageView(frame: NSRect(x: (width - logoSize) / 2, y: y - logoSize, width: logoSize, height: logoSize))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            logoView.image = appIcon
            logoView.imageScaling = .scaleProportionallyUpOrDown
        }
        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 16
        logoView.layer?.masksToBounds = false
        logoView.layer?.shadowColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
        logoView.layer?.shadowRadius = 16
        logoView.layer?.shadowOpacity = 1.0
        logoView.layer?.shadowOffset = .zero
        container.addSubview(logoView)
        y -= logoSize + 16

        // Welcome title
        let title = NSTextField(labelWithString: "Welcome to Barista")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center
        title.frame = NSRect(x: pad, y: y - 30, width: width - pad * 2, height: 30)
        container.addSubview(title)
        y -= 38

        let sub = NSTextField(labelWithString: "Pick a few widgets to get started")
        sub.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        sub.textColor = Theme.textMuted
        sub.alignment = .center
        sub.frame = NSRect(x: pad, y: y - 18, width: width - pad * 2, height: 18)
        container.addSubview(sub)
        y -= 30

        // Widget picker grid
        let starterWidgets: [(String, String, String)] = [
            ("world-clock", "World Clock", "clock"),
            ("weather-current", "Weather", "cloud.sun"),
            ("stock-ticker", "Stock Ticker", "chart.line.uptrend.xyaxis"),
            ("cpu-monitor", "CPU Monitor", "cpu"),
            ("battery-health", "Battery", "battery.100"),
            ("calendar-grid", "Calendar", "calendar.badge.clock"),
            ("now-playing", "Now Playing", "music.note"),
            ("meeting-joiner", "Meeting Joiner", "video.fill"),
            ("focus-task", "Focus Task", "target"),
            ("keep-awake", "Keep Awake", "cup.and.saucer.fill"),
            ("pomodoro", "Pomodoro", "timer"),
            ("daily-quote", "Daily Quote", "text.quote"),
        ]

        let cardW: CGFloat = (width - pad * 2 - 12) / 2
        let cardH: CGFloat = 48

        for (i, (wID, name, icon)) in starterWidgets.enumerated() {
            let col = i % 2
            let row = i / 2
            let cx = pad + CGFloat(col) * (cardW + 12)
            let cy = y - CGFloat(row) * (cardH + 8) - cardH

            let isSelected = onboardingSelectedWidgets.contains(wID)

            let card = NSView(frame: NSRect(x: cx, y: cy, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.backgroundColor = isSelected ? Theme.accent.withAlphaComponent(0.12).cgColor : Theme.cardBg.cgColor
            card.layer?.cornerRadius = 12
            card.layer?.borderWidth = isSelected ? 1.5 : 0.5
            card.layer?.borderColor = isSelected ? Theme.accent.withAlphaComponent(0.6).cgColor : Theme.cardBorder.cgColor

            // Icon
            if let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
                let iv = NSImageView(frame: NSRect(x: 12, y: 14, width: 18, height: 18))
                iv.image = img
                iv.contentTintColor = isSelected ? Theme.accent : Theme.textMuted
                card.addSubview(iv)
            }

            // Name
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .medium)
            nameLabel.textColor = isSelected ? Theme.textPrimary : Theme.textSecondary
            nameLabel.frame = NSRect(x: 36, y: 15, width: cardW - 64, height: 16)
            card.addSubview(nameLabel)

            // Checkmark
            if isSelected {
                let check = NSTextField(labelWithString: "\u{2713}")
                check.font = NSFont.systemFont(ofSize: 14, weight: .bold)
                check.textColor = Theme.accent
                check.alignment = .center
                check.frame = NSRect(x: cardW - 28, y: 14, width: 20, height: 20)
                card.addSubview(check)
            }

            // Click handler via button overlay
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: cardW, height: cardH))
            btn.isBordered = false
            btn.isTransparent = true
            btn.target = self
            btn.action = #selector(onboardingToggleWidget(_:))
            btn.identifier = NSUserInterfaceItemIdentifier("ob:\(wID)")
            card.addSubview(btn)

            container.addSubview(card)
        }

        let gridRows = (starterWidgets.count + 1) / 2
        y -= CGFloat(gridRows) * (cardH + 8) + 16

        // Selection count
        let onboardingMax = 5
        let countStr = "\(onboardingSelectedWidgets.count) selected (max \(onboardingMax))"
        let countLabel = NSTextField(labelWithString: countStr)
        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = onboardingSelectedWidgets.count > onboardingMax ? Theme.red : Theme.textMuted
        countLabel.alignment = .center
        countLabel.frame = NSRect(x: pad, y: y - 16, width: width - pad * 2, height: 16)
        container.addSubview(countLabel)
        y -= 28

        // Get Started button
        let btnW: CGFloat = 200
        let btnH: CGFloat = 40
        let startBtn = NSButton(frame: NSRect(x: (width - btnW) / 2, y: y - btnH, width: btnW, height: btnH))
        startBtn.wantsLayer = true
        startBtn.bezelStyle = .rounded
        startBtn.isBordered = false
        startBtn.title = "Get Started"
        startBtn.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        startBtn.contentTintColor = NSColor.black
        startBtn.layer?.backgroundColor = Theme.brandAmber.cgColor
        startBtn.layer?.cornerRadius = 20
        startBtn.target = self
        startBtn.action = #selector(onboardingFinish)
        container.addSubview(startBtn)
    }

    @objc func onboardingToggleWidget(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let widgetID = String(id.dropFirst("ob:".count))

        if onboardingSelectedWidgets.contains(widgetID) {
            onboardingSelectedWidgets.remove(widgetID)
        } else {
            if onboardingSelectedWidgets.count < 5 {
                onboardingSelectedWidgets.insert(widgetID)
            }
        }

        // Rebuild content
        if let window = onboardingWindow, let visualEffect = window.contentView {
            if let container = visualEffect.subviews.last {
                let bounds = visualEffect.bounds
                buildOnboardingContent(in: container, width: bounds.width, height: bounds.height)
            }
        }
    }

    @objc func onboardingFinish() {
        UserDefaults.standard.set(true, forKey: "barista.hasLaunched")

        // Remove default widgets and add selected ones
        statusBarController.removeAllWidgets()
        // Clear stored widgets
        WidgetStore.shared.save([])

        for widgetID in onboardingSelectedWidgets {
            _ = statusBarController.addWidget(widgetID: widgetID)
        }

        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Settings Window

    @objc func showSettingsWindow() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            rebuildSettingsUI()
            return
        }

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        settingsWindow = NSWindow(
            contentRect: NSRect(
                x: (screenFrame.width - windowWidth) / 2,
                y: (screenFrame.height - windowHeight) / 2,
                width: windowWidth,
                height: windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        guard let window = settingsWindow else { return }
        window.title = "Barista"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 440, height: 500)

        // Frosted glass background - this is what makes it ACTUALLY glassmorphism
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        visualEffect.material = .hudWindow            // dark frosted glass
        visualEffect.blendingMode = .behindWindow      // blur what's BEHIND the window
        visualEffect.state = .active                    // always active, not just when focused
        visualEffect.autoresizingMask = [.width, .height]

        // Dark tint overlay on top of the blur for depth
        let tintOverlay = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = NSColor(red: 0.04, green: 0.03, blue: 0.06, alpha: 0.45).cgColor
        tintOverlay.autoresizingMask = [.width, .height]
        visualEffect.addSubview(tintOverlay)

        settingsScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        settingsScrollView.hasVerticalScroller = true
        settingsScrollView.autohidesScrollers = true
        settingsScrollView.scrollerStyle = .overlay
        settingsScrollView.drawsBackground = false
        settingsScrollView.autoresizingMask = [.width, .height]
        let clip = NSClipView()
        clip.drawsBackground = false
        settingsScrollView.contentView = clip

        settingsContentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 1000))
        settingsContentView.wantsLayer = true
        settingsContentView.layer?.backgroundColor = NSColor.clear.cgColor
        settingsScrollView.documentView = settingsContentView

        visualEffect.addSubview(settingsScrollView)
        window.contentView = visualEffect

        rebuildSettingsUI()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        startSettingsRefreshTimer()
    }

    // Track which widgets have expanded config panels
    var expandedWidgets: Set<UUID> = []

    // MARK: - Settings UI

    func rebuildSettingsUI() {
        guard let content = settingsContentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }

        let w = windowWidth
        let pad: CGFloat = 28

        let activeWidgets = statusBarController.activeInstances

        // First pass: calculate total height
        var totalHeight: CGFloat = 80 // title bar + padding
        totalHeight += 54 // space usage bar + remaining label
        if !statusBarController.canAddMore || statusBarController.menuBarUsagePercent > 0.9 { totalHeight += 44 } // overflow warning
        totalHeight += 30 // "MY WIDGETS" header

        for instance in activeWidgets {
            totalHeight += 58 // collapsed card
            if expandedWidgets.contains(instance.id) {
                totalHeight += configPanelHeight(for: instance)
            }
        }
        if activeWidgets.isEmpty { totalHeight += 40 }

        totalHeight += 48 // divider + spacing

        // Menu bar manager section
        let menuBarMgr = MenuBarManager.shared
        let menuBarItemHeight: CGFloat = 36
        totalHeight += 30 // "MENU BAR" header
        if !MenuBarManager.hasAccessibilityPermission {
            totalHeight += 70 // permission prompt
        } else {
            totalHeight += CGFloat(menuBarMgr.detectedItems.count) * (menuBarItemHeight + 4)
            if menuBarMgr.detectedItems.isEmpty { totalHeight += 40 }
        }
        totalHeight += 48 // divider + spacing

        totalHeight += 30 // "WIDGET GALLERY" header
        totalHeight += 40 // search bar
        totalHeight += 32 // category filter pills

        let galleryCardHeight: CGFloat = 72
        let filteredEntries = filteredGalleryEntries()
        // Group by category and calculate height
        let groupedCategories = categoriesInOrder(for: filteredEntries)
        for cat in groupedCategories {
            totalHeight += 28 // category header
            let count = filteredEntries.filter { $0.category == cat }.count
            totalHeight += CGFloat(count) * (galleryCardHeight + 6)
            totalHeight += 8 // spacing after group
        }
        if filteredEntries.isEmpty { totalHeight += 50 } // "no results"
        totalHeight += 48 // divider + spacing
        totalHeight += 30 // "MENU BAR APPEARANCE" header
        totalHeight += 40 // enable toggle
        totalHeight += 56 // preset grid row 1
        totalHeight += 56 // preset grid row 2
        totalHeight += 40 // opacity slider
        totalHeight += 16 // spacing
        totalHeight += 48 // divider + spacing
        totalHeight += 30 // "PROFILES" header
        totalHeight += 44 // profile preset buttons
        totalHeight += 36 // save profile button
        totalHeight += 8  // spacing
        totalHeight += 48 // divider + spacing
        totalHeight += 30 // "APP SETTINGS" header
        totalHeight += 40 // launch at login toggle
        totalHeight += 40 // check for updates
        totalHeight += 24 // keyboard shortcut hint
        totalHeight += 60 // footer

        totalHeight = max(totalHeight, windowHeight)
        content.frame = NSRect(x: 0, y: 0, width: w, height: totalHeight)

        var y = totalHeight - 56

        // MARK: Title Bar with Logo
        let titleBar = NSView(frame: NSRect(x: 0, y: totalHeight - 68, width: w, height: 68))
        titleBar.wantsLayer = true

        // App icon from bundle
        let logoSize: CGFloat = 42
        let logoView = NSImageView(frame: NSRect(x: pad, y: 14, width: logoSize, height: logoSize))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            logoView.image = appIcon
            logoView.imageScaling = .scaleProportionallyUpOrDown
        }
        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 10
        logoView.layer?.masksToBounds = true
        // Warm amber glow behind the logo
        logoView.shadow = NSShadow()
        logoView.layer?.shadowColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
        logoView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        logoView.layer?.shadowRadius = 12
        logoView.layer?.shadowOpacity = 1.0
        titleBar.addSubview(logoView)

        let appTitle = NSTextField(labelWithString: "Barista")
        appTitle.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        appTitle.textColor = Theme.textPrimary
        appTitle.frame = NSRect(x: pad + logoSize + 14, y: 28, width: 200, height: 28)
        titleBar.addSubview(appTitle)

        // Amber dot after title
        let dotView = NSView(frame: NSRect(x: pad + logoSize + 14 + 82, y: 38, width: 6, height: 6))
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.layer?.backgroundColor = Theme.brandAmber.cgColor
        dotView.layer?.shadowColor = Theme.brandAmber.cgColor
        dotView.layer?.shadowRadius = 4
        dotView.layer?.shadowOpacity = 0.8
        dotView.layer?.shadowOffset = .zero
        titleBar.addSubview(dotView)

        let subtitle = NSTextField(labelWithString: "your menu bar, your way")
        subtitle.font = NSFont.systemFont(ofSize: 11.5, weight: .light)
        subtitle.textColor = Theme.textFaint
        subtitle.frame = NSRect(x: pad + logoSize + 14, y: 10, width: 220, height: 16)
        titleBar.addSubview(subtitle)

        content.addSubview(titleBar)
        y -= 28

        // MARK: Menu Bar Space Usage
        let usedPx = statusBarController.usedMenuBarWidth
        let availPx = statusBarController.availableMenuBarWidth
        let remainPx = statusBarController.remainingMenuBarWidth
        let usagePct = statusBarController.menuBarUsagePercent
        let isFull = !statusBarController.canAddMore

        let spaceRowH: CGFloat = 38
        let spaceRow = NSView(frame: NSRect(x: pad, y: y - spaceRowH, width: w - pad * 2, height: spaceRowH))

        // Usage bar background
        let barW = w - pad * 2 - 120  // leave room for label
        let barH: CGFloat = 6
        let barY: CGFloat = 22
        let barTrack = NSView(frame: NSRect(x: 0, y: barY, width: barW, height: barH))
        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = barH / 2
        barTrack.layer?.backgroundColor = Theme.trackBg.cgColor
        spaceRow.addSubview(barTrack)

        // Usage bar fill
        let fillPct = min(usagePct, 1.0)
        let barFill = NSView(frame: NSRect(x: 0, y: barY, width: barW * fillPct, height: barH))
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = barH / 2
        let barColor: NSColor = usagePct > 0.9 ? Theme.red : (usagePct > 0.7 ? Theme.brandAmber : Theme.accent)
        barFill.layer?.backgroundColor = barColor.cgColor
        barFill.layer?.shadowColor = barColor.cgColor
        barFill.layer?.shadowRadius = 4
        barFill.layer?.shadowOpacity = 0.6
        barFill.layer?.shadowOffset = .zero
        spaceRow.addSubview(barFill)

        // Per-widget segment separators on the bar
        var segX: CGFloat = 0
        for instance in activeWidgets {
            let segW = barW * (instance.measuredWidth / max(availPx, 1))
            segX += segW
            // Thin separator between segments
            if segX > 1 && segX < barW * fillPct - 1 {
                let sep = NSView(frame: NSRect(x: segX - 0.5, y: barY, width: 1, height: barH))
                sep.wantsLayer = true
                sep.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
                spaceRow.addSubview(sep)
            }
        }

        // Usage label
        let pctInt = Int(usagePct * 100)
        let usageText = "\(Int(usedPx))px / \(Int(availPx))px (\(pctInt)%)"
        let usageLabel = NSTextField(labelWithString: usageText)
        usageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        usageLabel.textColor = usagePct > 0.9 ? Theme.red : Theme.textMuted
        usageLabel.frame = NSRect(x: barW + 8, y: barY - 3, width: 120, height: 14)
        spaceRow.addSubview(usageLabel)

        // Remaining space hint
        let remainText = remainPx > 60 ? "\(Int(remainPx))px free" : "almost full"
        let remainLabel = NSTextField(labelWithString: remainText)
        remainLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        remainLabel.textColor = Theme.textFaint
        remainLabel.frame = NSRect(x: 0, y: 2, width: 200, height: 14)
        spaceRow.addSubview(remainLabel)

        content.addSubview(spaceRow)
        y -= spaceRowH + 8

        // Overflow warning when almost full or over
        if isFull || usagePct > 0.9 {
            let warnH: CGFloat = 36
            let warnCard = NSView(frame: NSRect(x: pad, y: y - warnH, width: w - pad * 2, height: warnH))
            warnCard.wantsLayer = true
            let warnColor = usagePct >= 1.0 ? Theme.red : Theme.brandAmber
            warnCard.layer?.backgroundColor = warnColor.withAlphaComponent(0.08).cgColor
            warnCard.layer?.cornerRadius = 8
            warnCard.layer?.borderWidth = 0.5
            warnCard.layer?.borderColor = warnColor.withAlphaComponent(0.25).cgColor

            let warnMsg = usagePct >= 1.0
                ? "Menu bar is full. Remove a widget to add another."
                : "Menu bar is almost full (\(Int(remainPx))px remaining)."
            let warnLabel = NSTextField(labelWithString: warnMsg)
            warnLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            warnLabel.textColor = warnColor
            warnLabel.frame = NSRect(x: 12, y: 10, width: warnCard.frame.width - 24, height: 16)
            warnCard.addSubview(warnLabel)

            content.addSubview(warnCard)
            y -= warnH + 8
        }

        // MARK: Active Widgets Section
        let activeLabel = makeTrackedLabel("MY WIDGETS")
        activeLabel.frame = NSRect(x: pad, y: y, width: 120, height: 14)
        content.addSubview(activeLabel)

        let countBadge = NSTextField(labelWithString: "\(activeWidgets.count)")
        countBadge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        countBadge.textColor = Theme.accent
        countBadge.alignment = .center
        countBadge.frame = NSRect(x: pad + 100, y: y, width: 20, height: 14)
        content.addSubview(countBadge)
        y -= 16

        for (i, instance) in activeWidgets.enumerated() {
            let isExpanded = expandedWidgets.contains(instance.id)
            let headerHeight: CGFloat = 52

            let card = NSView(frame: NSRect(x: pad, y: y - headerHeight, width: w - pad * 2, height: headerHeight))
            card.wantsLayer = true
            card.layer?.backgroundColor = Theme.cardBg.cgColor
            card.layer?.cornerRadius = 14
            card.layer?.borderWidth = 0.5
            card.layer?.borderColor = (isExpanded ? Theme.cardBorderHover : Theme.cardBorder).cgColor
            card.setAccessibilityLabel("\(instance.widget.displayName) widget, position \(i + 1) of \(activeWidgets.count)")
            if isExpanded {
                card.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                card.layer?.shadowColor = NSColor.black.cgColor
                card.layer?.shadowRadius = 16
                card.layer?.shadowOpacity = 0.45
                card.layer?.shadowOffset = CGSize(width: 0, height: -6)
            }

            // Top specular highlight
            let specular = CAGradientLayer()
            specular.frame = CGRect(x: 0, y: headerHeight - 28, width: Double(w) - Double(pad) * 2, height: 28)
            specular.colors = [NSColor.white.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
            specular.startPoint = CGPoint(x: 0.5, y: 1)
            specular.endPoint = CGPoint(x: 0.5, y: 0)
            specular.cornerRadius = 14
            specular.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            card.layer?.addSublayer(specular)

            // Widget icon with colored glow tile
            let iconTile = NSView(frame: NSRect(x: 12, y: 9, width: 34, height: 34))
            iconTile.wantsLayer = true
            iconTile.layer?.cornerRadius = 10
            iconTile.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
            iconTile.layer?.borderWidth = 0.5
            iconTile.layer?.borderColor = Theme.accent.withAlphaComponent(0.27).cgColor
            card.addSubview(iconTile)

            if let img = NSImage(systemSymbolName: instance.widget.iconName, accessibilityDescription: nil) {
                let iconView = NSImageView(frame: NSRect(x: 7, y: 7, width: 20, height: 20))
                iconView.image = img
                iconView.contentTintColor = Theme.accent
                iconTile.addSubview(iconView)
            }

            // Widget name
            let nameLabel = NSTextField(labelWithString: instance.widget.displayName)
            nameLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
            nameLabel.textColor = Theme.textPrimary
            nameLabel.frame = NSRect(x: 54, y: 20, width: 200, height: 18)
            card.addSubview(nameLabel)

            // "In menu bar" label + mini preview
            let inBarLabel = NSTextField(labelWithString: "In menu bar")
            inBarLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            inBarLabel.textColor = Theme.textFaint
            inBarLabel.frame = NSRect(x: 54, y: 4, width: 70, height: 14)
            card.addSubview(inBarLabel)

            // Reorder buttons (up/down arrows)
            if activeWidgets.count > 1 {
                if i > 0 {
                    let upBtn = HoverButton(frame: NSRect(x: card.frame.width - 132, y: 14, width: 24, height: 24))
                    upBtn.wantsLayer = true
                    upBtn.bezelStyle = .inline
                    upBtn.isBordered = false
                    if let img = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move Up") {
                        upBtn.image = img
                        upBtn.imagePosition = .imageOnly
                    }
                    upBtn.contentTintColor = Theme.textMuted
                    upBtn.layer?.cornerRadius = 12
                    upBtn.normalBg = .clear
                    upBtn.hoverBg = Theme.accentBg
                    upBtn.tag = i
                    upBtn.target = self
                    upBtn.action = #selector(moveWidgetUp(_:))
                    card.addSubview(upBtn)
                }
                if i < activeWidgets.count - 1 {
                    let downBtn = HoverButton(frame: NSRect(x: card.frame.width - 108, y: 14, width: 24, height: 24))
                    downBtn.wantsLayer = true
                    downBtn.bezelStyle = .inline
                    downBtn.isBordered = false
                    if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move Down") {
                        downBtn.image = img
                        downBtn.imagePosition = .imageOnly
                    }
                    downBtn.contentTintColor = Theme.textMuted
                    downBtn.layer?.cornerRadius = 12
                    downBtn.normalBg = .clear
                    downBtn.hoverBg = Theme.accentBg
                    downBtn.tag = i
                    downBtn.target = self
                    downBtn.action = #selector(moveWidgetDown(_:))
                    card.addSubview(downBtn)
                }
            }

            // Configure button (gear icon)
            let configBtn = HoverButton(frame: NSRect(x: card.frame.width - 72, y: 14, width: 24, height: 24))
            configBtn.wantsLayer = true
            configBtn.bezelStyle = .inline
            configBtn.isBordered = false
            if let gearImg = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Configure") {
                configBtn.image = gearImg
                configBtn.imagePosition = .imageOnly
            }
            configBtn.contentTintColor = isExpanded ? Theme.accent : Theme.textMuted
            configBtn.layer?.cornerRadius = 12
            configBtn.normalBg = isExpanded ? Theme.accentBg : .clear
            configBtn.hoverBg = Theme.accentBg
            configBtn.tag = i
            configBtn.target = self
            configBtn.action = #selector(toggleWidgetConfig(_:))
            configBtn.setAccessibilityLabel("Configure \(instance.widget.displayName)")
            card.addSubview(configBtn)

            // Remove button
            let removeBtn = HoverButton(frame: NSRect(x: card.frame.width - 36, y: 14, width: 24, height: 24))
            removeBtn.wantsLayer = true
            removeBtn.bezelStyle = .inline
            removeBtn.isBordered = false
            removeBtn.title = "x"
            removeBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            removeBtn.contentTintColor = Theme.textMuted
            removeBtn.layer?.cornerRadius = 12
            removeBtn.normalBg = .clear
            removeBtn.hoverBg = Theme.redBg
            removeBtn.tag = i
            removeBtn.target = self
            removeBtn.action = #selector(removeWidgetAction(_:))
            removeBtn.setAccessibilityLabel("Remove \(instance.widget.displayName)")
            card.addSubview(removeBtn)

            content.addSubview(card)
            y -= headerHeight + (isExpanded ? 0 : 6)

            // Expanded config panel
            if isExpanded {
                let panelHeight = configPanelHeight(for: instance)
                let panel = NSView(frame: NSRect(x: pad, y: y - panelHeight, width: w - pad * 2, height: panelHeight))
                panel.wantsLayer = true
                panel.layer?.backgroundColor = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.3).cgColor
                panel.layer?.cornerRadius = 14
                panel.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                panel.layer?.borderWidth = 0.5
                panel.layer?.borderColor = Theme.cardBorderHover.cgColor

                buildConfigPanel(for: instance, in: panel, width: w - pad * 2)
                content.addSubview(panel)
                y -= panelHeight + 6
            }
        }

        if activeWidgets.isEmpty {
            let emptyCard = NSView(frame: NSRect(x: pad, y: y - 80, width: w - pad * 2, height: 80))
            emptyCard.wantsLayer = true
            emptyCard.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
            emptyCard.layer?.cornerRadius = 16
            emptyCard.layer?.borderWidth = 0.5
            emptyCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

            let emptyTitle = NSTextField(labelWithString: "Your menu bar is empty")
            emptyTitle.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            emptyTitle.textColor = Theme.textPrimary
            emptyTitle.alignment = .center
            emptyTitle.frame = NSRect(x: 20, y: 44, width: emptyCard.frame.width - 40, height: 20)
            emptyCard.addSubview(emptyTitle)

            let emptySub = NSTextField(labelWithString: "Brew your first widget from the gallery below")
            emptySub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            emptySub.textColor = Theme.textMuted
            emptySub.alignment = .center
            emptySub.frame = NSRect(x: 20, y: 18, width: emptyCard.frame.width - 40, height: 16)
            emptyCard.addSubview(emptySub)

            content.addSubview(emptyCard)
            y -= 88
        }

        y -= 24

        // MARK: Divider
        let divider = NSView(frame: NSRect(x: pad, y: y, width: w - pad * 2, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider)
        y -= 24

        // MARK: Menu Bar Manager Section
        let menuBarLabel = makeTrackedLabel("MENU BAR")
        menuBarLabel.frame = NSRect(x: pad, y: y, width: 120, height: 14)
        content.addSubview(menuBarLabel)

        let hiddenCountBadge = NSTextField(labelWithString: "\(MenuBarManager.shared.hiddenCount) hidden")
        hiddenCountBadge.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        hiddenCountBadge.textColor = MenuBarManager.shared.hiddenCount > 0 ? Theme.accent : Theme.textMuted
        hiddenCountBadge.frame = NSRect(x: pad + 90, y: y, width: 80, height: 14)
        content.addSubview(hiddenCountBadge)
        y -= 8

        if !MenuBarManager.hasAccessibilityPermission {
            // Permission prompt card
            let permCard = NSView(frame: NSRect(x: pad, y: y - 60, width: w - pad * 2, height: 60))
            permCard.wantsLayer = true
            permCard.layer?.backgroundColor = Theme.cardBg.cgColor
            permCard.layer?.cornerRadius = 12
            permCard.layer?.borderWidth = 1
            permCard.layer?.borderColor = Theme.accent.withAlphaComponent(0.3).cgColor

            let permLabel = NSTextField(labelWithString: "Grant Accessibility to hide menu bar icons")
            permLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            permLabel.textColor = Theme.textSecondary
            permLabel.frame = NSRect(x: 14, y: 22, width: 300, height: 16)
            permCard.addSubview(permLabel)

            let permBtn = NSButton(title: "Grant Access", target: self, action: #selector(requestAccessibility))
            permBtn.frame = NSRect(x: CGFloat(w) - pad * 2 - 110, y: 14, width: 100, height: 30)
            permBtn.bezelStyle = .rounded
            permBtn.isBordered = true
            permBtn.contentTintColor = Theme.accent
            permCard.addSubview(permBtn)

            content.addSubview(permCard)
            y -= 68
        } else {
            // Refresh detected items
            MenuBarManager.shared.detectMenuBarItems()
            let items = MenuBarManager.shared.detectedItems

            if items.isEmpty {
                let emptyLabel = NSTextField(labelWithString: "No third-party menu bar items detected")
                emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                emptyLabel.textColor = Theme.textMuted
                emptyLabel.frame = NSRect(x: pad, y: y - 30, width: w - pad * 2, height: 30)
                content.addSubview(emptyLabel)
                y -= 36
            } else {
                // Show all / Hide toggle
                if MenuBarManager.shared.hiddenCount > 0 {
                    let showAllBtn = NSButton(title: "Show All", target: self, action: #selector(menuBarShowAll))
                    showAllBtn.frame = NSRect(x: CGFloat(w) - pad - 80, y: y - 4, width: 70, height: 20)
                    showAllBtn.bezelStyle = .inline
                    showAllBtn.isBordered = false
                    showAllBtn.contentTintColor = Theme.accent
                    showAllBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                    content.addSubview(showAllBtn)
                }
                y -= 8

                for item in items {
                    let row = NSView(frame: NSRect(x: pad, y: y - menuBarItemHeight, width: w - pad * 2, height: menuBarItemHeight))
                    row.wantsLayer = true
                    row.layer?.backgroundColor = Theme.cardBg.cgColor
                    row.layer?.cornerRadius = 8
                    row.layer?.borderWidth = 1
                    row.layer?.borderColor = item.isHidden ? Theme.red.withAlphaComponent(0.2).cgColor : Theme.cardBorder.cgColor

                    // App icon (small SF Symbol as fallback)
                    let iconStr = item.isHidden ? "eye.slash.fill" : "eye.fill"
                    if let img = NSImage(systemSymbolName: iconStr, accessibilityDescription: nil) {
                        let iconView = NSImageView(frame: NSRect(x: 10, y: 8, width: 16, height: 16))
                        iconView.image = img
                        iconView.contentTintColor = item.isHidden ? Theme.red.withAlphaComponent(0.5) : Theme.green.withAlphaComponent(0.6)
                        row.addSubview(iconView)
                    }

                    // App name + item title
                    let displayName = item.appName == item.title ? item.title : "\(item.appName) - \(item.title)"
                    let nameLabel = NSTextField(labelWithString: displayName)
                    nameLabel.font = NSFont.systemFont(ofSize: 11, weight: item.isHidden ? .regular : .medium)
                    nameLabel.textColor = item.isHidden ? Theme.textMuted : Theme.textPrimary
                    nameLabel.lineBreakMode = .byTruncatingTail
                    nameLabel.frame = NSRect(x: 32, y: 10, width: w - pad * 2 - 110, height: 16)
                    row.addSubview(nameLabel)

                    // Toggle button
                    let toggleBtn = NSButton(title: item.isHidden ? "Show" : "Hide", target: self, action: #selector(menuBarToggleItem(_:)))
                    toggleBtn.frame = NSRect(x: row.frame.width - 62, y: 4, width: 52, height: 26)
                    toggleBtn.bezelStyle = .inline
                    toggleBtn.isBordered = false
                    toggleBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                    toggleBtn.contentTintColor = item.isHidden ? Theme.green : Theme.textMuted
                    toggleBtn.identifier = NSUserInterfaceItemIdentifier("menubar-toggle:\(item.id)")
                    row.addSubview(toggleBtn)

                    content.addSubview(row)
                    y -= menuBarItemHeight + 4
                }
            }
        }

        y -= 16

        // MARK: Divider 2
        let divider2 = NSView(frame: NSRect(x: pad, y: y, width: w - pad * 2, height: 1))
        divider2.wantsLayer = true
        divider2.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider2)
        y -= 24

        // MARK: Gallery Section
        let galleryLabel = makeTrackedLabel("WIDGET GALLERY")
        galleryLabel.frame = NSRect(x: pad, y: y, width: 140, height: 14)
        content.addSubview(galleryLabel)
        y -= 22

        // Embedded search bar - NSSearchField styled to match glass UI
        let searchHeight: CGFloat = 28
        let searchField = NSSearchField()
        searchField.frame = NSRect(x: pad, y: y - searchHeight, width: w - pad * 2, height: searchHeight)
        searchField.wantsLayer = true
        searchField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        searchField.textColor = Theme.textPrimary
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.placeholderString = "Search widgets\u{2026}"
        searchField.stringValue = gallerySearchText
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(gallerySearchChanged(_:))
        searchField.identifier = NSUserInterfaceItemIdentifier("gallerySearch")
        // Style the cell for dark glass look
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.isTransparent = false
            cell.cancelButtonCell?.isTransparent = false
        }
        searchField.appearance = NSAppearance(named: .darkAqua)
        content.addSubview(searchField)
        y -= searchHeight + 10

        // Horizontally scrollable category pills
        let pillHeight: CGFloat = 26
        let pillScrollView = NSScrollView(frame: NSRect(x: pad, y: y - pillHeight, width: w - pad * 2, height: pillHeight))
        pillScrollView.hasHorizontalScroller = false
        pillScrollView.hasVerticalScroller = false
        pillScrollView.drawsBackground = false
        pillScrollView.autohidesScrollers = true
        let pillClip = NSClipView()
        pillClip.drawsBackground = false
        pillScrollView.contentView = pillClip

        // Build pill strip - calculate total width first
        let pillFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let registeredCategories = categoriesInOrder(for: WidgetRegistry.shared.entries)
        var totalPillWidth: CGFloat = 0
        let pillGap: CGFloat = 5

        // Measure "All"
        let allTextWidth = ("All" as NSString).size(withAttributes: [.font: pillFont]).width + 20
        totalPillWidth += allTextWidth + pillGap
        for cat in registeredCategories {
            let catWidth = (cat.rawValue as NSString).size(withAttributes: [.font: pillFont]).width + 20
            totalPillWidth += catWidth + pillGap
        }

        let pillStrip = NSView(frame: NSRect(x: 0, y: 0, width: max(totalPillWidth, pillScrollView.frame.width), height: pillHeight))
        var pillX: CGFloat = 0

        // "All" pill
        let allSelected = gallerySelectedCategory == nil
        let allPill = makeCategoryPill(title: "All", identifier: "cat:all", isSelected: allSelected, font: pillFont)
        allPill.frame = NSRect(x: pillX, y: 0, width: allTextWidth, height: pillHeight)
        pillStrip.addSubview(allPill)
        pillX += allTextWidth + pillGap

        for cat in registeredCategories {
            let isSelected = gallerySelectedCategory == cat
            let catWidth = (cat.rawValue as NSString).size(withAttributes: [.font: pillFont]).width + 20
            let pill = makeCategoryPill(title: cat.rawValue, identifier: "cat:\(cat.rawValue)", isSelected: isSelected, font: pillFont)
            pill.frame = NSRect(x: pillX, y: 0, width: catWidth, height: pillHeight)
            pillStrip.addSubview(pill)
            pillX += catWidth + pillGap
        }

        pillScrollView.documentView = pillStrip
        content.addSubview(pillScrollView)
        y -= pillHeight + 10

        // Filtered & grouped entries
        let filtered = filteredGalleryEntries()
        let groupedCats = categoriesInOrder(for: filtered)

        if filtered.isEmpty {
            let noResults = NSTextField(labelWithString: "No widgets match your search")
            noResults.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            noResults.textColor = Theme.textMuted
            noResults.alignment = .center
            noResults.frame = NSRect(x: pad, y: y - 40, width: w - pad * 2, height: 40)
            content.addSubview(noResults)
            y -= 50
        }

        for cat in groupedCats {
            // Category section header
            let catEntries = filtered.filter { $0.category == cat }
            let catIcon = cat.icon
            let catHeader = NSView(frame: NSRect(x: pad, y: y - 20, width: w - pad * 2, height: 20))

            if let sfImg = NSImage(systemSymbolName: catIcon, accessibilityDescription: nil) {
                let catIconView = NSImageView(frame: NSRect(x: 0, y: 2, width: 14, height: 14))
                catIconView.image = sfImg
                catIconView.contentTintColor = Theme.textFaint
                catHeader.addSubview(catIconView)
            }

            let catTitle = NSTextField(labelWithString: cat.rawValue.uppercased())
            catTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            catTitle.textColor = Theme.textFaint
            let catTitleAttr = NSMutableAttributedString(string: cat.rawValue.uppercased())
            catTitleAttr.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: catTitleAttr.length))
            catTitleAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .semibold), range: NSRange(location: 0, length: catTitleAttr.length))
            catTitleAttr.addAttribute(.foregroundColor, value: Theme.textFaint, range: NSRange(location: 0, length: catTitleAttr.length))
            catTitle.attributedStringValue = catTitleAttr
            catTitle.frame = NSRect(x: 18, y: 2, width: 200, height: 14)
            catHeader.addSubview(catTitle)

            let catCount = NSTextField(labelWithString: "\(catEntries.count)")
            catCount.font = NSFont.systemFont(ofSize: 9, weight: .bold)
            catCount.textColor = Theme.textGhost
            catCount.frame = NSRect(x: w - pad * 2 - 24, y: 2, width: 20, height: 14)
            catCount.alignment = .right
            catHeader.addSubview(catCount)

            content.addSubview(catHeader)
            y -= 28

            // Widget cards in this category
            for entry in catEntries {
                let isActive = activeWidgets.contains { $0.widgetID == entry.widgetID }
                let canAdd = entry.allowsMultiple || !isActive

                let card = NSView(frame: NSRect(x: pad, y: y - galleryCardHeight, width: w - pad * 2, height: galleryCardHeight))
                card.wantsLayer = true
                card.layer?.backgroundColor = Theme.cardBg.cgColor
                card.layer?.cornerRadius = 12
                card.layer?.borderWidth = 0.5
                card.layer?.borderColor = Theme.cardBorder.cgColor

                // Icon tile
                let gIconTile = NSView(frame: NSRect(x: 12, y: 21, width: 30, height: 30))
                gIconTile.wantsLayer = true
                gIconTile.layer?.cornerRadius = 8
                gIconTile.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
                gIconTile.layer?.borderWidth = 0.5
                gIconTile.layer?.borderColor = Theme.accent.withAlphaComponent(0.27).cgColor
                card.addSubview(gIconTile)

                if let img = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: nil) {
                    let iconView = NSImageView(frame: NSRect(x: 5, y: 5, width: 20, height: 20))
                    iconView.image = img
                    iconView.contentTintColor = Theme.accent
                    gIconTile.addSubview(iconView)
                }

                let nameLabel = NSTextField(labelWithString: entry.displayName)
                nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                nameLabel.textColor = Theme.textPrimary
                nameLabel.frame = NSRect(x: 50, y: 38, width: 200, height: 18)
                card.addSubview(nameLabel)

                let subLabel = NSTextField(labelWithString: entry.subtitle)
                subLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
                subLabel.textColor = Theme.textMuted
                subLabel.frame = NSRect(x: 50, y: 18, width: 250, height: 16)
                card.addSubview(subLabel)

                // Menu bar preview
                let preview = galleryPreviewText(for: entry.widgetID)
                let prevLabel = NSTextField(labelWithString: preview)
                prevLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
                prevLabel.textColor = Theme.textFaint
                prevLabel.frame = NSRect(x: 50, y: 4, width: 250, height: 12)
                card.addSubview(prevLabel)

                let hasRoom = statusBarController.canAddMore
                if canAdd && hasRoom {
                    let addBtn = HoverButton(frame: NSRect(x: card.frame.width - 68, y: 22, width: 52, height: 26))
                    addBtn.wantsLayer = true
                    addBtn.bezelStyle = .inline
                    addBtn.isBordered = false
                    addBtn.title = "Add"
                    addBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                    addBtn.contentTintColor = Theme.accent
                    addBtn.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.10).cgColor
                    addBtn.layer?.cornerRadius = 13
                    addBtn.layer?.borderWidth = 0.5
                    addBtn.layer?.borderColor = Theme.accent.withAlphaComponent(0.3).cgColor
                    addBtn.normalBg = Theme.accent.withAlphaComponent(0.10)
                    addBtn.hoverBg = Theme.accent.withAlphaComponent(0.22)
                    addBtn.target = self
                    addBtn.action = #selector(addWidgetAction(_:))
                    addBtn.identifier = NSUserInterfaceItemIdentifier(entry.widgetID)
                    addBtn.setAccessibilityLabel("Add \(entry.displayName) widget")
                    card.addSubview(addBtn)
                } else if canAdd && !hasRoom {
                    let fullBadge = NSView(frame: NSRect(x: card.frame.width - 60, y: 22, width: 44, height: 20))
                    fullBadge.wantsLayer = true
                    fullBadge.layer?.backgroundColor = Theme.red.withAlphaComponent(0.12).cgColor
                    fullBadge.layer?.cornerRadius = 5
                    fullBadge.layer?.borderWidth = 0.5
                    fullBadge.layer?.borderColor = Theme.red.withAlphaComponent(0.25).cgColor
                    let fullText = NSTextField(labelWithString: "Full")
                    fullText.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                    fullText.textColor = Theme.red
                    fullText.alignment = .center
                    fullText.frame = NSRect(x: 0, y: 2, width: 44, height: 14)
                    fullBadge.addSubview(fullText)
                    card.addSubview(fullBadge)
                } else {
                    let addedBadge = NSView(frame: NSRect(x: card.frame.width - 68, y: 22, width: 52, height: 20))
                    addedBadge.wantsLayer = true
                    addedBadge.layer?.backgroundColor = Theme.green.withAlphaComponent(0.10).cgColor
                    addedBadge.layer?.cornerRadius = 5
                    addedBadge.layer?.borderWidth = 0.5
                    addedBadge.layer?.borderColor = Theme.green.withAlphaComponent(0.25).cgColor
                    let addedText = NSTextField(labelWithString: "Added")
                    addedText.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                    addedText.textColor = Theme.green
                    addedText.alignment = .center
                    addedText.frame = NSRect(x: 0, y: 2, width: 52, height: 14)
                    addedBadge.addSubview(addedText)
                    card.addSubview(addedBadge)
                }

                content.addSubview(card)
                y -= galleryCardHeight + 6
            }
            y -= 8 // spacing between category groups
        }

        y -= 8

        // MARK: Divider 3 - Appearance
        let divider3 = NSView(frame: NSRect(x: pad, y: y, width: w - pad * 2, height: 1))
        divider3.wantsLayer = true
        divider3.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider3)
        y -= 24

        // MARK: Menu Bar Appearance Section
        let appearanceLabel = makeTrackedLabel("MENU BAR APPEARANCE")
        appearanceLabel.frame = NSRect(x: pad, y: y, width: 200, height: 14)
        content.addSubview(appearanceLabel)
        y -= 24

        // Enable toggle
        let currentAppearance = MenuBarAppearance.load()

        let enableRow = NSView(frame: NSRect(x: pad, y: y - 32, width: w - pad * 2, height: 32))
        enableRow.wantsLayer = true

        let enableLabel = NSTextField(labelWithString: "Color Menu Bar")
        enableLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        enableLabel.textColor = Theme.textSecondary
        enableLabel.frame = NSRect(x: 0, y: 7, width: 200, height: 18)
        enableRow.addSubview(enableLabel)

        let enableToggle = NSSwitch()
        enableToggle.frame = NSRect(x: enableRow.frame.width - 46, y: 4, width: 38, height: 22)
        enableToggle.state = currentAppearance.isEnabled ? .on : .off
        enableToggle.target = self
        enableToggle.action = #selector(toggleMenuBarAppearance(_:))
        enableRow.addSubview(enableToggle)

        content.addSubview(enableRow)
        y -= 40

        // Preset grid - 4 per row, 2 rows
        let presets = MenuBarAppearance.presets
        let presetCardW: CGFloat = (w - pad * 2 - 18) / 4
        let presetCardH: CGFloat = 44

        for (i, (name, preset)) in presets.enumerated() {
            let col = i % 4
            let row = i / 4
            let cx = pad + CGFloat(col) * (presetCardW + 6)
            let cy = y - CGFloat(row) * (presetCardH + 8) - presetCardH

            let isActive = currentAppearance.isEnabled && currentAppearance.mode == preset.mode

            let card = NSView(frame: NSRect(x: cx, y: cy, width: presetCardW, height: presetCardH))
            card.wantsLayer = true
            card.layer?.cornerRadius = 10
            card.layer?.borderWidth = isActive ? 1.5 : 0.5
            card.layer?.borderColor = isActive ? Theme.accent.withAlphaComponent(0.6).cgColor : Theme.cardBorder.cgColor

            // Preview gradient/color in the card background
            switch preset.mode {
            case .solid(let color):
                card.layer?.backgroundColor = color.nsColor.withAlphaComponent(0.6).cgColor
            case .gradient(let colors, _):
                let gradientLayer = CAGradientLayer()
                gradientLayer.frame = CGRect(x: 0, y: 0, width: presetCardW, height: presetCardH)
                gradientLayer.cornerRadius = 10
                gradientLayer.colors = colors.map { $0.nsColor.withAlphaComponent(0.7).cgColor }
                gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
                gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
                card.layer?.addSublayer(gradientLayer)
            case .dynamicGradient(let style):
                let colors = MenuBarAppearance.dynamicColors(for: style)
                let gradientLayer = CAGradientLayer()
                gradientLayer.frame = CGRect(x: 0, y: 0, width: presetCardW, height: presetCardH)
                gradientLayer.cornerRadius = 10
                gradientLayer.colors = colors.map { $0.nsColor.withAlphaComponent(0.7).cgColor }
                gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
                gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
                card.layer?.addSublayer(gradientLayer)
            case .frostedGlass:
                card.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.4).cgColor
            }

            // Name label
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 10, weight: isActive ? .bold : .medium)
            nameLabel.textColor = .white
            nameLabel.alignment = .center
            nameLabel.backgroundColor = .clear
            nameLabel.isBezeled = false
            nameLabel.isEditable = false
            nameLabel.frame = NSRect(x: 2, y: 4, width: presetCardW - 4, height: 14)
            nameLabel.shadow = NSShadow()
            nameLabel.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.7)
            nameLabel.shadow?.shadowBlurRadius = 3
            nameLabel.shadow?.shadowOffset = NSSize(width: 0, height: -1)
            card.addSubview(nameLabel)

            // Active indicator
            if isActive {
                let check = NSTextField(labelWithString: "\u{2713}")
                check.font = NSFont.systemFont(ofSize: 11, weight: .bold)
                check.textColor = Theme.accent
                check.backgroundColor = .clear
                check.isBezeled = false
                check.isEditable = false
                check.alignment = .center
                check.frame = NSRect(x: presetCardW - 20, y: presetCardH - 18, width: 16, height: 14)
                card.addSubview(check)
            }

            // Click button
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: presetCardW, height: presetCardH))
            btn.isBordered = false
            btn.isTransparent = true
            btn.target = self
            btn.action = #selector(selectAppearancePreset(_:))
            btn.tag = i
            card.addSubview(btn)

            content.addSubview(card)
        }

        let presetRows = (presets.count + 3) / 4
        y -= CGFloat(presetRows) * (presetCardH + 8) + 8

        // Opacity slider
        let opacityRow = NSView(frame: NSRect(x: pad, y: y - 32, width: w - pad * 2, height: 32))
        opacityRow.wantsLayer = true

        let opacityLabel = NSTextField(labelWithString: "Opacity")
        opacityLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        opacityLabel.textColor = Theme.textSecondary
        opacityLabel.frame = NSRect(x: 0, y: 7, width: 60, height: 18)
        opacityRow.addSubview(opacityLabel)

        let opacitySlider = NSSlider(value: currentAppearance.opacity, minValue: 0.1, maxValue: 1.0, target: self, action: #selector(appearanceOpacityChanged(_:)))
        opacitySlider.frame = NSRect(x: 65, y: 7, width: opacityRow.frame.width - 120, height: 20)
        opacityRow.addSubview(opacitySlider)

        let opacityValue = NSTextField(labelWithString: "\(Int(currentAppearance.opacity * 100))%")
        opacityValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        opacityValue.textColor = Theme.textMuted
        opacityValue.alignment = .right
        opacityValue.frame = NSRect(x: opacityRow.frame.width - 45, y: 7, width: 45, height: 18)
        opacityRow.addSubview(opacityValue)

        content.addSubview(opacityRow)
        y -= 40

        y -= 8

        // MARK: Profiles Section
        let profilesDivider = NSView(frame: NSRect(x: pad, y: y, width: w - pad * 2, height: 1))
        profilesDivider.wantsLayer = true
        profilesDivider.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(profilesDivider)
        y -= 24

        let profilesLabel = makeTrackedLabel("PROFILES")
        profilesLabel.frame = NSRect(x: pad, y: y, width: 140, height: 14)
        content.addSubview(profilesLabel)
        y -= 24

        // Profile presets
        let profilePresets = ProfileManager.presets
        let profileBtnW: CGFloat = (w - pad * 2 - CGFloat(profilePresets.count - 1) * 6) / CGFloat(profilePresets.count)

        for (i, preset) in profilePresets.enumerated() {
            let isActive = ProfileManager.shared.profiles.contains { $0.name == preset.name }
            let cx = pad + CGFloat(i) * (profileBtnW + 6)

            let btn = HoverButton(frame: NSRect(x: cx, y: y - 36, width: profileBtnW, height: 36))
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            btn.layer?.backgroundColor = isActive ? Theme.accent.withAlphaComponent(0.12).cgColor : Theme.cardBg.cgColor
            btn.layer?.borderWidth = isActive ? 1 : 0.5
            btn.layer?.borderColor = isActive ? Theme.accent.withAlphaComponent(0.4).cgColor : Theme.cardBorder.cgColor
            btn.normalBg = isActive ? Theme.accent.withAlphaComponent(0.12) : Theme.cardBg
            btn.hoverBg = Theme.cardBgHover
            btn.isBordered = false
            btn.title = ""

            let icon = NSTextField(labelWithString: preset.icon == "briefcase" ? "\u{1F4BC}" : preset.icon == "house" ? "\u{1F3E0}" : preset.icon == "play.rectangle" ? "\u{1F3AC}" : preset.icon == "terminal" ? "\u{1F4BB}" : "\u{25CB}")
            icon.font = .systemFont(ofSize: 14)
            icon.alignment = .center
            icon.frame = NSRect(x: 0, y: 14, width: profileBtnW, height: 18)
            btn.addSubview(icon)

            let nameLabel = NSTextField(labelWithString: preset.name)
            nameLabel.font = .systemFont(ofSize: 9, weight: .medium)
            nameLabel.textColor = isActive ? Theme.accent : Theme.textMuted
            nameLabel.alignment = .center
            nameLabel.frame = NSRect(x: 0, y: 2, width: profileBtnW, height: 12)
            btn.addSubview(nameLabel)

            btn.target = self
            btn.action = #selector(activateProfile(_:))
            btn.tag = i

            content.addSubview(btn)
        }
        y -= 44

        // Save current as profile button
        let saveProfileBtn = HoverButton(frame: NSRect(x: pad, y: y - 28, width: w - pad * 2, height: 28))
        saveProfileBtn.wantsLayer = true
        saveProfileBtn.layer?.cornerRadius = 8
        saveProfileBtn.layer?.backgroundColor = Theme.cardBg.cgColor
        saveProfileBtn.layer?.borderWidth = 0.5
        saveProfileBtn.layer?.borderColor = Theme.cardBorder.cgColor
        saveProfileBtn.normalBg = Theme.cardBg
        saveProfileBtn.hoverBg = Theme.cardBgHover
        saveProfileBtn.isBordered = false
        saveProfileBtn.title = "Save Current Layout as Profile..."
        saveProfileBtn.font = .systemFont(ofSize: 11, weight: .medium)
        saveProfileBtn.contentTintColor = Theme.textSecondary
        saveProfileBtn.target = self
        saveProfileBtn.action = #selector(saveCurrentProfile)
        content.addSubview(saveProfileBtn)
        y -= 36

        y -= 8

        // MARK: Divider 4 - App Settings
        let divider4 = NSView(frame: NSRect(x: pad, y: y, width: w - pad * 2, height: 1))
        divider4.wantsLayer = true
        divider4.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider4)
        y -= 24

        // MARK: App Settings Section
        let appSettingsLabel = makeTrackedLabel("APP SETTINGS")
        appSettingsLabel.frame = NSRect(x: pad, y: y, width: 140, height: 14)
        content.addSubview(appSettingsLabel)
        y -= 24

        // Launch at Login toggle
        let loginRow = NSView(frame: NSRect(x: pad, y: y - 32, width: w - pad * 2, height: 32))
        loginRow.wantsLayer = true

        let loginLabel = NSTextField(labelWithString: "Launch at Login")
        loginLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        loginLabel.textColor = Theme.textSecondary
        loginLabel.frame = NSRect(x: 0, y: 7, width: 200, height: 18)
        loginRow.addSubview(loginLabel)

        let loginToggle = NSSwitch()
        loginToggle.frame = NSRect(x: loginRow.frame.width - 46, y: 4, width: 38, height: 22)
        loginToggle.state = isLaunchAtLoginEnabled() ? .on : .off
        loginToggle.target = self
        loginToggle.action = #selector(toggleLaunchAtLogin(_:))
        loginRow.addSubview(loginToggle)

        content.addSubview(loginRow)
        y -= 40

        // Check for Updates button
        let updateRow = NSView(frame: NSRect(x: pad, y: y - 32, width: w - pad * 2, height: 32))
        updateRow.wantsLayer = true

        let updateBtn = NSButton(title: "Check for Updates...", target: self, action: #selector(checkForUpdates))
        updateBtn.frame = NSRect(x: 0, y: 4, width: 160, height: 24)
        updateBtn.bezelStyle = .inline
        updateBtn.isBordered = false
        updateBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        updateBtn.contentTintColor = Theme.accent
        updateRow.addSubview(updateBtn)

        content.addSubview(updateRow)
        y -= 40

        // Keyboard shortcut hint
        let shortcutLabel = NSTextField(labelWithString: "Tip: Press Cmd+Shift+B to toggle this window")
        shortcutLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        shortcutLabel.textColor = Theme.textFaint
        shortcutLabel.frame = NSRect(x: pad, y: y - 16, width: w - pad * 2, height: 16)
        content.addSubview(shortcutLabel)
        y -= 24

        // Footer
        let footer = NSTextField(labelWithString: "Barista v1.0 - Your menu bar, your way")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        footer.textColor = Theme.textMuted.withAlphaComponent(0.6)
        footer.alignment = .center
        footer.frame = NSRect(x: 0, y: 10, width: w, height: 14)
        content.addSubview(footer)
    }

    // MARK: - Config Panel Height

    private func configPanelHeight(for instance: WidgetInstance) -> CGFloat {
        switch instance.widgetID {
        case "stock-ticker":
            let stockWidget = instance.widget.underlying(as: StockTickerWidget.self)
            let quoteCount = max(stockWidget?.quotes.count ?? 0, 1)
            return 60 + CGFloat(quoteCount) * 52 + 44 + 180 + 30
        case "cpu-monitor": return 310
        case "ram-monitor": return 326
        case "network-speed": return 326
        case "battery-health": return 310
        case "uptime": return 250
        case "weather-current": return 470
        case "pomodoro": return 400
        case "countdown": return 350
        case "daily-quote": return 290
        case "moon-phase": return 300
        case "custom-date": return 290
        case "daily-goal": return 330
        case "crypto":
            let cw = instance.widget.underlying(as: CryptoWidget.self)
            let quoteCount = max(cw?.quotes.count ?? 0, 1)
            return 60 + CGFloat(quoteCount) * 52 + 44 + 220 + 30
        case "market-status": return 210
        case "world-clock": return 440
        case "calendar-next": return 290
        case "inbox-count": return 210
        case "screen-time": return 210
        case "reminders": return 260
        case "now-playing": return 330
        case "hn-top": return 260
        case "live-scores": return 300
        case "git-branch": return 360
        case "forex-rate": return 310
        case "disk-space": return 260
        case "ip-address": return 250
        case "sunrise-sunset": return 310
        case "tz-diff": return 310
        case "gpu-monitor": return 280
        case "temperature-sensors": return 280
        case "top-processes": return 280
        case "bluetooth-battery": return 250
        case "calendar-grid": return 280
        case "meeting-joiner": return 250
        case "keep-awake": return 250
        case "focus-task": return 230
        case "clipboard-peek": return 230
        case "dark-mode-toggle": return 200
        case "script-widget": return 350
        case "docker-status": return 250
        case "github-notifications": return 250
        case "server-ping": return 280
        case "air-quality": return 280
        case "uv-index": return 250
        case "dad-joke": return 230
        case "dice-roller": return 250
        case "caffeine-tracker": return 300
        case "water-reminder": return 250
        case "stand-reminder": return 250
        case "f1-standings": return 280
        case "soccer-table": return 280
        default: return 200
        }
    }

    // MARK: - Build Config Panel

    private func buildConfigPanel(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        switch instance.widgetID {
        case "stock-ticker":
            buildStockTickerConfig(for: instance, in: panel, width: width)
        case "cpu-monitor":
            buildCPUConfig(for: instance, in: panel, width: width)
        case "ram-monitor":
            buildRAMConfig(for: instance, in: panel, width: width)
        case "network-speed":
            buildNetworkConfig(for: instance, in: panel, width: width)
        case "battery-health":
            buildBatteryConfig(for: instance, in: panel, width: width)
        case "uptime":
            buildUptimeConfig(for: instance, in: panel, width: width)
        case "weather-current":
            buildWeatherConfig(for: instance, in: panel, width: width)
        case "pomodoro":
            buildPomodoroConfig(for: instance, in: panel, width: width)
        case "countdown":
            buildCountdownConfig(for: instance, in: panel, width: width)
        case "daily-quote":
            buildQuoteConfig(for: instance, in: panel, width: width)
        case "moon-phase":
            buildMoonConfig(for: instance, in: panel, width: width)
        case "custom-date":
            buildCustomDateConfig(for: instance, in: panel, width: width)
        case "daily-goal":
            buildGoalConfig(for: instance, in: panel, width: width)
        case "crypto":
            buildCryptoConfig(for: instance, in: panel, width: width)
        case "market-status":
            buildMarketStatusConfig(for: instance, in: panel, width: width)
        case "calendar-next":
            buildCalendarNextConfig(for: instance, in: panel, width: width)
        case "inbox-count":
            buildInboxCountConfig(for: instance, in: panel, width: width)
        case "screen-time":
            buildScreenTimeConfig(for: instance, in: panel, width: width)
        case "reminders":
            buildRemindersConfig(for: instance, in: panel, width: width)
        case "now-playing":
            buildNowPlayingConfig(for: instance, in: panel, width: width)
        case "hn-top":
            buildHackerNewsConfig(for: instance, in: panel, width: width)
        case "live-scores":
            buildLiveScoresConfig(for: instance, in: panel, width: width)
        case "git-branch":
            buildGitBranchConfig(for: instance, in: panel, width: width)
        case "forex-rate":
            buildForexConfig(for: instance, in: panel, width: width)
        case "disk-space":
            buildDiskSpaceConfig(for: instance, in: panel, width: width)
        case "ip-address":
            buildIPAddressConfig(for: instance, in: panel, width: width)
        case "sunrise-sunset":
            buildSunriseSunsetConfig(for: instance, in: panel, width: width)
        case "tz-diff":
            buildTimeZoneDiffConfig(for: instance, in: panel, width: width)
        case "world-clock":
            buildWorldClockConfig(for: instance, in: panel, width: width)
        default:
            buildGenericConfig(for: instance, in: panel, width: width)
        }
    }

    // MARK: - Config Panel Helpers

    @discardableResult
    private func makeStatusCard(lines: [(String, String, NSColor?)], y: inout CGFloat, inset: CGFloat, width: CGFloat, panel: NSView, accentColor: NSColor? = nil) -> NSView {
        let h: CGFloat = CGFloat(max(lines.count, 1)) * 22 + 16
        let card = NSView(frame: NSRect(x: inset, y: y - h, width: width, height: h))
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (accentColor ?? Theme.cardBorder).withAlphaComponent(0.3).cgColor

        if let accent = accentColor {
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: h))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = accent.cgColor
            bar.layer?.cornerRadius = 1.5
            card.addSubview(bar)
        }

        for (i, (label, value, color)) in lines.enumerated() {
            let ly = h - CGFloat(i + 1) * 22 - 2
            let lbl = NSTextField(labelWithString: label)
            lbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            lbl.textColor = Theme.textMuted
            lbl.frame = NSRect(x: 14, y: ly, width: width / 2 - 14, height: 16)
            card.addSubview(lbl)

            let val = NSTextField(labelWithString: value)
            val.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            val.textColor = color ?? Theme.textPrimary
            val.alignment = .right
            val.frame = NSRect(x: width / 2, y: ly, width: width / 2 - 14, height: 16)
            card.addSubview(val)
        }

        panel.addSubview(card)
        y -= h + 8
        return card
    }

    private func makeSettingsHeader(y: inout CGFloat, inset: CGFloat, panel: NSView) {
        let attr = NSMutableAttributedString(string: "SETTINGS")
        attr.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: 8))
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .bold), range: NSRange(location: 0, length: 8))
        attr.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: 8))
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = attr
        label.frame = NSRect(x: inset, y: y - 14, width: 100, height: 14)
        panel.addSubview(label)
        y -= 24
    }

    // MARK: - Stock Ticker Config Panel

    private func buildStockTickerConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let stockWidget = instance.widget.underlying(as: StockTickerWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Portfolio summary card
        let summaryCard = NSView(frame: NSRect(x: inset, y: y - 50, width: cardW, height: 50))
        summaryCard.wantsLayer = true
        summaryCard.layer?.backgroundColor = Theme.cardBg.cgColor
        summaryCard.layer?.cornerRadius = 10
        summaryCard.layer?.borderWidth = 1

        if !stockWidget.quotes.isEmpty {
            let avgChange = stockWidget.quotes.map(\.change).reduce(0, +) / Double(stockWidget.quotes.count)
            summaryCard.layer?.borderColor = Theme.borderForChange(avgChange).cgColor

            let avgLabel = NSTextField(labelWithString: String(format: "Portfolio Avg: %@%.2f%%", avgChange >= 0 ? "+" : "", avgChange))
            avgLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            avgLabel.textColor = Theme.colorForChange(avgChange)
            avgLabel.frame = NSRect(x: 14, y: 16, width: cardW - 28, height: 20)
            summaryCard.addSubview(avgLabel)

            let countLabel = NSTextField(labelWithString: "\(stockWidget.quotes.count) stocks tracked")
            countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = Theme.textMuted
            countLabel.frame = NSRect(x: 14, y: 2, width: 200, height: 14)
            summaryCard.addSubview(countLabel)
        } else {
            summaryCard.layer?.borderColor = Theme.cardBorder.cgColor
            let loadLabel = NSTextField(labelWithString: "Loading stock data...")
            loadLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            loadLabel.textColor = Theme.textMuted
            loadLabel.frame = NSRect(x: 14, y: 16, width: cardW - 28, height: 18)
            summaryCard.addSubview(loadLabel)
        }
        panel.addSubview(summaryCard)
        y -= 58

        // Individual stock cards
        for q in stockWidget.quotes {
            let stockCard = NSView(frame: NSRect(x: inset, y: y - 42, width: cardW, height: 42))
            stockCard.wantsLayer = true
            stockCard.layer?.backgroundColor = Theme.bgForChange(q.change).cgColor
            stockCard.layer?.cornerRadius = 8
            stockCard.layer?.borderWidth = 1
            stockCard.layer?.borderColor = Theme.borderForChange(q.change).cgColor

            // Color accent bar on left
            let accentBar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 42))
            accentBar.wantsLayer = true
            accentBar.layer?.backgroundColor = Theme.colorForChange(q.change).cgColor
            accentBar.layer?.cornerRadius = 1.5
            stockCard.addSubview(accentBar)

            // Symbol
            let symLabel = NSTextField(labelWithString: q.symbol)
            symLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            symLabel.textColor = Theme.textPrimary
            symLabel.frame = NSRect(x: 12, y: 12, width: 60, height: 18)
            stockCard.addSubview(symLabel)

            // Price
            let priceLabel = NSTextField(labelWithString: String(format: "$%.2f", q.price))
            priceLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            priceLabel.textColor = Theme.textPrimary
            priceLabel.alignment = .center
            priceLabel.frame = NSRect(x: cardW / 2 - 50, y: 12, width: 100, height: 18)
            stockCard.addSubview(priceLabel)

            // Change pill
            let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
            let changeStr = String(format: "%@ %.2f%%", arrow, abs(q.change))
            let changePill = NSView(frame: NSRect(x: cardW - 100, y: 10, width: 84, height: 22))
            changePill.wantsLayer = true
            changePill.layer?.backgroundColor = Theme.colorForChange(q.change).withAlphaComponent(0.15).cgColor
            changePill.layer?.cornerRadius = 6

            let changeLabel = NSTextField(labelWithString: changeStr)
            changeLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            changeLabel.textColor = Theme.colorForChange(q.change)
            changeLabel.alignment = .center
            changeLabel.frame = NSRect(x: 0, y: 2, width: 84, height: 16)
            changePill.addSubview(changeLabel)
            stockCard.addSubview(changePill)

            // Remove symbol button (x on far right)
            let removeSymBtn = HoverButton(frame: NSRect(x: cardW - 24, y: 28, width: 14, height: 14))
            removeSymBtn.wantsLayer = true
            removeSymBtn.bezelStyle = .inline
            removeSymBtn.isBordered = false
            removeSymBtn.title = "x"
            removeSymBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            removeSymBtn.contentTintColor = Theme.textMuted.withAlphaComponent(0.5)
            removeSymBtn.layer?.cornerRadius = 7
            removeSymBtn.normalBg = .clear
            removeSymBtn.hoverBg = Theme.redBg
            removeSymBtn.identifier = NSUserInterfaceItemIdentifier("remove-sym:\(q.symbol):\(instance.id.uuidString)")
            removeSymBtn.target = self
            removeSymBtn.action = #selector(removeStockSymbol(_:))
            stockCard.addSubview(removeSymBtn)

            panel.addSubview(stockCard)
            y -= 52
        }

        if stockWidget.quotes.isEmpty {
            // Show placeholder for configured symbols
            for sym in stockWidget.config.symbols {
                let placeholder = NSView(frame: NSRect(x: inset, y: y - 42, width: cardW, height: 42))
                placeholder.wantsLayer = true
                placeholder.layer?.backgroundColor = Theme.cardBg.cgColor
                placeholder.layer?.cornerRadius = 8
                placeholder.layer?.borderWidth = 1
                placeholder.layer?.borderColor = Theme.cardBorder.cgColor

                let symLabel = NSTextField(labelWithString: "\(sym) - Loading...")
                symLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                symLabel.textColor = Theme.textMuted
                symLabel.frame = NSRect(x: 12, y: 12, width: cardW - 24, height: 18)
                placeholder.addSubview(symLabel)
                panel.addSubview(placeholder)
                y -= 52
            }
        }

        y -= 4

        // Add symbol input field
        let addRow = NSView(frame: NSRect(x: inset, y: y - 36, width: cardW, height: 36))
        addRow.wantsLayer = true

        let addField = NSTextField(frame: NSRect(x: 0, y: 4, width: cardW - 70, height: 28))
        addField.placeholderString = "Add ticker (e.g. AAPL)"
        addField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        addField.textColor = Theme.textPrimary
        addField.backgroundColor = Theme.inputBg
        addField.isBordered = false
        addField.isBezeled = true
        addField.bezelStyle = .roundedBezel
        addField.focusRingType = .none
        addField.wantsLayer = true
        addField.layer?.cornerRadius = 8
        addField.identifier = NSUserInterfaceItemIdentifier("addSymbolField:\(instance.id.uuidString)")
        addField.target = self
        addField.action = #selector(addStockSymbolFromField(_:))
        addRow.addSubview(addField)

        let addBtn = HoverButton(frame: NSRect(x: cardW - 60, y: 4, width: 60, height: 28))
        addBtn.wantsLayer = true
        addBtn.bezelStyle = .inline
        addBtn.isBordered = false
        addBtn.title = "+ Add"
        addBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        addBtn.contentTintColor = Theme.accent
        addBtn.layer?.backgroundColor = Theme.accentBg.cgColor
        addBtn.layer?.cornerRadius = 8
        addBtn.normalBg = Theme.accentBg
        addBtn.hoverBg = NSColor(red: 0.38, green: 0.50, blue: 1.0, alpha: 0.20)
        addBtn.identifier = NSUserInterfaceItemIdentifier("addSymbolBtn:\(instance.id.uuidString)")
        addBtn.target = self
        addBtn.action = #selector(addStockSymbolFromButton(_:))
        addRow.addSubview(addBtn)

        panel.addSubview(addRow)
        y -= 44

        // MARK: Settings section
        y -= 8
        let settingsLabel = NSTextField(labelWithString: "SETTINGS")
        settingsLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        settingsLabel.textColor = Theme.textMuted
        let settingsAttr = NSMutableAttributedString(string: "SETTINGS")
        settingsAttr.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: 8))
        settingsAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .bold), range: NSRange(location: 0, length: 8))
        settingsAttr.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: 8))
        settingsLabel.attributedStringValue = settingsAttr
        settingsLabel.frame = NSRect(x: inset, y: y - 14, width: 100, height: 14)
        panel.addSubview(settingsLabel)
        y -= 24

        // Scroll Speed slider
        let speedRow = makeSettingRow(label: "Scroll Speed", y: y, inset: inset, width: cardW)
        let speedSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        speedSlider.minValue = 0.1
        speedSlider.maxValue = 2.0
        speedSlider.doubleValue = stockWidget.config.scrollSpeed
        speedSlider.target = self
        speedSlider.action = #selector(stockSpeedChanged(_:))
        speedSlider.identifier = NSUserInterfaceItemIdentifier("speedSlider:\(instance.id.uuidString)")
        panel.addSubview(speedRow)
        panel.addSubview(speedSlider)
        y -= 36

        // Colored Ticker toggle
        let colorRow = makeSettingRow(label: "Colored Ticker", y: y, inset: inset, width: cardW)
        let colorToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        colorToggle.state = stockWidget.config.coloredTicker ? .on : .off
        colorToggle.target = self
        colorToggle.action = #selector(stockColorToggled(_:))
        colorToggle.identifier = NSUserInterfaceItemIdentifier("colorToggle:\(instance.id.uuidString)")
        panel.addSubview(colorRow)
        panel.addSubview(colorToggle)
        y -= 36

        // Ticker Width slider
        let widthRow = makeSettingRow(label: "Ticker Width", y: y, inset: inset, width: cardW)
        let widthSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        widthSlider.minValue = 80
        widthSlider.maxValue = 400
        widthSlider.doubleValue = stockWidget.config.tickerWidth
        widthSlider.target = self
        widthSlider.action = #selector(stockWidthChanged(_:))
        widthSlider.identifier = NSUserInterfaceItemIdentifier("widthSlider:\(instance.id.uuidString)")
        panel.addSubview(widthRow)
        panel.addSubview(widthSlider)
        y -= 36

        // Refresh Interval dropdown
        let refreshRow = makeSettingRow(label: "Refresh Interval", y: y, inset: inset, width: cardW)
        let refreshPopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        refreshPopup.addItems(withTitles: ["15 sec", "30 sec", "1 min", "2 min", "5 min"])
        let intervals: [TimeInterval] = [15, 30, 60, 120, 300]
        if let idx = intervals.firstIndex(of: stockWidget.config.refreshInterval) {
            refreshPopup.selectItem(at: idx)
        } else {
            refreshPopup.selectItem(at: 2)
        }
        refreshPopup.target = self
        refreshPopup.action = #selector(stockRefreshChanged(_:))
        refreshPopup.identifier = NSUserInterfaceItemIdentifier("refreshPopup:\(instance.id.uuidString)")
        panel.addSubview(refreshRow)
        panel.addSubview(refreshPopup)
    }

    // MARK: - CPU Config Panel

    private func buildCPUConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: CPUWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let cpuColor: NSColor = w.cpuUsage >= w.config.alertThreshold ? Theme.red : Theme.green
        let avg = w.history.isEmpty ? 0 : w.history.reduce(0, +) / Double(w.history.count)
        let peak = w.history.max() ?? 0
        let cores = ProcessInfo.processInfo.activeProcessorCount
        makeStatusCard(lines: [
            ("Current", String(format: "%.1f%%", w.cpuUsage), cpuColor),
            ("Average", String(format: "%.1f%%", avg), nil),
            ("Peak", String(format: "%.1f%%", peak), peak >= w.config.alertThreshold ? Theme.red : nil),
            ("Cores", "\(cores)", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: cpuColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let pctRow = makeSettingRow(label: "Show Percentage", y: y, inset: inset, width: cardW)
        let pctToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        pctToggle.state = w.config.showPercentage ? .on : .off
        pctToggle.target = self; pctToggle.action = #selector(configToggleChanged(_:))
        pctToggle.identifier = NSUserInterfaceItemIdentifier("cfg:cpu-monitor:showPercentage:\(instance.id.uuidString)")
        panel.addSubview(pctRow); panel.addSubview(pctToggle)
        y -= 36

        let barRow = makeSettingRow(label: "Show Bar", y: y, inset: inset, width: cardW)
        let barToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        barToggle.state = w.config.showBar ? .on : .off
        barToggle.target = self; barToggle.action = #selector(configToggleChanged(_:))
        barToggle.identifier = NSUserInterfaceItemIdentifier("cfg:cpu-monitor:showBar:\(instance.id.uuidString)")
        panel.addSubview(barRow); panel.addSubview(barToggle)
        y -= 36

        let threshRow = makeSettingRow(label: "Alert Threshold", y: y, inset: inset, width: cardW)
        let threshSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        threshSlider.minValue = 50; threshSlider.maxValue = 100
        threshSlider.doubleValue = w.config.alertThreshold
        threshSlider.target = self; threshSlider.action = #selector(configSliderChanged(_:))
        threshSlider.identifier = NSUserInterfaceItemIdentifier("cfg:cpu-monitor:alertThreshold:\(instance.id.uuidString)")
        panel.addSubview(threshRow); panel.addSubview(threshSlider)
        y -= 36

        let rateRow = makeSettingRow(label: "Refresh Rate", y: y, inset: inset, width: cardW)
        let ratePopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        ratePopup.addItems(withTitles: ["1 sec", "2 sec", "3 sec", "5 sec", "10 sec"])
        let rates: [TimeInterval] = [1, 2, 3, 5, 10]
        if let idx = rates.firstIndex(of: w.config.refreshRate) { ratePopup.selectItem(at: idx) }
        ratePopup.target = self; ratePopup.action = #selector(configPopupChanged(_:))
        ratePopup.identifier = NSUserInterfaceItemIdentifier("cfg:cpu-monitor:refreshRate:\(instance.id.uuidString)")
        panel.addSubview(rateRow); panel.addSubview(ratePopup)
    }

    // MARK: - RAM Config Panel

    private func buildRAMConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: RAMWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        let ramColor: NSColor = w.percentage >= w.config.alertThreshold ? Theme.red : Theme.green
        makeStatusCard(lines: [
            ("Used", String(format: "%.1f GB", w.usedGB), nil),
            ("Total", String(format: "%.0f GB", w.totalGB), nil),
            ("Free", String(format: "%.1f GB", w.totalGB - w.usedGB), nil),
            ("Usage", String(format: "%.1f%%", w.percentage), ramColor),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: ramColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let absRow = makeSettingRow(label: "Show GB (vs %)", y: y, inset: inset, width: cardW)
        let absToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        absToggle.state = w.config.showAbsolute ? .on : .off
        absToggle.target = self; absToggle.action = #selector(configToggleChanged(_:))
        absToggle.identifier = NSUserInterfaceItemIdentifier("cfg:ram-monitor:showAbsolute:\(instance.id.uuidString)")
        panel.addSubview(absRow); panel.addSubview(absToggle)
        y -= 36

        let barRow = makeSettingRow(label: "Show Bar", y: y, inset: inset, width: cardW)
        let barToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        barToggle.state = w.config.showBar ? .on : .off
        barToggle.target = self; barToggle.action = #selector(configToggleChanged(_:))
        barToggle.identifier = NSUserInterfaceItemIdentifier("cfg:ram-monitor:showBar:\(instance.id.uuidString)")
        panel.addSubview(barRow); panel.addSubview(barToggle)
        y -= 36

        let threshRow = makeSettingRow(label: "Alert Threshold", y: y, inset: inset, width: cardW)
        let threshSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        threshSlider.minValue = 50; threshSlider.maxValue = 100
        threshSlider.doubleValue = w.config.alertThreshold
        threshSlider.target = self; threshSlider.action = #selector(configSliderChanged(_:))
        threshSlider.identifier = NSUserInterfaceItemIdentifier("cfg:ram-monitor:alertThreshold:\(instance.id.uuidString)")
        panel.addSubview(threshRow); panel.addSubview(threshSlider)
        y -= 36

        let rateRow = makeSettingRow(label: "Refresh Rate", y: y, inset: inset, width: cardW)
        let ratePopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        ratePopup.addItems(withTitles: ["1 sec", "2 sec", "5 sec", "10 sec"])
        let rates: [TimeInterval] = [1, 2, 5, 10]
        if let idx = rates.firstIndex(of: w.config.refreshRate) { ratePopup.selectItem(at: idx) }
        else { ratePopup.selectItem(at: 2) }
        ratePopup.target = self; ratePopup.action = #selector(configPopupChanged(_:))
        ratePopup.identifier = NSUserInterfaceItemIdentifier("cfg:ram-monitor:refreshRate:\(instance.id.uuidString)")
        panel.addSubview(rateRow); panel.addSubview(ratePopup)
    }

    // MARK: - Network Speed Config Panel

    private func buildNetworkConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: NetworkSpeedWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        makeStatusCard(lines: [
            ("Download", w.formatSpeedForCard(w.downloadSpeed), Theme.green),
            ("Upload", w.formatSpeedForCard(w.uploadSpeed), Theme.accent),
            ("Session Down", w.formatTotalForCard(w.sessionDownTotal), nil),
            ("Session Up", w.formatTotalForCard(w.sessionUpTotal), nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: Theme.accent)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let dlRow = makeSettingRow(label: "Show Download", y: y, inset: inset, width: cardW)
        let dlToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        dlToggle.state = w.config.showDownload ? .on : .off
        dlToggle.target = self; dlToggle.action = #selector(configToggleChanged(_:))
        dlToggle.identifier = NSUserInterfaceItemIdentifier("cfg:network-speed:showDownload:\(instance.id.uuidString)")
        panel.addSubview(dlRow); panel.addSubview(dlToggle)
        y -= 36

        let ulRow = makeSettingRow(label: "Show Upload", y: y, inset: inset, width: cardW)
        let ulToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        ulToggle.state = w.config.showUpload ? .on : .off
        ulToggle.target = self; ulToggle.action = #selector(configToggleChanged(_:))
        ulToggle.identifier = NSUserInterfaceItemIdentifier("cfg:network-speed:showUpload:\(instance.id.uuidString)")
        panel.addSubview(ulRow); panel.addSubview(ulToggle)
        y -= 36

        let compactRow = makeSettingRow(label: "Compact Format", y: y, inset: inset, width: cardW)
        let compactToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        compactToggle.state = w.config.compactFormat ? .on : .off
        compactToggle.target = self; compactToggle.action = #selector(configToggleChanged(_:))
        compactToggle.identifier = NSUserInterfaceItemIdentifier("cfg:network-speed:compactFormat:\(instance.id.uuidString)")
        panel.addSubview(compactRow); panel.addSubview(compactToggle)
        y -= 36

        let rateRow = makeSettingRow(label: "Refresh Rate", y: y, inset: inset, width: cardW)
        let ratePopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        ratePopup.addItems(withTitles: ["1 sec", "2 sec", "3 sec", "5 sec"])
        let netRates: [TimeInterval] = [1, 2, 3, 5]
        if let idx = netRates.firstIndex(of: w.config.refreshRate) { ratePopup.selectItem(at: idx) }
        else { ratePopup.selectItem(at: 1) }
        ratePopup.target = self; ratePopup.action = #selector(configPopupChanged(_:))
        ratePopup.identifier = NSUserInterfaceItemIdentifier("cfg:network-speed:refreshRate:\(instance.id.uuidString)")
        panel.addSubview(rateRow); panel.addSubview(ratePopup)
    }

    // MARK: - Battery Config Panel

    private func buildBatteryConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: BatteryWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        let batColor: NSColor = w.level <= w.config.alertBelow && !w.isCharging ? Theme.red : (w.isCharging ? Theme.green : Theme.accent)
        let timeStr = w.timeRemaining > 0 ? "\(w.timeRemaining / 60)h \(w.timeRemaining % 60)m" : "Calculating..."
        makeStatusCard(lines: [
            ("Level", "\(w.level)%", batColor),
            ("Status", w.isCharging ? "Charging" : "On Battery", w.isCharging ? Theme.green : nil),
            ("Time", timeStr, nil),
            ("Health", "\(w.health)%", w.health < 80 ? Theme.red : nil),
            ("Cycles", "\(w.cycleCount)", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: batColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let timeRow = makeSettingRow(label: "Show Time Remaining", y: y, inset: inset, width: cardW)
        let timeToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        timeToggle.state = w.config.showTimeRemaining ? .on : .off
        timeToggle.target = self; timeToggle.action = #selector(configToggleChanged(_:))
        timeToggle.identifier = NSUserInterfaceItemIdentifier("cfg:battery-health:showTimeRemaining:\(instance.id.uuidString)")
        panel.addSubview(timeRow); panel.addSubview(timeToggle)
        y -= 36

        let healthRow = makeSettingRow(label: "Show Health %", y: y, inset: inset, width: cardW)
        let healthToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        healthToggle.state = w.config.showHealth ? .on : .off
        healthToggle.target = self; healthToggle.action = #selector(configToggleChanged(_:))
        healthToggle.identifier = NSUserInterfaceItemIdentifier("cfg:battery-health:showHealth:\(instance.id.uuidString)")
        panel.addSubview(healthRow); panel.addSubview(healthToggle)
        y -= 36

        let cycleRow = makeSettingRow(label: "Show Cycles", y: y, inset: inset, width: cardW)
        let cycleToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        cycleToggle.state = w.config.showCycles ? .on : .off
        cycleToggle.target = self; cycleToggle.action = #selector(configToggleChanged(_:))
        cycleToggle.identifier = NSUserInterfaceItemIdentifier("cfg:battery-health:showCycles:\(instance.id.uuidString)")
        panel.addSubview(cycleRow); panel.addSubview(cycleToggle)
        y -= 36

        let alertRow = makeSettingRow(label: "Alert Below %", y: y, inset: inset, width: cardW)
        let alertSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        alertSlider.minValue = 5; alertSlider.maxValue = 50
        alertSlider.doubleValue = Double(w.config.alertBelow)
        alertSlider.target = self; alertSlider.action = #selector(configSliderChanged(_:))
        alertSlider.identifier = NSUserInterfaceItemIdentifier("cfg:battery-health:alertBelow:\(instance.id.uuidString)")
        panel.addSubview(alertRow); panel.addSubview(alertSlider)
    }

    // MARK: - Uptime Config Panel

    private func buildUptimeConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: UptimeWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        let up = ProcessInfo.processInfo.systemUptime
        let days = Int(up) / 86400
        let hours = (Int(up) % 86400) / 3600
        let mins = (Int(up) % 3600) / 60
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        makeStatusCard(lines: [
            ("Uptime", "\(days)d \(hours)h \(mins)m", nil),
            ("Boot Time", df.string(from: Date().addingTimeInterval(-up)), nil),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString, nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: Theme.accent)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let labelRow = makeSettingRow(label: "Show 'Up' Label", y: y, inset: inset, width: cardW)
        let labelToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        labelToggle.state = w.config.showLabel ? .on : .off
        labelToggle.target = self; labelToggle.action = #selector(configToggleChanged(_:))
        labelToggle.identifier = NSUserInterfaceItemIdentifier("cfg:uptime:showLabel:\(instance.id.uuidString)")
        panel.addSubview(labelRow); panel.addSubview(labelToggle)
        y -= 36

        let secRow = makeSettingRow(label: "Show Seconds", y: y, inset: inset, width: cardW)
        let secToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        secToggle.state = w.config.showSeconds ? .on : .off
        secToggle.target = self; secToggle.action = #selector(configToggleChanged(_:))
        secToggle.identifier = NSUserInterfaceItemIdentifier("cfg:uptime:showSeconds:\(instance.id.uuidString)")
        panel.addSubview(secRow); panel.addSubview(secToggle)
    }

    // MARK: - Weather Config Panel

    private func buildWeatherConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: WeatherWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let unit = w.config.useCelsius ? "C" : "F"
        if let temp = w.temperature {
            let emoji = w.weatherEmoji(code: w.weatherCode)
            let desc = w.weatherDesc(code: w.weatherCode)
            var lines: [(String, String, NSColor?)] = [
                ("Condition", "\(emoji) \(desc)", nil),
                ("Temperature", String(format: "%.0f\u{00B0}%@", temp, unit), nil),
            ]
            if let feels = w.feelsLike { lines.append(("Feels Like", String(format: "%.0f\u{00B0}%@", feels, unit), nil)) }
            lines.append(("Humidity", "\(w.humidity)%", nil))
            lines.append(("Wind", String(format: "%.1f mph", w.windSpeed), nil))
            if let hi = w.highTemp, let lo = w.lowTemp {
                lines.append(("Hi / Lo", String(format: "%.0f\u{00B0} / %.0f\u{00B0}", hi, lo), nil))
            }
            makeStatusCard(lines: lines, y: &y, inset: inset, width: cardW, panel: panel)
        } else {
            makeStatusCard(lines: [("Status", "Loading...", Theme.textMuted)], y: &y, inset: inset, width: cardW, panel: panel)
        }

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let cityRow = makeSettingRow(label: "City Name", y: y, inset: inset, width: cardW)
        let cityField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        cityField.stringValue = w.config.cityName
        cityField.font = NSFont.systemFont(ofSize: 12)
        cityField.textColor = Theme.textPrimary
        cityField.backgroundColor = Theme.inputBg
        cityField.isBordered = false; cityField.isBezeled = true; cityField.bezelStyle = .roundedBezel
        cityField.focusRingType = .none
        cityField.target = self; cityField.action = #selector(configTextChanged(_:))
        cityField.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:cityName:\(instance.id.uuidString)")
        panel.addSubview(cityRow); panel.addSubview(cityField)
        y -= 36

        let unitRow = makeSettingRow(label: "Use Celsius", y: y, inset: inset, width: cardW)
        let unitToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        unitToggle.state = w.config.useCelsius ? .on : .off
        unitToggle.target = self; unitToggle.action = #selector(configToggleChanged(_:))
        unitToggle.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:useCelsius:\(instance.id.uuidString)")
        panel.addSubview(unitRow); panel.addSubview(unitToggle)
        y -= 36

        let feelsRow = makeSettingRow(label: "Show Feels Like", y: y, inset: inset, width: cardW)
        let feelsToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        feelsToggle.state = w.config.showFeelsLike ? .on : .off
        feelsToggle.target = self; feelsToggle.action = #selector(configToggleChanged(_:))
        feelsToggle.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:showFeelsLike:\(instance.id.uuidString)")
        panel.addSubview(feelsRow); panel.addSubview(feelsToggle)
        y -= 36

        let emojiRow = makeSettingRow(label: "Show Emoji", y: y, inset: inset, width: cardW)
        let emojiToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        emojiToggle.state = w.config.showEmoji ? .on : .off
        emojiToggle.target = self; emojiToggle.action = #selector(configToggleChanged(_:))
        emojiToggle.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:showEmoji:\(instance.id.uuidString)")
        panel.addSubview(emojiRow); panel.addSubview(emojiToggle)
        y -= 36

        let showCityRow = makeSettingRow(label: "Show City in Bar", y: y, inset: inset, width: cardW)
        let showCityToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        showCityToggle.state = w.config.showCity ? .on : .off
        showCityToggle.target = self; showCityToggle.action = #selector(configToggleChanged(_:))
        showCityToggle.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:showCity:\(instance.id.uuidString)")
        panel.addSubview(showCityRow); panel.addSubview(showCityToggle)
        y -= 36

        let latRow = makeSettingRow(label: "Latitude", y: y, inset: inset, width: cardW)
        let latField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        latField.stringValue = w.config.manualLat.map { String(format: "%.4f", $0) } ?? ""
        latField.placeholderString = "40.7128"
        latField.font = NSFont.systemFont(ofSize: 12)
        latField.textColor = Theme.textPrimary
        latField.backgroundColor = Theme.inputBg
        latField.isBordered = false; latField.isBezeled = true; latField.bezelStyle = .roundedBezel
        latField.focusRingType = .none
        latField.target = self; latField.action = #selector(configTextChanged(_:))
        latField.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:manualLat:\(instance.id.uuidString)")
        panel.addSubview(latRow); panel.addSubview(latField)
        y -= 36

        let lonRow = makeSettingRow(label: "Longitude", y: y, inset: inset, width: cardW)
        let lonField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        lonField.stringValue = w.config.manualLon.map { String(format: "%.4f", $0) } ?? ""
        lonField.placeholderString = "-74.0060"
        lonField.font = NSFont.systemFont(ofSize: 12)
        lonField.textColor = Theme.textPrimary
        lonField.backgroundColor = Theme.inputBg
        lonField.isBordered = false; lonField.isBezeled = true; lonField.bezelStyle = .roundedBezel
        lonField.focusRingType = .none
        lonField.target = self; lonField.action = #selector(configTextChanged(_:))
        lonField.identifier = NSUserInterfaceItemIdentifier("cfg:weather-current:manualLon:\(instance.id.uuidString)")
        panel.addSubview(lonRow); panel.addSubview(lonField)
    }

    // MARK: - Pomodoro Config Panel

    private func buildPomodoroConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: PomodoroWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let stateStr: String
        let stateColor: NSColor
        switch w.state {
        case .idle: stateStr = "Idle"; stateColor = Theme.textMuted
        case .working: stateStr = "Working"; stateColor = Theme.red
        case .shortBreak: stateStr = "Short Break"; stateColor = Theme.green
        case .longBreak: stateStr = "Long Break"; stateColor = Theme.green
        }
        let min = w.secondsRemaining / 60
        let sec = w.secondsRemaining % 60
        let focusMin = w.totalFocusToday / 60
        makeStatusCard(lines: [
            ("Status", stateStr, stateColor),
            ("Time Left", w.state == .idle ? "--" : String(format: "%d:%02d", min, sec), nil),
            ("Sessions", "\(w.completedCycles)", nil),
            ("Focus Today", "\(focusMin)m", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: stateColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let workRow = makeSettingRow(label: "Work (minutes)", y: y, inset: inset, width: cardW)
        let workSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        workSlider.minValue = 5; workSlider.maxValue = 60
        workSlider.doubleValue = Double(w.config.workMinutes)
        workSlider.target = self; workSlider.action = #selector(configSliderChanged(_:))
        workSlider.identifier = NSUserInterfaceItemIdentifier("cfg:pomodoro:workMinutes:\(instance.id.uuidString)")
        panel.addSubview(workRow); panel.addSubview(workSlider)
        y -= 36

        let shortRow = makeSettingRow(label: "Short Break (min)", y: y, inset: inset, width: cardW)
        let shortSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        shortSlider.minValue = 1; shortSlider.maxValue = 15
        shortSlider.doubleValue = Double(w.config.shortBreakMinutes)
        shortSlider.target = self; shortSlider.action = #selector(configSliderChanged(_:))
        shortSlider.identifier = NSUserInterfaceItemIdentifier("cfg:pomodoro:shortBreakMinutes:\(instance.id.uuidString)")
        panel.addSubview(shortRow); panel.addSubview(shortSlider)
        y -= 36

        let longRow = makeSettingRow(label: "Long Break (min)", y: y, inset: inset, width: cardW)
        let longSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        longSlider.minValue = 5; longSlider.maxValue = 30
        longSlider.doubleValue = Double(w.config.longBreakMinutes)
        longSlider.target = self; longSlider.action = #selector(configSliderChanged(_:))
        longSlider.identifier = NSUserInterfaceItemIdentifier("cfg:pomodoro:longBreakMinutes:\(instance.id.uuidString)")
        panel.addSubview(longRow); panel.addSubview(longSlider)
        y -= 36

        let cyclesRow = makeSettingRow(label: "Cycles Before Long", y: y, inset: inset, width: cardW)
        let cyclesSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        cyclesSlider.minValue = 2; cyclesSlider.maxValue = 8
        cyclesSlider.doubleValue = Double(w.config.cyclesBeforeLong)
        cyclesSlider.target = self; cyclesSlider.action = #selector(configSliderChanged(_:))
        cyclesSlider.identifier = NSUserInterfaceItemIdentifier("cfg:pomodoro:cyclesBeforeLong:\(instance.id.uuidString)")
        panel.addSubview(cyclesRow); panel.addSubview(cyclesSlider)
        y -= 36

        let autoRow = makeSettingRow(label: "Auto-Start Breaks", y: y, inset: inset, width: cardW)
        let autoToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        autoToggle.state = w.config.autoStartBreak ? .on : .off
        autoToggle.target = self; autoToggle.action = #selector(configToggleChanged(_:))
        autoToggle.identifier = NSUserInterfaceItemIdentifier("cfg:pomodoro:autoStartBreak:\(instance.id.uuidString)")
        panel.addSubview(autoRow); panel.addSubview(autoToggle)
        y -= 36

        let emojiRow = makeSettingRow(label: "Show Emoji", y: y, inset: inset, width: cardW)
        let emojiToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        emojiToggle.state = w.config.showEmoji ? .on : .off
        emojiToggle.target = self; emojiToggle.action = #selector(configToggleChanged(_:))
        emojiToggle.identifier = NSUserInterfaceItemIdentifier("cfg:pomodoro:showEmoji:\(instance.id.uuidString)")
        panel.addSubview(emojiRow); panel.addSubview(emojiToggle)
    }

    // MARK: - Countdown Config Panel

    private func buildCountdownConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: CountdownWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let diff = w.config.targetDate.timeIntervalSince(Date())
        let absDiff = abs(diff)
        let days = Int(absDiff) / 86400
        let hours = (Int(absDiff) % 86400) / 3600
        let mins = (Int(absDiff) % 3600) / 60
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let statusColor: NSColor = diff <= 0 ? Theme.red : (days < 7 ? Theme.brandAmber : Theme.green)
        makeStatusCard(lines: [
            ("Event", "\(w.config.emoji) \(w.config.eventName)", nil),
            ("Target", df.string(from: w.config.targetDate), nil),
            (diff >= 0 ? "Remaining" : "Elapsed", "\(days)d \(hours)h \(mins)m", statusColor),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: statusColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let nameRow = makeSettingRow(label: "Event Name", y: y, inset: inset, width: cardW)
        let nameField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        nameField.stringValue = w.config.eventName
        nameField.font = NSFont.systemFont(ofSize: 12)
        nameField.textColor = Theme.textPrimary
        nameField.backgroundColor = Theme.inputBg
        nameField.isBordered = false; nameField.isBezeled = true; nameField.bezelStyle = .roundedBezel
        nameField.focusRingType = .none
        nameField.target = self; nameField.action = #selector(configTextChanged(_:))
        nameField.identifier = NSUserInterfaceItemIdentifier("cfg:countdown:eventName:\(instance.id.uuidString)")
        panel.addSubview(nameRow); panel.addSubview(nameField)
        y -= 36

        let emojiRow = makeSettingRow(label: "Emoji", y: y, inset: inset, width: cardW)
        let emojiField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: 50, height: 24))
        emojiField.stringValue = w.config.emoji
        emojiField.font = NSFont.systemFont(ofSize: 14)
        emojiField.textColor = Theme.textPrimary
        emojiField.backgroundColor = Theme.inputBg
        emojiField.isBordered = false; emojiField.isBezeled = true; emojiField.bezelStyle = .roundedBezel
        emojiField.focusRingType = .none
        emojiField.target = self; emojiField.action = #selector(configTextChanged(_:))
        emojiField.identifier = NSUserInterfaceItemIdentifier("cfg:countdown:emoji:\(instance.id.uuidString)")
        panel.addSubview(emojiRow); panel.addSubview(emojiField)
        y -= 36

        let dateRow = makeSettingRow(label: "Target Date", y: y, inset: inset, width: cardW)
        let datePicker = NSDatePicker(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = w.config.targetDate
        datePicker.target = self; datePicker.action = #selector(countdownDateChanged(_:))
        datePicker.identifier = NSUserInterfaceItemIdentifier("cfg:countdown:targetDate:\(instance.id.uuidString)")
        panel.addSubview(dateRow); panel.addSubview(datePicker)
        y -= 36

        let secRow = makeSettingRow(label: "Show Seconds", y: y, inset: inset, width: cardW)
        let secToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        secToggle.state = w.config.showSeconds ? .on : .off
        secToggle.target = self; secToggle.action = #selector(configToggleChanged(_:))
        secToggle.identifier = NSUserInterfaceItemIdentifier("cfg:countdown:showSeconds:\(instance.id.uuidString)")
        panel.addSubview(secRow); panel.addSubview(secToggle)
        y -= 36

        let countUpRow = makeSettingRow(label: "Count Up After", y: y, inset: inset, width: cardW)
        let countUpToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        countUpToggle.state = w.config.countUpAfter ? .on : .off
        countUpToggle.target = self; countUpToggle.action = #selector(configToggleChanged(_:))
        countUpToggle.identifier = NSUserInterfaceItemIdentifier("cfg:countdown:countUpAfter:\(instance.id.uuidString)")
        panel.addSubview(countUpRow); panel.addSubview(countUpToggle)
    }

    // MARK: - Daily Quote Config Panel

    private func buildQuoteConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: DailyQuoteWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let quotePreview = w.currentQuote.count > 60 ? String(w.currentQuote.prefix(57)) + "..." : w.currentQuote
        makeStatusCard(lines: [
            ("Quote", "\u{201C}\(quotePreview)\u{201D}", nil),
            ("Author", w.currentAuthor, nil),
        ], y: &y, inset: inset, width: cardW, panel: panel)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let barRow = makeSettingRow(label: "Show in Bar", y: y, inset: inset, width: cardW)
        let barToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        barToggle.state = w.config.showInBar ? .on : .off
        barToggle.target = self; barToggle.action = #selector(configToggleChanged(_:))
        barToggle.identifier = NSUserInterfaceItemIdentifier("cfg:daily-quote:showInBar:\(instance.id.uuidString)")
        panel.addSubview(barRow); panel.addSubview(barToggle)
        y -= 36

        let scrollRow = makeSettingRow(label: "Scroll in Bar", y: y, inset: inset, width: cardW)
        let scrollToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        scrollToggle.state = w.config.scrollInBar ? .on : .off
        scrollToggle.target = self; scrollToggle.action = #selector(configToggleChanged(_:))
        scrollToggle.identifier = NSUserInterfaceItemIdentifier("cfg:daily-quote:scrollInBar:\(instance.id.uuidString)")
        panel.addSubview(scrollRow); panel.addSubview(scrollToggle)
        y -= 36

        let widthRow = makeSettingRow(label: "Ticker Width", y: y, inset: inset, width: cardW)
        let widthSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        widthSlider.minValue = 100; widthSlider.maxValue = 400
        widthSlider.doubleValue = w.config.tickerWidth
        widthSlider.target = self; widthSlider.action = #selector(configSliderChanged(_:))
        widthSlider.identifier = NSUserInterfaceItemIdentifier("cfg:daily-quote:tickerWidth:\(instance.id.uuidString)")
        panel.addSubview(widthRow); panel.addSubview(widthSlider)
    }

    // MARK: - Moon Phase Config Panel

    private func buildMoonConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: MoonPhaseWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let synodicMonth = 29.53058867
        let daysToFull = w.phase < 0.5 ? (0.5 - w.phase) * synodicMonth : (1.5 - w.phase) * synodicMonth
        let daysToNew = (1.0 - w.phase) * synodicMonth
        makeStatusCard(lines: [
            ("Phase", "\(w.phaseEmoji) \(w.phaseName)", nil),
            ("Illumination", String(format: "%.1f%%", w.illumination), nil),
            ("Next Full", String(format: "%.0f days", daysToFull), nil),
            ("Next New", String(format: "%.0f days", daysToNew), nil),
        ], y: &y, inset: inset, width: cardW, panel: panel)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let nameRow = makeSettingRow(label: "Show Phase Name", y: y, inset: inset, width: cardW)
        let nameToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        nameToggle.state = w.config.showName ? .on : .off
        nameToggle.target = self; nameToggle.action = #selector(configToggleChanged(_:))
        nameToggle.identifier = NSUserInterfaceItemIdentifier("cfg:moon-phase:showName:\(instance.id.uuidString)")
        panel.addSubview(nameRow); panel.addSubview(nameToggle)
        y -= 36

        let illumRow = makeSettingRow(label: "Show Illumination", y: y, inset: inset, width: cardW)
        let illumToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        illumToggle.state = w.config.showIllumination ? .on : .off
        illumToggle.target = self; illumToggle.action = #selector(configToggleChanged(_:))
        illumToggle.identifier = NSUserInterfaceItemIdentifier("cfg:moon-phase:showIllumination:\(instance.id.uuidString)")
        panel.addSubview(illumRow); panel.addSubview(illumToggle)
        y -= 36

        let countdownRow = makeSettingRow(label: "Show Countdown to Full", y: y, inset: inset, width: cardW)
        let countdownToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        countdownToggle.state = w.config.showCountdown ? .on : .off
        countdownToggle.target = self; countdownToggle.action = #selector(configToggleChanged(_:))
        countdownToggle.identifier = NSUserInterfaceItemIdentifier("cfg:moon-phase:showCountdown:\(instance.id.uuidString)")
        panel.addSubview(countdownRow); panel.addSubview(countdownToggle)
    }

    // MARK: - Custom Date Config Panel

    private func buildCustomDateConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: CustomDateWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let cal = Calendar.current
        let now = Date()
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: now) ?? 1
        let daysInYear = cal.range(of: .day, in: .year, for: now)?.count ?? 365
        let week = cal.component(.weekOfYear, from: now)
        let month = cal.component(.month, from: now)
        let quarter = (month - 1) / 3 + 1
        makeStatusCard(lines: [
            ("Day of Year", "\(dayOfYear) / \(daysInYear)", nil),
            ("Week", "\(week)", nil),
            ("Quarter", "Q\(quarter)", nil),
            ("Days Left", "\(daysInYear - dayOfYear)", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let fmtRow = makeSettingRow(label: "Format String", y: y, inset: inset, width: cardW)
        let fmtField = NSTextField(frame: NSRect(x: inset, y: y - 50, width: cardW, height: 24))
        fmtField.stringValue = w.config.format
        fmtField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fmtField.textColor = Theme.textPrimary
        fmtField.backgroundColor = Theme.inputBg
        fmtField.isBordered = false; fmtField.isBezeled = true; fmtField.bezelStyle = .roundedBezel
        fmtField.focusRingType = .none
        fmtField.target = self; fmtField.action = #selector(configTextChanged(_:))
        fmtField.identifier = NSUserInterfaceItemIdentifier("cfg:custom-date:format:\(instance.id.uuidString)")
        panel.addSubview(fmtRow); panel.addSubview(fmtField)
        y -= 60

        let progRow = makeSettingRow(label: "Show Day Progress", y: y, inset: inset, width: cardW)
        let progToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        progToggle.state = w.config.showDayProgress ? .on : .off
        progToggle.target = self; progToggle.action = #selector(configToggleChanged(_:))
        progToggle.identifier = NSUserInterfaceItemIdentifier("cfg:custom-date:showDayProgress:\(instance.id.uuidString)")
        panel.addSubview(progRow); panel.addSubview(progToggle)
    }

    // MARK: - Daily Goal Config Panel

    private func buildGoalConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: DailyGoalWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let pct = w.config.target > 0 ? min(Double(w.current) / Double(w.config.target) * 100, 100) : 0
        let remaining = max(w.config.target - w.current, 0)
        let goalColor: NSColor = pct >= 100 ? Theme.green : (pct >= 50 ? Theme.brandAmber : Theme.textMuted)
        makeStatusCard(lines: [
            ("Progress", "\(w.current) / \(w.config.target) \(w.config.unit)", goalColor),
            ("Percentage", String(format: "%.0f%%", pct), goalColor),
            ("Remaining", "\(remaining) \(w.config.unit)", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: goalColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let nameRow = makeSettingRow(label: "Goal Name", y: y, inset: inset, width: cardW)
        let nameField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        nameField.stringValue = w.config.goalName
        nameField.font = NSFont.systemFont(ofSize: 12)
        nameField.textColor = Theme.textPrimary
        nameField.backgroundColor = Theme.inputBg
        nameField.isBordered = false; nameField.isBezeled = true; nameField.bezelStyle = .roundedBezel
        nameField.focusRingType = .none
        nameField.target = self; nameField.action = #selector(configTextChanged(_:))
        nameField.identifier = NSUserInterfaceItemIdentifier("cfg:daily-goal:goalName:\(instance.id.uuidString)")
        panel.addSubview(nameRow); panel.addSubview(nameField)
        y -= 36

        let targetRow = makeSettingRow(label: "Target", y: y, inset: inset, width: cardW)
        let targetField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        targetField.stringValue = "\(w.config.target)"
        targetField.font = NSFont.systemFont(ofSize: 12)
        targetField.textColor = Theme.textPrimary
        targetField.backgroundColor = Theme.inputBg
        targetField.isBordered = false; targetField.isBezeled = true; targetField.bezelStyle = .roundedBezel
        targetField.focusRingType = .none
        targetField.target = self; targetField.action = #selector(configTextChanged(_:))
        targetField.identifier = NSUserInterfaceItemIdentifier("cfg:daily-goal:target:\(instance.id.uuidString)")
        panel.addSubview(targetRow); panel.addSubview(targetField)
        y -= 36

        let unitRow = makeSettingRow(label: "Unit Label", y: y, inset: inset, width: cardW)
        let unitField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        unitField.stringValue = w.config.unit
        unitField.font = NSFont.systemFont(ofSize: 12)
        unitField.textColor = Theme.textPrimary
        unitField.backgroundColor = Theme.inputBg
        unitField.isBordered = false; unitField.isBezeled = true; unitField.bezelStyle = .roundedBezel
        unitField.focusRingType = .none
        unitField.target = self; unitField.action = #selector(configTextChanged(_:))
        unitField.identifier = NSUserInterfaceItemIdentifier("cfg:daily-goal:unit:\(instance.id.uuidString)")
        panel.addSubview(unitRow); panel.addSubview(unitField)
        y -= 36

        let barRow = makeSettingRow(label: "Show Progress Bar", y: y, inset: inset, width: cardW)
        let barToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        barToggle.state = w.config.showBar ? .on : .off
        barToggle.target = self; barToggle.action = #selector(configToggleChanged(_:))
        barToggle.identifier = NSUserInterfaceItemIdentifier("cfg:daily-goal:showBar:\(instance.id.uuidString)")
        panel.addSubview(barRow); panel.addSubview(barToggle)
    }

    // MARK: - Crypto Config Panel

    private func buildCryptoConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let cryptoWidget = instance.widget.underlying(as: CryptoWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Summary card
        let summaryCard = NSView(frame: NSRect(x: inset, y: y - 50, width: cardW, height: 50))
        summaryCard.wantsLayer = true
        summaryCard.layer?.backgroundColor = Theme.cardBg.cgColor
        summaryCard.layer?.cornerRadius = 10
        summaryCard.layer?.borderWidth = 1

        if !cryptoWidget.quotes.isEmpty {
            let avgChange = cryptoWidget.quotes.map(\.change).reduce(0, +) / Double(cryptoWidget.quotes.count)
            summaryCard.layer?.borderColor = Theme.borderForChange(avgChange).cgColor

            let avgLabel = NSTextField(labelWithString: String(format: "Portfolio Avg: %@%.2f%%", avgChange >= 0 ? "+" : "", avgChange))
            avgLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            avgLabel.textColor = Theme.colorForChange(avgChange)
            avgLabel.frame = NSRect(x: 14, y: 16, width: cardW - 28, height: 20)
            summaryCard.addSubview(avgLabel)

            let countLabel = NSTextField(labelWithString: "\(cryptoWidget.quotes.count) coins tracked")
            countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = Theme.textMuted
            countLabel.frame = NSRect(x: 14, y: 2, width: 200, height: 14)
            summaryCard.addSubview(countLabel)
        } else {
            summaryCard.layer?.borderColor = Theme.cardBorder.cgColor
            let loadLabel = NSTextField(labelWithString: "Loading crypto data...")
            loadLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            loadLabel.textColor = Theme.textMuted
            loadLabel.frame = NSRect(x: 14, y: 16, width: cardW - 28, height: 18)
            summaryCard.addSubview(loadLabel)
        }
        panel.addSubview(summaryCard)
        y -= 58

        // Individual coin cards
        for q in cryptoWidget.quotes {
            let coinCard = NSView(frame: NSRect(x: inset, y: y - 42, width: cardW, height: 42))
            coinCard.wantsLayer = true
            coinCard.layer?.backgroundColor = Theme.bgForChange(q.change).cgColor
            coinCard.layer?.cornerRadius = 8
            coinCard.layer?.borderWidth = 1
            coinCard.layer?.borderColor = Theme.borderForChange(q.change).cgColor

            let accentBar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 42))
            accentBar.wantsLayer = true
            accentBar.layer?.backgroundColor = Theme.colorForChange(q.change).cgColor
            accentBar.layer?.cornerRadius = 1.5
            coinCard.addSubview(accentBar)

            let symLabel = NSTextField(labelWithString: q.symbol)
            symLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            symLabel.textColor = Theme.textPrimary
            symLabel.frame = NSRect(x: 12, y: 12, width: 60, height: 18)
            coinCard.addSubview(symLabel)

            let priceStr = cryptoWidget.quotes.isEmpty ? "--" : formatCryptoPrice(q.price)
            let priceLabel = NSTextField(labelWithString: "$\(priceStr)")
            priceLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            priceLabel.textColor = Theme.textPrimary
            priceLabel.alignment = .center
            priceLabel.frame = NSRect(x: cardW / 2 - 50, y: 12, width: 100, height: 18)
            coinCard.addSubview(priceLabel)

            let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
            let changeStr = String(format: "%@ %.2f%%", arrow, abs(q.change))
            let changePill = NSView(frame: NSRect(x: cardW - 100, y: 10, width: 84, height: 22))
            changePill.wantsLayer = true
            changePill.layer?.backgroundColor = Theme.colorForChange(q.change).withAlphaComponent(0.15).cgColor
            changePill.layer?.cornerRadius = 6
            let changeLabel = NSTextField(labelWithString: changeStr)
            changeLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            changeLabel.textColor = Theme.colorForChange(q.change)
            changeLabel.alignment = .center
            changeLabel.frame = NSRect(x: 0, y: 2, width: 84, height: 16)
            changePill.addSubview(changeLabel)
            coinCard.addSubview(changePill)

            // Remove coin button
            let removeBtn = HoverButton(frame: NSRect(x: cardW - 24, y: 28, width: 14, height: 14))
            removeBtn.wantsLayer = true
            removeBtn.bezelStyle = .inline
            removeBtn.isBordered = false
            removeBtn.title = "x"
            removeBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            removeBtn.contentTintColor = Theme.textMuted.withAlphaComponent(0.5)
            removeBtn.layer?.cornerRadius = 7
            removeBtn.normalBg = .clear
            removeBtn.hoverBg = Theme.redBg
            removeBtn.identifier = NSUserInterfaceItemIdentifier("remove-coin:\(q.coin):\(instance.id.uuidString)")
            removeBtn.target = self
            removeBtn.action = #selector(removeCryptoAction(_:))
            coinCard.addSubview(removeBtn)

            panel.addSubview(coinCard)
            y -= 52
        }

        if cryptoWidget.quotes.isEmpty {
            for coin in cryptoWidget.config.coins {
                let sym = CryptoWidget.coinSymbols[coin] ?? String(coin.prefix(4)).uppercased()
                let placeholder = NSView(frame: NSRect(x: inset, y: y - 42, width: cardW, height: 42))
                placeholder.wantsLayer = true
                placeholder.layer?.backgroundColor = Theme.cardBg.cgColor
                placeholder.layer?.cornerRadius = 8
                placeholder.layer?.borderWidth = 1
                placeholder.layer?.borderColor = Theme.cardBorder.cgColor
                let label = NSTextField(labelWithString: "\(sym) - Loading...")
                label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                label.textColor = Theme.textMuted
                label.frame = NSRect(x: 12, y: 12, width: cardW - 24, height: 18)
                placeholder.addSubview(label)
                panel.addSubview(placeholder)
                y -= 52
            }
        }

        y -= 4

        // Add coin input
        let addRow = NSView(frame: NSRect(x: inset, y: y - 36, width: cardW, height: 36))
        addRow.wantsLayer = true

        let addField = NSTextField(frame: NSRect(x: 0, y: 4, width: cardW - 70, height: 28))
        addField.placeholderString = "Add coin (e.g. solana)"
        addField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        addField.textColor = Theme.textPrimary
        addField.backgroundColor = Theme.inputBg
        addField.isBordered = false; addField.isBezeled = true; addField.bezelStyle = .roundedBezel
        addField.focusRingType = .none
        addField.identifier = NSUserInterfaceItemIdentifier("addCoinField:\(instance.id.uuidString)")
        addField.target = self; addField.action = #selector(cryptoAddCoin(_:))
        addRow.addSubview(addField)

        let addBtn = HoverButton(frame: NSRect(x: cardW - 60, y: 4, width: 60, height: 28))
        addBtn.wantsLayer = true
        addBtn.bezelStyle = .inline
        addBtn.isBordered = false
        addBtn.title = "+ Add"
        addBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        addBtn.contentTintColor = Theme.accent
        addBtn.layer?.backgroundColor = Theme.accentBg.cgColor
        addBtn.layer?.cornerRadius = 8
        addBtn.normalBg = Theme.accentBg
        addBtn.hoverBg = NSColor(red: 0.38, green: 0.50, blue: 1.0, alpha: 0.20)
        addBtn.identifier = NSUserInterfaceItemIdentifier("addCoinBtn:\(instance.id.uuidString)")
        addBtn.target = self; addBtn.action = #selector(cryptoAddCoinFromButton(_:))
        addRow.addSubview(addBtn)

        panel.addSubview(addRow)
        y -= 44

        // Settings section
        y -= 8
        let settingsLabel = NSTextField(labelWithString: "")
        let settingsAttr = NSMutableAttributedString(string: "SETTINGS")
        settingsAttr.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: 8))
        settingsAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .bold), range: NSRange(location: 0, length: 8))
        settingsAttr.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: 8))
        settingsLabel.attributedStringValue = settingsAttr
        settingsLabel.frame = NSRect(x: inset, y: y - 14, width: 100, height: 14)
        panel.addSubview(settingsLabel)
        y -= 24

        // Scroll Speed
        let speedRow = makeSettingRow(label: "Scroll Speed", y: y, inset: inset, width: cardW)
        let speedSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        speedSlider.minValue = 0.1; speedSlider.maxValue = 2.0
        speedSlider.doubleValue = cryptoWidget.config.scrollSpeed
        speedSlider.target = self; speedSlider.action = #selector(cryptoSpeedChanged(_:))
        speedSlider.identifier = NSUserInterfaceItemIdentifier("cryptoSpeed:\(instance.id.uuidString)")
        panel.addSubview(speedRow); panel.addSubview(speedSlider)
        y -= 36

        // Colored Ticker
        let colorRow = makeSettingRow(label: "Colored Ticker", y: y, inset: inset, width: cardW)
        let colorToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        colorToggle.state = cryptoWidget.config.coloredTicker ? .on : .off
        colorToggle.target = self; colorToggle.action = #selector(configToggleChanged(_:))
        colorToggle.identifier = NSUserInterfaceItemIdentifier("cfg:crypto:coloredTicker:\(instance.id.uuidString)")
        panel.addSubview(colorRow); panel.addSubview(colorToggle)
        y -= 36

        // Show Change %
        let changeRow = makeSettingRow(label: "Show Change %", y: y, inset: inset, width: cardW)
        let changeToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        changeToggle.state = cryptoWidget.config.showChange ? .on : .off
        changeToggle.target = self; changeToggle.action = #selector(configToggleChanged(_:))
        changeToggle.identifier = NSUserInterfaceItemIdentifier("cfg:crypto:showChange:\(instance.id.uuidString)")
        panel.addSubview(changeRow); panel.addSubview(changeToggle)
        y -= 36

        // Currency
        let currRow = makeSettingRow(label: "Currency", y: y, inset: inset, width: cardW)
        let currPopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        currPopup.addItems(withTitles: ["USD ($)", "EUR (\u{20AC})", "GBP (\u{00A3})", "JPY (\u{00A5})"])
        let currencies = ["usd", "eur", "gbp", "jpy"]
        if let currIdx = currencies.firstIndex(of: cryptoWidget.config.currency) { currPopup.selectItem(at: currIdx) }
        currPopup.target = self; currPopup.action = #selector(configPopupChanged(_:))
        currPopup.identifier = NSUserInterfaceItemIdentifier("cfg:crypto:currency:\(instance.id.uuidString)")
        panel.addSubview(currRow); panel.addSubview(currPopup)
        y -= 36

        // Ticker Width
        let widthRow = makeSettingRow(label: "Ticker Width", y: y, inset: inset, width: cardW)
        let widthSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        widthSlider.minValue = 80; widthSlider.maxValue = 400
        widthSlider.doubleValue = cryptoWidget.config.tickerWidth
        widthSlider.target = self; widthSlider.action = #selector(cryptoWidthChanged(_:))
        widthSlider.identifier = NSUserInterfaceItemIdentifier("cryptoWidth:\(instance.id.uuidString)")
        panel.addSubview(widthRow); panel.addSubview(widthSlider)
        y -= 36

        // Refresh Interval
        let refreshRow = makeSettingRow(label: "Refresh Interval", y: y, inset: inset, width: cardW)
        let refreshPopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        refreshPopup.addItems(withTitles: ["30 sec", "1 min", "2 min", "5 min"])
        let intervals: [TimeInterval] = [30, 60, 120, 300]
        if let idx = intervals.firstIndex(of: cryptoWidget.config.refreshInterval) { refreshPopup.selectItem(at: idx) }
        else { refreshPopup.selectItem(at: 1) }
        refreshPopup.target = self; refreshPopup.action = #selector(cryptoRefreshChanged(_:))
        refreshPopup.identifier = NSUserInterfaceItemIdentifier("cryptoRefresh:\(instance.id.uuidString)")
        panel.addSubview(refreshRow); panel.addSubview(refreshPopup)
    }

    private func formatCryptoPrice(_ price: Double) -> String {
        if price >= 1000 { return String(format: "%.0f", price) }
        if price >= 1 { return String(format: "%.2f", price) }
        return String(format: "%.4f", price)
    }

    // MARK: - Market Status Config Panel

    private func buildMarketStatusConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: MarketStatusWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card - show market state
        let rendered = w.render()
        let barText: String
        switch rendered {
        case .text(let t): barText = t
        case .attributedText(let a): barText = a.string
        default: barText = "Market Status"
        }
        let isOpen = barText.contains("Open")
        let statusColor: NSColor = isOpen ? Theme.green : Theme.red
        makeStatusCard(lines: [
            ("Status", barText, statusColor),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: statusColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let countdownRow = makeSettingRow(label: "Show Countdown", y: y, inset: inset, width: cardW)
        let countdownToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        countdownToggle.state = w.config.showCountdown ? .on : .off
        countdownToggle.target = self; countdownToggle.action = #selector(configToggleChanged(_:))
        countdownToggle.identifier = NSUserInterfaceItemIdentifier("cfg:market-status:showCountdown:\(instance.id.uuidString)")
        panel.addSubview(countdownRow); panel.addSubview(countdownToggle)
        y -= 36

        let dotRow = makeSettingRow(label: "Show Status Dot", y: y, inset: inset, width: cardW)
        let dotToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        dotToggle.state = w.config.showDot ? .on : .off
        dotToggle.target = self; dotToggle.action = #selector(configToggleChanged(_:))
        dotToggle.identifier = NSUserInterfaceItemIdentifier("cfg:market-status:showDot:\(instance.id.uuidString)")
        panel.addSubview(dotRow); panel.addSubview(dotToggle)
    }

    // MARK: - Calendar Next Config Panel

    private func buildCalendarNextConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: CalendarNextWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        var lines: [(String, String, NSColor?)] = []
        if !w.hasAccess {
            lines.append(("Access", "Not Granted", Theme.red))
        } else if let current = w.currentEvent {
            let minsLeft = Int(current.endDate.timeIntervalSince(Date()) / 60)
            lines.append(("Now", current.title ?? "Meeting", Theme.red))
            lines.append(("Ends In", "\(minsLeft)m", nil))
        } else if let next = w.nextEvent {
            let minsUntil = Int(next.startDate.timeIntervalSince(Date()) / 60)
            let timeStr = minsUntil < 60 ? "\(minsUntil)m" : "\(minsUntil/60)h \(minsUntil%60)m"
            lines.append(("Next", next.title ?? "Meeting", nil))
            lines.append(("In", timeStr, minsUntil <= w.config.minuteWarning ? Theme.brandAmber : nil))
        } else {
            lines.append(("Status", "No more meetings", Theme.green))
        }
        let upcoming = w.todayEvents.filter { !$0.isAllDay && $0.startDate > Date() }.count
        lines.append(("Remaining Today", "\(upcoming)", nil))
        let calColor: NSColor = w.currentEvent != nil ? Theme.red : (w.nextEvent != nil ? Theme.accent : Theme.green)
        makeStatusCard(lines: lines, y: &y, inset: inset, width: cardW, panel: panel, accentColor: calColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let timeRow = makeSettingRow(label: "Show Time Until", y: y, inset: inset, width: cardW)
        let timeToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        timeToggle.state = w.config.showTimeUntil ? .on : .off
        timeToggle.target = self; timeToggle.action = #selector(configToggleChanged(_:))
        timeToggle.identifier = NSUserInterfaceItemIdentifier("cfg:calendar-next:showTimeUntil:\(instance.id.uuidString)")
        panel.addSubview(timeRow); panel.addSubview(timeToggle)
        y -= 36

        let warnRow = makeSettingRow(label: "Urgent Warning (min)", y: y, inset: inset, width: cardW)
        let warnSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        warnSlider.minValue = 1; warnSlider.maxValue = 30
        warnSlider.integerValue = w.config.minuteWarning
        warnSlider.target = self; warnSlider.action = #selector(configSliderChanged(_:))
        warnSlider.identifier = NSUserInterfaceItemIdentifier("cfg:calendar-next:minuteWarning:\(instance.id.uuidString)")
        panel.addSubview(warnRow); panel.addSubview(warnSlider)
        y -= 36

        let allDayRow = makeSettingRow(label: "Show All-Day Events", y: y, inset: inset, width: cardW)
        let allDayToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        allDayToggle.state = w.config.showAllDay ? .on : .off
        allDayToggle.target = self; allDayToggle.action = #selector(configToggleChanged(_:))
        allDayToggle.identifier = NSUserInterfaceItemIdentifier("cfg:calendar-next:showAllDay:\(instance.id.uuidString)")
        panel.addSubview(allDayRow); panel.addSubview(allDayToggle)
    }

    // MARK: - Inbox Count Config Panel

    private func buildInboxCountConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: InboxCountWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let inboxColor: NSColor = w.unreadCount > 10 ? Theme.red : (w.unreadCount > 0 ? Theme.brandAmber : Theme.green)
        let statusText = !w.mailRunning ? "Mail not running" : (w.unreadCount == 0 ? "Inbox Zero!" : "\(w.unreadCount) unread")
        makeStatusCard(lines: [
            ("Inbox", statusText, inboxColor),
            ("Mail.app", w.mailRunning ? "Running" : "Not Running", w.mailRunning ? Theme.green : Theme.textMuted),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: inboxColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let hideRow = makeSettingRow(label: "Hide When Zero", y: y, inset: inset, width: cardW)
        let hideToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        hideToggle.state = w.config.hideWhenZero ? .on : .off
        hideToggle.target = self; hideToggle.action = #selector(configToggleChanged(_:))
        hideToggle.identifier = NSUserInterfaceItemIdentifier("cfg:inbox-count:hideWhenZero:\(instance.id.uuidString)")
        panel.addSubview(hideRow); panel.addSubview(hideToggle)
    }

    // MARK: - Screen Time Config Panel

    private func buildScreenTimeConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: ScreenTimeWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let h = w.totalActiveMinutes / 60
        let m = w.totalActiveMinutes % 60
        let uptime = ProcessInfo.processInfo.systemUptime
        let uptimeH = Int(uptime / 3600)
        let uptimeM = Int(uptime.truncatingRemainder(dividingBy: 3600) / 60)
        let screenColor: NSColor = h >= 8 ? Theme.red : (h >= 4 ? Theme.brandAmber : Theme.green)
        makeStatusCard(lines: [
            ("Active Today", "\(h)h \(m)m", screenColor),
            ("System Uptime", "\(uptimeH)h \(uptimeM)m", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: screenColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let labelRow = makeSettingRow(label: "Show Label", y: y, inset: inset, width: cardW)
        let labelToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        labelToggle.state = w.config.showLabel ? .on : .off
        labelToggle.target = self; labelToggle.action = #selector(configToggleChanged(_:))
        labelToggle.identifier = NSUserInterfaceItemIdentifier("cfg:screen-time:showLabel:\(instance.id.uuidString)")
        panel.addSubview(labelRow); panel.addSubview(labelToggle)
    }

    // MARK: - Reminders Config Panel

    private func buildRemindersConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: RemindersWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let remColor: NSColor = !w.hasAccess ? Theme.red : (w.pendingCount == 0 ? Theme.green : Theme.brandAmber)
        var lines: [(String, String, NSColor?)] = []
        if !w.hasAccess {
            lines.append(("Access", "Not Granted", Theme.red))
        } else {
            lines.append(("Pending", "\(w.pendingCount) reminders", remColor))
            if !w.nextReminder.isEmpty {
                let nextPreview = w.nextReminder.count > 30 ? String(w.nextReminder.prefix(27)) + "..." : w.nextReminder
                lines.append(("Next", nextPreview, nil))
            }
        }
        makeStatusCard(lines: lines, y: &y, inset: inset, width: cardW, panel: panel, accentColor: remColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let countRow = makeSettingRow(label: "Show Count", y: y, inset: inset, width: cardW)
        let countToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        countToggle.state = w.config.showCount ? .on : .off
        countToggle.target = self; countToggle.action = #selector(configToggleChanged(_:))
        countToggle.identifier = NSUserInterfaceItemIdentifier("cfg:reminders:showCount:\(instance.id.uuidString)")
        panel.addSubview(countRow); panel.addSubview(countToggle)
        y -= 36

        let titleRow = makeSettingRow(label: "Show Next Title", y: y, inset: inset, width: cardW)
        let titleToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        titleToggle.state = w.config.showNextTitle ? .on : .off
        titleToggle.target = self; titleToggle.action = #selector(configToggleChanged(_:))
        titleToggle.identifier = NSUserInterfaceItemIdentifier("cfg:reminders:showNextTitle:\(instance.id.uuidString)")
        panel.addSubview(titleRow); panel.addSubview(titleToggle)
    }

    // MARK: - Now Playing Config Panel

    private func buildNowPlayingConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: NowPlayingWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let playColor: NSColor = w.isPlaying ? Theme.green : Theme.textMuted
        if w.trackName.isEmpty {
            makeStatusCard(lines: [
                ("Status", "Nothing playing", Theme.textMuted),
            ], y: &y, inset: inset, width: cardW, panel: panel)
        } else {
            let trackPreview = w.trackName.count > 30 ? String(w.trackName.prefix(27)) + "..." : w.trackName
            makeStatusCard(lines: [
                ("Track", trackPreview, nil),
                ("Artist", w.artistName.isEmpty ? "--" : w.artistName, nil),
                ("Status", w.isPlaying ? "Playing" : "Paused", playColor),
                ("Player", w.playerApp.isEmpty ? "--" : w.playerApp, nil),
            ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: playColor)
        }

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let playerRow = makeSettingRow(label: "Preferred Player", y: y, inset: inset, width: cardW)
        let playerPopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        playerPopup.addItems(withTitles: ["System (Any)", "Spotify", "Apple Music"])
        let players = ["system", "spotify", "music"]
        if let idx = players.firstIndex(of: w.config.preferredPlayer) { playerPopup.selectItem(at: idx) }
        playerPopup.target = self; playerPopup.action = #selector(configPopupChanged(_:))
        playerPopup.identifier = NSUserInterfaceItemIdentifier("cfg:now-playing:preferredPlayer:\(instance.id.uuidString)")
        panel.addSubview(playerRow); panel.addSubview(playerPopup)
        y -= 36

        let artistRow = makeSettingRow(label: "Show Artist", y: y, inset: inset, width: cardW)
        let artistToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        artistToggle.state = w.config.showArtist ? .on : .off
        artistToggle.target = self; artistToggle.action = #selector(configToggleChanged(_:))
        artistToggle.identifier = NSUserInterfaceItemIdentifier("cfg:now-playing:showArtist:\(instance.id.uuidString)")
        panel.addSubview(artistRow); panel.addSubview(artistToggle)
        y -= 36

        let scrollRow = makeSettingRow(label: "Scroll Long Text", y: y, inset: inset, width: cardW)
        let scrollToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        scrollToggle.state = w.config.scrollLongText ? .on : .off
        scrollToggle.target = self; scrollToggle.action = #selector(configToggleChanged(_:))
        scrollToggle.identifier = NSUserInterfaceItemIdentifier("cfg:now-playing:scrollLongText:\(instance.id.uuidString)")
        panel.addSubview(scrollRow); panel.addSubview(scrollToggle)
        y -= 36

        let widthRow = makeSettingRow(label: "Max Width", y: y, inset: inset, width: cardW)
        let widthSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        widthSlider.minValue = 100; widthSlider.maxValue = 400
        widthSlider.doubleValue = Double(w.config.maxWidth)
        widthSlider.target = self; widthSlider.action = #selector(configSliderChanged(_:))
        widthSlider.identifier = NSUserInterfaceItemIdentifier("cfg:now-playing:maxWidth:\(instance.id.uuidString)")
        panel.addSubview(widthRow); panel.addSubview(widthSlider)
    }

    // MARK: - Hacker News Config Panel

    private func buildHackerNewsConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: HackerNewsWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let titlePreview = w.topTitle.count > 40 ? String(w.topTitle.prefix(37)) + "..." : w.topTitle
        makeStatusCard(lines: [
            ("#1", titlePreview, nil),
            ("Score", "\(w.topScore) pts", Theme.brandAmber),
            ("Stories", "\(w.topItems.count) loaded", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: Theme.brandAmber)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let scoreRow = makeSettingRow(label: "Show Score", y: y, inset: inset, width: cardW)
        let scoreToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        scoreToggle.state = w.config.showScore ? .on : .off
        scoreToggle.target = self; scoreToggle.action = #selector(configToggleChanged(_:))
        scoreToggle.identifier = NSUserInterfaceItemIdentifier("cfg:hn-top:showScore:\(instance.id.uuidString)")
        panel.addSubview(scoreRow); panel.addSubview(scoreToggle)
        y -= 36

        let scrollRow = makeSettingRow(label: "Scroll Title", y: y, inset: inset, width: cardW)
        let scrollToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        scrollToggle.state = w.config.scrollTitle ? .on : .off
        scrollToggle.target = self; scrollToggle.action = #selector(configToggleChanged(_:))
        scrollToggle.identifier = NSUserInterfaceItemIdentifier("cfg:hn-top:scrollTitle:\(instance.id.uuidString)")
        panel.addSubview(scrollRow); panel.addSubview(scrollToggle)
    }

    // MARK: - Live Scores Config Panel

    private func buildLiveScoresConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: LiveScoresWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let liveCount = w.games.filter { $0.isLive }.count
        let totalGames = w.games.count
        let scoresColor: NSColor = liveCount > 0 ? Theme.green : Theme.textMuted
        var lines: [(String, String, NSColor?)] = [
            ("League", w.config.league.uppercased(), nil),
            ("Games", "\(totalGames) today", nil),
            ("Live", liveCount > 0 ? "\(liveCount) in progress" : "None", scoresColor),
        ]
        if let current = w.games.indices.contains(w.displayIndex) ? w.games[w.displayIndex] : nil {
            lines.append(("Current", "\(current.awayTeam) \(current.awayScore) - \(current.homeTeam) \(current.homeScore)", nil))
        }
        makeStatusCard(lines: lines, y: &y, inset: inset, width: cardW, panel: panel, accentColor: scoresColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let sportRow = makeSettingRow(label: "Sport", y: y, inset: inset, width: cardW)
        let sportPopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        sportPopup.addItems(withTitles: ["Basketball", "Football", "Baseball", "Hockey", "Soccer"])
        let sports = ["basketball", "football", "baseball", "hockey", "soccer"]
        if let idx = sports.firstIndex(of: w.config.sport) { sportPopup.selectItem(at: idx) }
        sportPopup.target = self; sportPopup.action = #selector(configPopupChanged(_:))
        sportPopup.identifier = NSUserInterfaceItemIdentifier("cfg:live-scores:sport:\(instance.id.uuidString)")
        panel.addSubview(sportRow); panel.addSubview(sportPopup)
        y -= 36

        let leagueRow = makeSettingRow(label: "League", y: y, inset: inset, width: cardW)
        let leaguePopup = NSPopUpButton(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        leaguePopup.addItems(withTitles: ["NBA", "NFL", "MLB", "NHL", "Premier League"])
        let leagues = ["nba", "nfl", "mlb", "nhl", "eng.1"]
        if let idx = leagues.firstIndex(of: w.config.league) { leaguePopup.selectItem(at: idx) }
        leaguePopup.target = self; leaguePopup.action = #selector(configPopupChanged(_:))
        leaguePopup.identifier = NSUserInterfaceItemIdentifier("cfg:live-scores:league:\(instance.id.uuidString)")
        panel.addSubview(leagueRow); panel.addSubview(leaguePopup)
    }

    // MARK: - Git Branch Config Panel

    private func buildGitBranchConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: GitBranchWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let gitColor: NSColor = !w.isRepo ? Theme.red : (w.isDirty ? Theme.brandAmber : Theme.green)
        if w.isRepo {
            var lines: [(String, String, NSColor?)] = [
                ("Branch", w.branch, nil),
                ("Status", w.isDirty ? "\(w.changedCount) changed" : "Clean", gitColor),
            ]
            if w.ahead > 0 || w.behind > 0 {
                lines.append(("Sync", "\u{2191}\(w.ahead) \u{2193}\(w.behind)", nil))
            }
            let commitPreview = w.lastCommit.count > 35 ? String(w.lastCommit.prefix(32)) + "..." : w.lastCommit
            if !commitPreview.isEmpty { lines.append(("Last", commitPreview, nil)) }
            makeStatusCard(lines: lines, y: &y, inset: inset, width: cardW, panel: panel, accentColor: gitColor)
        } else {
            makeStatusCard(lines: [("Status", "Not a git repo", Theme.red)], y: &y, inset: inset, width: cardW, panel: panel, accentColor: Theme.red)
        }

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let pathRow = makeSettingRow(label: "Repo Path", y: y, inset: inset, width: cardW)
        let pathField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        pathField.stringValue = w.config.repoPath
        pathField.font = NSFont.systemFont(ofSize: 12)
        pathField.textColor = Theme.textPrimary
        pathField.backgroundColor = Theme.inputBg
        pathField.isBordered = false; pathField.isBezeled = true; pathField.bezelStyle = .roundedBezel
        pathField.focusRingType = .none
        pathField.target = self; pathField.action = #selector(configTextChanged(_:))
        pathField.identifier = NSUserInterfaceItemIdentifier("cfg:git-branch:repoPath:\(instance.id.uuidString)")
        panel.addSubview(pathRow); panel.addSubview(pathField)
        y -= 36

        let dirtyRow = makeSettingRow(label: "Dirty Indicator", y: y, inset: inset, width: cardW)
        let dirtyToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        dirtyToggle.state = w.config.showDirtyIndicator ? .on : .off
        dirtyToggle.target = self; dirtyToggle.action = #selector(configToggleChanged(_:))
        dirtyToggle.identifier = NSUserInterfaceItemIdentifier("cfg:git-branch:showDirtyIndicator:\(instance.id.uuidString)")
        panel.addSubview(dirtyRow); panel.addSubview(dirtyToggle)
        y -= 36

        let aheadRow = makeSettingRow(label: "Ahead/Behind Count", y: y, inset: inset, width: cardW)
        let aheadToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        aheadToggle.state = w.config.showAheadBehind ? .on : .off
        aheadToggle.target = self; aheadToggle.action = #selector(configToggleChanged(_:))
        aheadToggle.identifier = NSUserInterfaceItemIdentifier("cfg:git-branch:showAheadBehind:\(instance.id.uuidString)")
        panel.addSubview(aheadRow); panel.addSubview(aheadToggle)
        y -= 36

        let truncRow = makeSettingRow(label: "Truncate Length", y: y, inset: inset, width: cardW)
        let truncSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        truncSlider.minValue = 8; truncSlider.maxValue = 40
        truncSlider.integerValue = w.config.truncateLength
        truncSlider.target = self; truncSlider.action = #selector(configSliderChanged(_:))
        truncSlider.identifier = NSUserInterfaceItemIdentifier("cfg:git-branch:truncateLength:\(instance.id.uuidString)")
        panel.addSubview(truncRow); panel.addSubview(truncSlider)
    }

    // MARK: - Forex Config Panel

    private func buildForexConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: ForexWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let rateStr = w.rate > 0 ? String(format: "%.\(w.config.decimalPlaces)f", w.rate) : "--"
        let inverseStr = w.rate > 0 ? String(format: "%.\(w.config.decimalPlaces)f", 1.0 / w.rate) : "--"
        makeStatusCard(lines: [
            ("Pair", "\(w.config.baseCurrency) / \(w.config.targetCurrency)", nil),
            ("Rate", rateStr, Theme.accent),
            ("Inverse", inverseStr, nil),
            ("Updated", w.lastUpdated.isEmpty ? "--" : w.lastUpdated, nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: Theme.accent)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let baseRow = makeSettingRow(label: "Base Currency", y: y, inset: inset, width: cardW)
        let baseField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        baseField.stringValue = w.config.baseCurrency
        baseField.placeholderString = "USD"
        baseField.font = NSFont.systemFont(ofSize: 12)
        baseField.textColor = Theme.textPrimary
        baseField.backgroundColor = Theme.inputBg
        baseField.isBordered = false; baseField.isBezeled = true; baseField.bezelStyle = .roundedBezel
        baseField.focusRingType = .none
        baseField.target = self; baseField.action = #selector(configTextChanged(_:))
        baseField.identifier = NSUserInterfaceItemIdentifier("cfg:forex-rate:baseCurrency:\(instance.id.uuidString)")
        panel.addSubview(baseRow); panel.addSubview(baseField)
        y -= 36

        let targetRow = makeSettingRow(label: "Target Currency", y: y, inset: inset, width: cardW)
        let targetField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        targetField.stringValue = w.config.targetCurrency
        targetField.placeholderString = "EUR"
        targetField.font = NSFont.systemFont(ofSize: 12)
        targetField.textColor = Theme.textPrimary
        targetField.backgroundColor = Theme.inputBg
        targetField.isBordered = false; targetField.isBezeled = true; targetField.bezelStyle = .roundedBezel
        targetField.focusRingType = .none
        targetField.target = self; targetField.action = #selector(configTextChanged(_:))
        targetField.identifier = NSUserInterfaceItemIdentifier("cfg:forex-rate:targetCurrency:\(instance.id.uuidString)")
        panel.addSubview(targetRow); panel.addSubview(targetField)
        y -= 36

        let decRow = makeSettingRow(label: "Decimal Places", y: y, inset: inset, width: cardW)
        let decSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        decSlider.minValue = 1; decSlider.maxValue = 6
        decSlider.integerValue = w.config.decimalPlaces
        decSlider.target = self; decSlider.action = #selector(configSliderChanged(_:))
        decSlider.identifier = NSUserInterfaceItemIdentifier("cfg:forex-rate:decimalPlaces:\(instance.id.uuidString)")
        panel.addSubview(decRow); panel.addSubview(decSlider)
    }

    // MARK: - Disk Space Config Panel

    private func buildDiskSpaceConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: DiskSpaceWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let diskColor: NSColor = w.freeGB < Double(w.config.warnBelowGB) ? Theme.red : Theme.green
        makeStatusCard(lines: [
            ("Total", String(format: "%.0f GB", w.totalGB), nil),
            ("Free", String(format: "%.1f GB", w.freeGB), diskColor),
            ("Used", String(format: "%.1f GB (%.0f%%)", w.totalGB - w.freeGB, w.usedPercent), nil),
        ], y: &y, inset: inset, width: cardW, panel: panel, accentColor: diskColor)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let pctRow = makeSettingRow(label: "Show Percentage", y: y, inset: inset, width: cardW)
        let pctToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        pctToggle.state = w.config.showPercentage ? .on : .off
        pctToggle.target = self; pctToggle.action = #selector(configToggleChanged(_:))
        pctToggle.identifier = NSUserInterfaceItemIdentifier("cfg:disk-space:showPercentage:\(instance.id.uuidString)")
        panel.addSubview(pctRow); panel.addSubview(pctToggle)
        y -= 36

        let warnRow = makeSettingRow(label: "Warn Below (GB)", y: y, inset: inset, width: cardW)
        let warnSlider = NSSlider(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 20, width: cardW / 2 - 10, height: 20))
        warnSlider.minValue = 5; warnSlider.maxValue = 100
        warnSlider.integerValue = w.config.warnBelowGB
        warnSlider.target = self; warnSlider.action = #selector(configSliderChanged(_:))
        warnSlider.identifier = NSUserInterfaceItemIdentifier("cfg:disk-space:warnBelowGB:\(instance.id.uuidString)")
        panel.addSubview(warnRow); panel.addSubview(warnSlider)
    }

    // MARK: - IP Address Config Panel

    private func buildIPAddressConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: IPAddressWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        makeStatusCard(lines: [
            ("Public IP", w.publicIP, nil),
            ("Local IP", w.localIP, nil),
        ], y: &y, inset: inset, width: cardW, panel: panel)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let pubRow = makeSettingRow(label: "Show Public IP", y: y, inset: inset, width: cardW)
        let pubToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        pubToggle.state = w.config.showPublic ? .on : .off
        pubToggle.target = self; pubToggle.action = #selector(configToggleChanged(_:))
        pubToggle.identifier = NSUserInterfaceItemIdentifier("cfg:ip-address:showPublic:\(instance.id.uuidString)")
        panel.addSubview(pubRow); panel.addSubview(pubToggle)
        y -= 36

        let localRow = makeSettingRow(label: "Show Local IP", y: y, inset: inset, width: cardW)
        let localToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        localToggle.state = w.config.showLocal ? .on : .off
        localToggle.target = self; localToggle.action = #selector(configToggleChanged(_:))
        localToggle.identifier = NSUserInterfaceItemIdentifier("cfg:ip-address:showLocal:\(instance.id.uuidString)")
        panel.addSubview(localRow); panel.addSubview(localToggle)
    }

    // MARK: - Sunrise/Sunset Config Panel

    private func buildSunriseSunsetConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: SunriseSunsetWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let dlH = w.dayLengthMinutes / 60
        let dlM = w.dayLengthMinutes % 60
        makeStatusCard(lines: [
            ("Sunrise", w.sunriseTime, Theme.brandAmber),
            ("Sunset", w.sunsetTime, Theme.red),
            ("Day Length", "\(dlH)h \(dlM)m", nil),
        ], y: &y, inset: inset, width: cardW, panel: panel)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let latRow = makeSettingRow(label: "Latitude", y: y, inset: inset, width: cardW)
        let latField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        latField.stringValue = String(w.config.latitude)
        latField.placeholderString = "40.7128"
        latField.font = NSFont.systemFont(ofSize: 12)
        latField.textColor = Theme.textPrimary
        latField.backgroundColor = Theme.inputBg
        latField.isBordered = false; latField.isBezeled = true; latField.bezelStyle = .roundedBezel
        latField.focusRingType = .none
        latField.target = self; latField.action = #selector(configTextChanged(_:))
        latField.identifier = NSUserInterfaceItemIdentifier("cfg:sunrise-sunset:latitude:\(instance.id.uuidString)")
        panel.addSubview(latRow); panel.addSubview(latField)
        y -= 36

        let lngRow = makeSettingRow(label: "Longitude", y: y, inset: inset, width: cardW)
        let lngField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        lngField.stringValue = String(w.config.longitude)
        lngField.placeholderString = "-74.0060"
        lngField.font = NSFont.systemFont(ofSize: 12)
        lngField.textColor = Theme.textPrimary
        lngField.backgroundColor = Theme.inputBg
        lngField.isBordered = false; lngField.isBezeled = true; lngField.bezelStyle = .roundedBezel
        lngField.focusRingType = .none
        lngField.target = self; lngField.action = #selector(configTextChanged(_:))
        lngField.identifier = NSUserInterfaceItemIdentifier("cfg:sunrise-sunset:longitude:\(instance.id.uuidString)")
        panel.addSubview(lngRow); panel.addSubview(lngField)
        y -= 36

        let dayRow = makeSettingRow(label: "Show Day Length", y: y, inset: inset, width: cardW)
        let dayToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        dayToggle.state = w.config.showDayLength ? .on : .off
        dayToggle.target = self; dayToggle.action = #selector(configToggleChanged(_:))
        dayToggle.identifier = NSUserInterfaceItemIdentifier("cfg:sunrise-sunset:showDayLength:\(instance.id.uuidString)")
        panel.addSubview(dayRow); panel.addSubview(dayToggle)
    }

    // MARK: - Time Zone Diff Config Panel

    private func buildTimeZoneDiffConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: TimeZoneDiffWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        if let tz = TimeZone(identifier: w.config.targetTimeZone) {
            let now = Date()
            let localOffset = TimeZone.current.secondsFromGMT(for: now)
            let targetOffset = tz.secondsFromGMT(for: now)
            let diffH = (targetOffset - localOffset) / 3600
            let sign = diffH >= 0 ? "+" : ""
            let formatter = DateFormatter()
            formatter.timeZone = tz
            formatter.dateFormat = "h:mm a"
            let timeStr = formatter.string(from: now)
            formatter.dateFormat = "EEE, MMM d"
            let dateStr = formatter.string(from: now)
            makeStatusCard(lines: [
                (w.config.label, timeStr, nil),
                ("Date", dateStr, nil),
                ("Offset", "\(sign)\(diffH)h from you", nil),
            ], y: &y, inset: inset, width: cardW, panel: panel)
        } else {
            makeStatusCard(lines: [("Status", "Invalid timezone", Theme.red)], y: &y, inset: inset, width: cardW, panel: panel, accentColor: Theme.red)
        }

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        let tzRow = makeSettingRow(label: "Time Zone ID", y: y, inset: inset, width: cardW)
        let tzField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        tzField.stringValue = w.config.targetTimeZone
        tzField.placeholderString = "Asia/Tokyo"
        tzField.font = NSFont.systemFont(ofSize: 12)
        tzField.textColor = Theme.textPrimary
        tzField.backgroundColor = Theme.inputBg
        tzField.isBordered = false; tzField.isBezeled = true; tzField.bezelStyle = .roundedBezel
        tzField.focusRingType = .none
        tzField.target = self; tzField.action = #selector(configTextChanged(_:))
        tzField.identifier = NSUserInterfaceItemIdentifier("cfg:tz-diff:targetTimeZone:\(instance.id.uuidString)")
        panel.addSubview(tzRow); panel.addSubview(tzField)
        y -= 36

        let labelRow = makeSettingRow(label: "Display Label", y: y, inset: inset, width: cardW)
        let labelField = NSTextField(frame: NSRect(x: cardW / 2 + inset - 10, y: y - 22, width: cardW / 2 - 10, height: 24))
        labelField.stringValue = w.config.label
        labelField.placeholderString = "Tokyo"
        labelField.font = NSFont.systemFont(ofSize: 12)
        labelField.textColor = Theme.textPrimary
        labelField.backgroundColor = Theme.inputBg
        labelField.isBordered = false; labelField.isBezeled = true; labelField.bezelStyle = .roundedBezel
        labelField.focusRingType = .none
        labelField.target = self; labelField.action = #selector(configTextChanged(_:))
        labelField.identifier = NSUserInterfaceItemIdentifier("cfg:tz-diff:label:\(instance.id.uuidString)")
        panel.addSubview(labelRow); panel.addSubview(labelField)
        y -= 36

        let hourRow = makeSettingRow(label: "Use 24-Hour", y: y, inset: inset, width: cardW)
        let hourToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        hourToggle.state = w.config.use24Hour ? .on : .off
        hourToggle.target = self; hourToggle.action = #selector(configToggleChanged(_:))
        hourToggle.identifier = NSUserInterfaceItemIdentifier("cfg:tz-diff:use24Hour:\(instance.id.uuidString)")
        panel.addSubview(hourRow); panel.addSubview(hourToggle)
    }

    // MARK: - World Clock Config Panel

    private func buildWorldClockConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        guard let w = instance.widget.underlying(as: WorldClockWidget.self) else { return }
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        // Status card
        let now = Date()
        var clockLines: [(String, String, NSColor?)] = []
        for (i, tzID) in w.config.timezoneIDs.enumerated() {
            guard let tz = TimeZone(identifier: tzID) else { continue }
            let label = i < w.config.labels.count ? w.config.labels[i] : String(tzID.split(separator: "/").last ?? "")
            let formatter = DateFormatter()
            formatter.timeZone = tz
            formatter.dateFormat = "h:mm a"
            clockLines.append((label, formatter.string(from: now), nil))
        }
        if clockLines.isEmpty { clockLines.append(("Status", "No zones configured", Theme.textMuted)) }
        makeStatusCard(lines: clockLines, y: &y, inset: inset, width: cardW, panel: panel)

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        // Timezone editing (up to 3 slots)
        let placeholders = ["America/New_York", "Europe/London", "Asia/Tokyo"]
        let labelPlaceholders = ["NYC", "LON", "TYO"]
        for i in 0..<3 {
            let tzID = i < w.config.timezoneIDs.count ? w.config.timezoneIDs[i] : ""
            let lbl = i < w.config.labels.count ? w.config.labels[i] : ""

            let slotRow = makeSettingRow(label: "Zone \(i + 1)", y: y, inset: inset, width: cardW)
            panel.addSubview(slotRow)

            let tzField = NSTextField(frame: NSRect(x: inset + 60, y: y - 22, width: cardW - 140, height: 24))
            tzField.stringValue = tzID
            tzField.placeholderString = i < placeholders.count ? placeholders[i] : "Timezone ID"
            tzField.font = NSFont.systemFont(ofSize: 11)
            tzField.textColor = Theme.textPrimary
            tzField.backgroundColor = Theme.inputBg
            tzField.isBordered = false; tzField.isBezeled = true; tzField.bezelStyle = .roundedBezel
            tzField.focusRingType = .none
            tzField.target = self; tzField.action = #selector(configTextChanged(_:))
            tzField.identifier = NSUserInterfaceItemIdentifier("cfg:world-clock:tz\(i):\(instance.id.uuidString)")
            panel.addSubview(tzField)

            let lblField = NSTextField(frame: NSRect(x: cardW - 60, y: y - 22, width: 60, height: 24))
            lblField.stringValue = lbl
            lblField.placeholderString = i < labelPlaceholders.count ? labelPlaceholders[i] : "Label"
            lblField.font = NSFont.systemFont(ofSize: 11)
            lblField.textColor = Theme.textPrimary
            lblField.backgroundColor = Theme.inputBg
            lblField.isBordered = false; lblField.isBezeled = true; lblField.bezelStyle = .roundedBezel
            lblField.focusRingType = .none
            lblField.target = self; lblField.action = #selector(configTextChanged(_:))
            lblField.identifier = NSUserInterfaceItemIdentifier("cfg:world-clock:lbl\(i):\(instance.id.uuidString)")
            panel.addSubview(lblField)
            y -= 36
        }

        let hourRow = makeSettingRow(label: "Use 24-Hour", y: y, inset: inset, width: cardW)
        let hourToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        hourToggle.state = w.config.use24Hour ? .on : .off
        hourToggle.target = self; hourToggle.action = #selector(configToggleChanged(_:))
        hourToggle.identifier = NSUserInterfaceItemIdentifier("cfg:world-clock:use24Hour:\(instance.id.uuidString)")
        panel.addSubview(hourRow); panel.addSubview(hourToggle)
        y -= 36

        let flagsRow = makeSettingRow(label: "Show Flags", y: y, inset: inset, width: cardW)
        let flagsToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        flagsToggle.state = w.config.showFlags ? .on : .off
        flagsToggle.target = self; flagsToggle.action = #selector(configToggleChanged(_:))
        flagsToggle.identifier = NSUserInterfaceItemIdentifier("cfg:world-clock:showFlags:\(instance.id.uuidString)")
        panel.addSubview(flagsRow); panel.addSubview(flagsToggle)
        y -= 36

        let secsRow = makeSettingRow(label: "Show Seconds", y: y, inset: inset, width: cardW)
        let secsToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        secsToggle.state = w.config.showSeconds ? .on : .off
        secsToggle.target = self; secsToggle.action = #selector(configToggleChanged(_:))
        secsToggle.identifier = NSUserInterfaceItemIdentifier("cfg:world-clock:showSeconds:\(instance.id.uuidString)")
        panel.addSubview(secsRow); panel.addSubview(secsToggle)
        y -= 36

        let compactRow = makeSettingRow(label: "Compact Mode", y: y, inset: inset, width: cardW)
        let compactToggle = NSSwitch(frame: NSRect(x: cardW - 10, y: y - 22, width: 38, height: 20))
        compactToggle.state = w.config.compactMode ? .on : .off
        compactToggle.target = self; compactToggle.action = #selector(configToggleChanged(_:))
        compactToggle.identifier = NSUserInterfaceItemIdentifier("cfg:world-clock:compactMode:\(instance.id.uuidString)")
        panel.addSubview(compactRow); panel.addSubview(compactToggle)
    }

    // MARK: - Generic Config Change Handlers

    @objc func configToggleChanged(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":") // cfg:widgetID:field:uuid
        guard parts.count >= 4,
              let uuid = UUID(uuidString: String(parts[3])),
              let instance = statusBarController.instance(for: uuid) else { return }

        let widgetID = String(parts[1])
        let field = String(parts[2])
        let isOn = sender.state == .on

        switch widgetID {
        case "cpu-monitor":
            guard let w = instance.widget.underlying(as: CPUWidget.self) else { return }
            switch field {
            case "showPercentage": w.config.showPercentage = isOn
            case "showBar": w.config.showBar = isOn
            default: break
            }
        case "ram-monitor":
            guard let w = instance.widget.underlying(as: RAMWidget.self) else { return }
            switch field {
            case "showAbsolute": w.config.showAbsolute = isOn
            case "showBar": w.config.showBar = isOn
            default: break
            }
        case "network-speed":
            guard let w = instance.widget.underlying(as: NetworkSpeedWidget.self) else { return }
            switch field {
            case "showDownload": w.config.showDownload = isOn
            case "showUpload": w.config.showUpload = isOn
            case "compactFormat": w.config.compactFormat = isOn
            default: break
            }
        case "battery-health":
            guard let w = instance.widget.underlying(as: BatteryWidget.self) else { return }
            switch field {
            case "showTimeRemaining": w.config.showTimeRemaining = isOn
            case "showHealth": w.config.showHealth = isOn
            case "showCycles": w.config.showCycles = isOn
            default: break
            }
        case "uptime":
            guard let w = instance.widget.underlying(as: UptimeWidget.self) else { return }
            switch field {
            case "showLabel": w.config.showLabel = isOn
            case "showSeconds":
                w.config.showSeconds = isOn
                saveWidgetConfig(instance: instance)
                instance.widget.refresh()
                return
            default: break
            }
        case "weather-current":
            guard let w = instance.widget.underlying(as: WeatherWidget.self) else { return }
            switch field {
            case "useCelsius": w.config.useCelsius = isOn
            case "showFeelsLike": w.config.showFeelsLike = isOn
            case "showEmoji": w.config.showEmoji = isOn
            case "showCity": w.config.showCity = isOn
            default: break
            }
        case "pomodoro":
            guard let w = instance.widget.underlying(as: PomodoroWidget.self) else { return }
            switch field {
            case "autoStartBreak": w.config.autoStartBreak = isOn
            case "showEmoji": w.config.showEmoji = isOn
            default: break
            }
        case "countdown":
            guard let w = instance.widget.underlying(as: CountdownWidget.self) else { return }
            switch field {
            case "showSeconds":
                w.config.showSeconds = isOn
                saveWidgetConfig(instance: instance)
                instance.widget.refresh()
                return
            case "countUpAfter": w.config.countUpAfter = isOn
            default: break
            }
        case "daily-quote":
            guard let w = instance.widget.underlying(as: DailyQuoteWidget.self) else { return }
            switch field {
            case "showInBar": w.config.showInBar = isOn
            case "scrollInBar": w.config.scrollInBar = isOn
            default: break
            }
        case "moon-phase":
            guard let w = instance.widget.underlying(as: MoonPhaseWidget.self) else { return }
            switch field {
            case "showName": w.config.showName = isOn
            case "showIllumination": w.config.showIllumination = isOn
            case "showCountdown": w.config.showCountdown = isOn
            default: break
            }
        case "custom-date":
            guard let w = instance.widget.underlying(as: CustomDateWidget.self) else { return }
            switch field {
            case "showDayProgress": w.config.showDayProgress = isOn
            default: break
            }
        case "daily-goal":
            guard let w = instance.widget.underlying(as: DailyGoalWidget.self) else { return }
            switch field {
            case "showBar": w.config.showBar = isOn
            default: break
            }
        case "crypto":
            guard let w = instance.widget.underlying(as: CryptoWidget.self) else { return }
            switch field {
            case "showChange": w.config.showChange = isOn
            case "coloredTicker": w.config.coloredTicker = isOn
            default: break
            }
        case "market-status":
            guard let w = instance.widget.underlying(as: MarketStatusWidget.self) else { return }
            switch field {
            case "showCountdown": w.config.showCountdown = isOn
            case "showDot": w.config.showDot = isOn
            default: break
            }
        case "calendar-next":
            guard let w = instance.widget.underlying(as: CalendarNextWidget.self) else { return }
            switch field {
            case "showTimeUntil": w.config.showTimeUntil = isOn
            case "showAllDay": w.config.showAllDay = isOn
            default: break
            }
        case "inbox-count":
            guard let w = instance.widget.underlying(as: InboxCountWidget.self) else { return }
            if field == "hideWhenZero" { w.config.hideWhenZero = isOn }
        case "screen-time":
            guard let w = instance.widget.underlying(as: ScreenTimeWidget.self) else { return }
            if field == "showLabel" { w.config.showLabel = isOn }
        case "reminders":
            guard let w = instance.widget.underlying(as: RemindersWidget.self) else { return }
            switch field {
            case "showCount": w.config.showCount = isOn
            case "showNextTitle": w.config.showNextTitle = isOn
            default: break
            }
        case "now-playing":
            guard let w = instance.widget.underlying(as: NowPlayingWidget.self) else { return }
            switch field {
            case "showArtist": w.config.showArtist = isOn
            case "scrollLongText": w.config.scrollLongText = isOn
            default: break
            }
        case "hn-top":
            guard let w = instance.widget.underlying(as: HackerNewsWidget.self) else { return }
            switch field {
            case "showScore": w.config.showScore = isOn
            case "scrollTitle": w.config.scrollTitle = isOn
            default: break
            }
        case "git-branch":
            guard let w = instance.widget.underlying(as: GitBranchWidget.self) else { return }
            switch field {
            case "showDirtyIndicator": w.config.showDirtyIndicator = isOn
            case "showAheadBehind": w.config.showAheadBehind = isOn
            default: break
            }
        case "disk-space":
            guard let w = instance.widget.underlying(as: DiskSpaceWidget.self) else { return }
            if field == "showPercentage" { w.config.showPercentage = isOn }
        case "ip-address":
            guard let w = instance.widget.underlying(as: IPAddressWidget.self) else { return }
            switch field {
            case "showPublic": w.config.showPublic = isOn
            case "showLocal": w.config.showLocal = isOn
            default: break
            }
        case "sunrise-sunset":
            guard let w = instance.widget.underlying(as: SunriseSunsetWidget.self) else { return }
            if field == "showDayLength" { w.config.showDayLength = isOn }
        case "tz-diff":
            guard let w = instance.widget.underlying(as: TimeZoneDiffWidget.self) else { return }
            if field == "use24Hour" { w.config.use24Hour = isOn }
        case "world-clock":
            guard let w = instance.widget.underlying(as: WorldClockWidget.self) else { return }
            switch field {
            case "use24Hour": w.config.use24Hour = isOn
            case "showFlags": w.config.showFlags = isOn
            case "showSeconds": w.config.showSeconds = isOn
            case "compactMode": w.config.compactMode = isOn
            default: break
            }
        default: break
        }

        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func configSliderChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        guard parts.count >= 4,
              let uuid = UUID(uuidString: String(parts[3])),
              let instance = statusBarController.instance(for: uuid) else { return }

        let widgetID = String(parts[1])
        let field = String(parts[2])
        let value = sender.doubleValue

        switch widgetID {
        case "cpu-monitor":
            guard let w = instance.widget.underlying(as: CPUWidget.self) else { return }
            if field == "alertThreshold" { w.config.alertThreshold = value }
        case "ram-monitor":
            guard let w = instance.widget.underlying(as: RAMWidget.self) else { return }
            if field == "alertThreshold" { w.config.alertThreshold = value }
        case "battery-health":
            guard let w = instance.widget.underlying(as: BatteryWidget.self) else { return }
            if field == "alertBelow" { w.config.alertBelow = Int(value) }
        case "pomodoro":
            guard let w = instance.widget.underlying(as: PomodoroWidget.self) else { return }
            switch field {
            case "workMinutes": w.config.workMinutes = Int(value)
            case "shortBreakMinutes": w.config.shortBreakMinutes = Int(value)
            case "longBreakMinutes": w.config.longBreakMinutes = Int(value)
            case "cyclesBeforeLong": w.config.cyclesBeforeLong = Int(value)
            default: break
            }
        case "daily-quote":
            guard let w = instance.widget.underlying(as: DailyQuoteWidget.self) else { return }
            if field == "tickerWidth" { w.config.tickerWidth = value }
        case "calendar-next":
            guard let w = instance.widget.underlying(as: CalendarNextWidget.self) else { return }
            if field == "minuteWarning" { w.config.minuteWarning = Int(value) }
        case "now-playing":
            guard let w = instance.widget.underlying(as: NowPlayingWidget.self) else { return }
            if field == "maxWidth" { w.config.maxWidth = CGFloat(value) }
        case "git-branch":
            guard let w = instance.widget.underlying(as: GitBranchWidget.self) else { return }
            if field == "truncateLength" { w.config.truncateLength = Int(value) }
        case "forex-rate":
            guard let w = instance.widget.underlying(as: ForexWidget.self) else { return }
            if field == "decimalPlaces" { w.config.decimalPlaces = Int(value) }
        case "disk-space":
            guard let w = instance.widget.underlying(as: DiskSpaceWidget.self) else { return }
            if field == "warnBelowGB" { w.config.warnBelowGB = Int(value) }
        default: break
        }

        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func configPopupChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        guard parts.count >= 4,
              let uuid = UUID(uuidString: String(parts[3])),
              let instance = statusBarController.instance(for: uuid) else { return }

        let widgetID = String(parts[1])
        let field = String(parts[2])
        let idx = sender.indexOfSelectedItem

        switch widgetID {
        case "cpu-monitor":
            guard let w = instance.widget.underlying(as: CPUWidget.self) else { return }
            if field == "refreshRate" {
                let rates: [TimeInterval] = [1, 2, 3, 5, 10]
                if idx >= 0 && idx < rates.count {
                    w.config.refreshRate = rates[idx]
                    saveWidgetConfig(instance: instance)
                    instance.widget.refresh()
                    return
                }
            }
        case "network-speed":
            guard let w = instance.widget.underlying(as: NetworkSpeedWidget.self) else { return }
            if field == "refreshRate" {
                let netRates: [TimeInterval] = [1, 2, 3, 5]
                if idx >= 0 && idx < netRates.count {
                    w.config.refreshRate = netRates[idx]
                    saveWidgetConfig(instance: instance)
                    instance.widget.refresh()
                    return
                }
            }
        case "ram-monitor":
            guard let w = instance.widget.underlying(as: RAMWidget.self) else { return }
            if field == "refreshRate" {
                let rates: [TimeInterval] = [1, 2, 5, 10]
                if idx >= 0 && idx < rates.count {
                    w.config.refreshRate = rates[idx]
                    saveWidgetConfig(instance: instance)
                    instance.widget.refresh()
                    return
                }
            }
        case "crypto":
            guard let w = instance.widget.underlying(as: CryptoWidget.self) else { return }
            if field == "currency" {
                let currencies = ["usd", "eur", "gbp", "jpy"]
                if idx >= 0 && idx < currencies.count { w.config.currency = currencies[idx] }
            }
        case "now-playing":
            guard let w = instance.widget.underlying(as: NowPlayingWidget.self) else { return }
            if field == "preferredPlayer" {
                let players = ["system", "spotify", "music"]
                if idx >= 0 && idx < players.count { w.config.preferredPlayer = players[idx] }
            }
        case "live-scores":
            guard let w = instance.widget.underlying(as: LiveScoresWidget.self) else { return }
            if field == "sport" {
                let sportLeagueMap: [(String, String)] = [
                    ("basketball", "nba"), ("football", "nfl"), ("baseball", "mlb"),
                    ("hockey", "nhl"), ("soccer", "eng.1")
                ]
                if idx >= 0 && idx < sportLeagueMap.count {
                    w.config.sport = sportLeagueMap[idx].0
                    w.config.league = sportLeagueMap[idx].1
                }
            } else if field == "league" {
                let leagues = ["nba", "nfl", "mlb", "nhl", "eng.1"]
                if idx >= 0 && idx < leagues.count { w.config.league = leagues[idx] }
            }
        default: break
        }

        saveWidgetConfig(instance: instance)
        instance.widget.refresh()
    }

    @objc func configTextChanged(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        guard parts.count >= 4,
              let uuid = UUID(uuidString: String(parts[3])),
              let instance = statusBarController.instance(for: uuid) else { return }

        let widgetID = String(parts[1])
        let field = String(parts[2])
        let value = sender.stringValue

        switch widgetID {
        case "weather-current":
            guard let w = instance.widget.underlying(as: WeatherWidget.self) else { return }
            switch field {
            case "cityName": w.config.cityName = value
            case "manualLat": w.config.manualLat = Double(value)
            case "manualLon": w.config.manualLon = Double(value)
            default: break
            }
        case "countdown":
            guard let w = instance.widget.underlying(as: CountdownWidget.self) else { return }
            switch field {
            case "eventName": w.config.eventName = value
            case "emoji": w.config.emoji = value
            default: break
            }
        case "custom-date":
            guard let w = instance.widget.underlying(as: CustomDateWidget.self) else { return }
            if field == "format" { w.config.format = value }
        case "daily-goal":
            guard let w = instance.widget.underlying(as: DailyGoalWidget.self) else { return }
            switch field {
            case "goalName": w.config.goalName = value
            case "target": w.config.target = Int(value) ?? w.config.target
            case "unit": w.config.unit = value
            default: break
            }
        case "git-branch":
            guard let w = instance.widget.underlying(as: GitBranchWidget.self) else { return }
            if field == "repoPath" { w.config.repoPath = value }
        case "forex-rate":
            guard let w = instance.widget.underlying(as: ForexWidget.self) else { return }
            switch field {
            case "baseCurrency": w.config.baseCurrency = value.uppercased()
            case "targetCurrency": w.config.targetCurrency = value.uppercased()
            default: break
            }
        case "sunrise-sunset":
            guard let w = instance.widget.underlying(as: SunriseSunsetWidget.self) else { return }
            switch field {
            case "latitude": w.config.latitude = Double(value) ?? w.config.latitude
            case "longitude": w.config.longitude = Double(value) ?? w.config.longitude
            default: break
            }
        case "tz-diff":
            guard let w = instance.widget.underlying(as: TimeZoneDiffWidget.self) else { return }
            switch field {
            case "targetTimeZone": w.config.targetTimeZone = value
            case "label": w.config.label = value
            default: break
            }
        case "world-clock":
            guard let w = instance.widget.underlying(as: WorldClockWidget.self) else { return }
            switch field {
            case "tz0", "tz1", "tz2":
                let idx = Int(String(field.last!))!
                guard TimeZone(identifier: value) != nil || value.isEmpty else { return }
                while w.config.timezoneIDs.count <= idx { w.config.timezoneIDs.append("") }
                w.config.timezoneIDs[idx] = value
                w.config.timezoneIDs = w.config.timezoneIDs.filter { !$0.isEmpty }
            case "lbl0", "lbl1", "lbl2":
                let idx = Int(String(field.last!))!
                while w.config.labels.count <= idx { w.config.labels.append("") }
                w.config.labels[idx] = value
            default: break
            }
        default: break
        }

        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func countdownDateChanged(_ sender: NSDatePicker) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        guard parts.count >= 4,
              let uuid = UUID(uuidString: String(parts[3])),
              let instance = statusBarController.instance(for: uuid),
              let w = instance.widget.underlying(as: CountdownWidget.self) else { return }
        w.config.targetDate = sender.dateValue
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func cryptoAddCoin(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue,
              let (instance, cryptoWidget) = findCryptoInstance(from: id) else { return }
        let coin = sender.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        guard !coin.isEmpty else { return }
        cryptoWidget.addCoin(coin)
        sender.stringValue = ""
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rebuildSettingsUI()
        }
    }

    // MARK: - Crypto Actions

    private func findCryptoInstance(from identifier: String) -> (WidgetInstance, CryptoWidget)? {
        let parts = identifier.split(separator: ":")
        guard parts.count >= 2, let uuid = UUID(uuidString: String(parts.last!)) else { return nil }
        guard let instance = statusBarController.instance(for: uuid),
              let cryptoWidget = instance.widget.underlying(as: CryptoWidget.self) else { return nil }
        return (instance, cryptoWidget)
    }

    @objc func removeCryptoAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        // format: remove-coin:coinId:uuid
        guard parts.count >= 3 else { return }
        let coinId = String(parts[1])
        let uuidStr = String(parts[2])
        guard let uuid = UUID(uuidString: uuidStr),
              let instance = statusBarController.instance(for: uuid),
              let cryptoWidget = instance.widget.underlying(as: CryptoWidget.self) else { return }
        cryptoWidget.removeCoin(coinId)
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
        rebuildSettingsUI()
    }

    @objc func cryptoAddCoinFromButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let (instance, cryptoWidget) = findCryptoInstance(from: id) else { return }
        let fieldID = id.replacingOccurrences(of: "addCoinBtn:", with: "addCoinField:")
        guard let field = findTextField(withIdentifier: fieldID, in: settingsContentView) else { return }
        let coin = field.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        guard !coin.isEmpty else { return }
        cryptoWidget.addCoin(coin)
        field.stringValue = ""
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rebuildSettingsUI()
        }
    }

    @objc func cryptoSpeedChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue,
              let (instance, cryptoWidget) = findCryptoInstance(from: id) else { return }
        cryptoWidget.config.scrollSpeed = sender.doubleValue
        if let sv = instance.scrollView {
            sv.speed = CGFloat(sender.doubleValue)
        }
        saveWidgetConfig(instance: instance)
    }

    @objc func cryptoWidthChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue,
              let (instance, cryptoWidget) = findCryptoInstance(from: id) else { return }
        cryptoWidget.config.tickerWidth = sender.doubleValue
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func cryptoRefreshChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,
              let (instance, cryptoWidget) = findCryptoInstance(from: id) else { return }
        let intervals: [TimeInterval] = [30, 60, 120, 300]
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < intervals.count else { return }
        cryptoWidget.config.refreshInterval = intervals[idx]
        saveWidgetConfig(instance: instance)
        instance.widget.refresh()
    }

    // MARK: - Generic Config Panel

    private func buildGenericConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        let controls = instance.widget.buildConfigControls { [weak self] in
            self?.widgetConfigChanged(instance: instance)
        }
        let inset: CGFloat = 16
        var y = panel.frame.height - 20

        if controls.isEmpty {
            let label = NSTextField(labelWithString: "No configurable settings for this widget.")
            label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            label.textColor = Theme.textMuted
            label.frame = NSRect(x: inset, y: y - 20, width: width - inset * 2, height: 20)
            panel.addSubview(label)
            return
        }

        for control in controls {
            control.frame = NSRect(x: inset, y: y - control.frame.height, width: width - inset * 2, height: control.frame.height)
            panel.addSubview(control)
            y -= control.frame.height + 8
        }
    }

    private func makeSettingRow(label: String, y: CGFloat, inset: CGFloat, width: CGFloat) -> NSTextField {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = Theme.textSecondary
        lbl.frame = NSRect(x: inset, y: y - 20, width: width / 2, height: 18)
        return lbl
    }

    private func makeCategoryPill(title: String, identifier: String, isSelected: Bool, font: NSFont) -> NSButton {
        let pill = NSButton(title: title, target: self, action: #selector(galleryCategoryChanged(_:)))
        pill.bezelStyle = .inline
        pill.isBordered = false
        pill.font = font
        pill.wantsLayer = true
        if isSelected {
            pill.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.18).cgColor
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = Theme.accent.withAlphaComponent(0.4).cgColor
            pill.contentTintColor = Theme.accent
            pill.layer?.shadowColor = Theme.accent.cgColor
            pill.layer?.shadowRadius = 6
            pill.layer?.shadowOpacity = 0.3
            pill.layer?.shadowOffset = .zero
        } else {
            pill.layer?.backgroundColor = NSColor(red: 1, green: 1, blue: 1, alpha: 0.04).cgColor
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = Theme.cardBorder.cgColor
            pill.contentTintColor = Theme.textMuted
        }
        pill.layer?.cornerRadius = 13
        pill.identifier = NSUserInterfaceItemIdentifier(identifier)
        return pill
    }

    private func galleryPreviewText(for widgetID: String) -> String {
        switch widgetID {
        case "stock-ticker": return "AAPL $189.42 +1.2%  TSLA $245.01 -0.8%"
        case "crypto": return "BTC $67,432 +2.1%  ETH $3,521 +0.9%"
        case "world-clock": return "NYC 3:42 PM  LON 8:42 PM  TKY 4:42 AM"
        case "weather-current": return "\u{2600}\u{FE0F} 72\u{00B0}F feels 70\u{00B0} New York"
        case "cpu-monitor": return "CPU 23%"
        case "ram-monitor": return "RAM 8.2/16 GB"
        case "network-speed": return "\u{2191} 1.2 MB/s  \u{2193} 4.8 MB/s"
        case "battery-health": return "\u{1F50B} 87% 2:30 remaining"
        case "uptime": return "Up 3d 14h"
        case "disk-space": return "Disk: 234 GB free"
        case "ip-address": return "192.168.1.42"
        case "pomodoro": return "\u{1F345} Focus 18:42"
        case "countdown": return "\u{1F389} Birthday in 14d 6h"
        case "daily-quote": return "\u{201C}Stay hungry, stay foolish\u{201D}"
        case "moon-phase": return "\u{1F314} Waxing Gibbous 78%"
        case "custom-date": return "Day 109 | W16 | Q2"
        case "daily-goal": return "\u{1F3AF} 6/10 glasses"
        case "market-status": return "\u{1F7E2} Open | 2h 30m left"
        case "calendar-next": return "Standup in 14m"
        case "inbox-count": return "Mail: 12 unread"
        case "screen-time": return "Screen: 4h 23m"
        case "reminders": return "\u{2611}\u{FE0F} 3 pending"
        case "now-playing": return "\u{266B} Radiohead - Creep"
        case "hn-top": return "HN: Show HN: I built... (342pts)"
        case "live-scores": return "LAL 98 - BOS 102 Q4 2:31"
        case "git-branch": return "\u{1F33F} main | 3 changed"
        case "forex-rate": return "EUR/USD 1.0842"
        case "sunrise-sunset": return "\u{1F305} 6:42 AM  \u{1F307} 7:58 PM"
        case "tz-diff": return "Tokyo +13h (2:00 AM)"
        case "gpu-monitor": return "GPU 34% 52\u{00B0}C"
        case "temperature-sensors": return "CPU 47\u{00B0}C"
        case "top-processes": return "Safari 12.3%"
        case "bluetooth-battery": return "\u{1F3A7} AirPods 82%"
        case "calendar-grid": return "\u{1F4C5} Sun 20 | 3 events"
        case "meeting-joiner": return "\u{1F4F9} Standup in 12m"
        case "keep-awake": return "\u{2615} Awake 1:23:45"
        case "focus-task": return "\u{1F3AF} Ship the login page"
        case "clipboard-peek": return "\u{1F4CB} hello world..."
        case "dark-mode-toggle": return "\u{1F319} Dark"
        case "script-widget": return "Hello | color=green"
        case "docker-status": return "\u{1F433} 3 running"
        case "github-notifications": return "GH 5"
        case "server-ping": return "\u{1F7E2} Google 12ms"
        case "air-quality": return "AQI 42 Good"
        case "uv-index": return "UV 3 Moderate"
        case "dad-joke": return "\u{1F602} Why don't eggs tell jokes?"
        case "dice-roller": return "\u{1F3B2} 7"
        case "caffeine-tracker": return "\u{2615} 187mg"
        case "water-reminder": return "\u{1F4A7} 3/8"
        case "stand-reminder": return "\u{1F9CD} 42m"
        case "f1-standings": return "F1 #1 Verstappen 575pts"
        case "soccer-table": return "#1 Arsenal 82pts"
        default: return ""
        }
    }

    private func filteredGalleryEntries() -> [WidgetRegistryEntry] {
        var entries = WidgetRegistry.shared.entries
        if let cat = gallerySelectedCategory {
            entries = entries.filter { $0.category == cat }
        }
        if !gallerySearchText.isEmpty {
            let q = gallerySearchText.lowercased()
            entries = entries.filter {
                $0.displayName.lowercased().contains(q) ||
                $0.subtitle.lowercased().contains(q) ||
                $0.category.rawValue.lowercased().contains(q)
            }
        }
        return entries
    }

    private func categoriesInOrder(for entries: [WidgetRegistryEntry]) -> [WidgetCategory] {
        var seen: Set<WidgetCategory> = []
        var result: [WidgetCategory] = []
        for e in entries {
            if seen.insert(e.category).inserted {
                result.append(e.category)
            }
        }
        return result
    }

    private func makeTrackedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let attrStr = NSMutableAttributedString(string: text)
        attrStr.addAttribute(.kern, value: 2.5, range: NSRange(location: 0, length: attrStr.length))
        attrStr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10.5, weight: .semibold), range: NSRange(location: 0, length: attrStr.length))
        attrStr.addAttribute(.foregroundColor, value: Theme.textFaint, range: NSRange(location: 0, length: attrStr.length))
        label.attributedStringValue = attrStr
        return label
    }

    // MARK: - Actions

    @objc func toggleWidgetConfig(_ sender: NSButton) {
        let idx = sender.tag
        let instances = statusBarController.activeInstances
        guard idx < instances.count else { return }
        let id = instances[idx].id
        if expandedWidgets.contains(id) {
            expandedWidgets.remove(id)
        } else {
            expandedWidgets.insert(id)
        }
        rebuildSettingsUI()
    }

    @objc func moveWidgetUp(_ sender: NSButton) {
        let idx = sender.tag
        guard idx > 0 else { return }
        WidgetStore.shared.reorder(from: idx, to: idx - 1)
        statusBarController.removeAllWidgets()
        statusBarController.syncMenuBar()
        rebuildSettingsUI()
    }

    @objc func moveWidgetDown(_ sender: NSButton) {
        let idx = sender.tag
        let instances = statusBarController.activeInstances
        guard idx < instances.count - 1 else { return }
        WidgetStore.shared.reorder(from: idx, to: idx + 1)
        statusBarController.removeAllWidgets()
        statusBarController.syncMenuBar()
        rebuildSettingsUI()
    }

    @objc func removeWidgetAction(_ sender: NSButton) {
        let idx = sender.tag
        let instances = statusBarController.activeInstances
        guard idx < instances.count else { return }
        let instanceID = instances[idx].id
        expandedWidgets.remove(instanceID)
        statusBarController.removeWidget(instanceID: instanceID)
        rebuildSettingsUI()
    }

    @objc func addWidgetAction(_ sender: NSButton) {
        guard let widgetID = sender.identifier?.rawValue else { return }
        _ = statusBarController.addWidget(widgetID: widgetID)
        rebuildSettingsUI()
    }

    @objc func refreshAllWidgets() {
        statusBarController.refreshAll()
    }

    // MARK: - Stock Ticker Config Actions

    private func findStockInstance(from identifier: String) -> (WidgetInstance, StockTickerWidget)? {
        let parts = identifier.split(separator: ":")
        guard parts.count >= 2, let uuid = UUID(uuidString: String(parts.last!)) else { return nil }
        guard let instance = statusBarController.instance(for: uuid),
              let stockWidget = instance.widget.underlying(as: StockTickerWidget.self) else { return nil }
        return (instance, stockWidget)
    }

    @objc func removeStockSymbol(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":")
        guard parts.count >= 3 else { return }
        let symbol = String(parts[1])
        let uuidStr = String(parts[2])
        guard let uuid = UUID(uuidString: uuidStr),
              let instance = statusBarController.instance(for: uuid),
              let stockWidget = instance.widget.underlying(as: StockTickerWidget.self) else { return }
        stockWidget.removeSymbol(symbol)
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
        rebuildSettingsUI()
    }

    @objc func addStockSymbolFromField(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue,
              let (instance, stockWidget) = findStockInstance(from: id) else { return }
        let symbol = sender.stringValue
        guard !symbol.isEmpty else { return }
        stockWidget.addSymbol(symbol)
        sender.stringValue = ""
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
        // Delay rebuild to let data fetch
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.rebuildSettingsUI()
        }
    }

    @objc func addStockSymbolFromButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let (instance, stockWidget) = findStockInstance(from: id) else { return }
        // Find the corresponding text field
        let fieldID = id.replacingOccurrences(of: "addSymbolBtn:", with: "addSymbolField:")
        guard let field = findTextField(withIdentifier: fieldID, in: settingsContentView) else { return }
        let symbol = field.stringValue
        guard !symbol.isEmpty else { return }
        stockWidget.addSymbol(symbol)
        field.stringValue = ""
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.rebuildSettingsUI()
        }
    }

    @objc func stockSpeedChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue,
              let (instance, stockWidget) = findStockInstance(from: id) else { return }
        stockWidget.config.scrollSpeed = sender.doubleValue
        if let sv = instance.scrollView {
            sv.speed = CGFloat(sender.doubleValue)
        }
        saveWidgetConfig(instance: instance)
    }

    @objc func stockColorToggled(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue,
              let (instance, stockWidget) = findStockInstance(from: id) else { return }
        stockWidget.config.coloredTicker = (sender.state == .on)
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func stockWidthChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue,
              let (instance, stockWidget) = findStockInstance(from: id) else { return }
        stockWidget.config.tickerWidth = sender.doubleValue
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    @objc func stockRefreshChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,
              let (instance, stockWidget) = findStockInstance(from: id) else { return }
        let intervals: [TimeInterval] = [15, 30, 60, 120, 300]
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < intervals.count else { return }
        stockWidget.config.refreshInterval = intervals[idx]
        saveWidgetConfig(instance: instance)
        // Restart the widget to pick up new interval
        instance.widget.refresh()
    }

    private func widgetConfigChanged(instance: WidgetInstance) {
        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    private func saveWidgetConfig(instance: WidgetInstance) {
        if let data = instance.widget.getConfigData() {
            WidgetStore.shared.updateConfig(instanceID: instance.id, configData: data)
        }
    }

    private func findTextField(withIdentifier id: String, in view: NSView?) -> NSTextField? {
        guard let view = view else { return nil }
        for sub in view.subviews {
            if let tf = sub as? NSTextField, tf.identifier?.rawValue == id { return tf }
            if let found = findTextField(withIdentifier: id, in: sub) { return found }
        }
        return nil
    }

    // MARK: - Pomodoro Actions

    private func findPomodoroWidget() -> PomodoroWidget? {
        for instance in statusBarController.activeInstances {
            if let pomo = instance.widget.underlying(as: PomodoroWidget.self) {
                return pomo
            }
        }
        return nil
    }

    @objc func pomodoroStart() {
        findPomodoroWidget()?.startWork()
    }

    @objc func pomodoroStop() {
        findPomodoroWidget()?.pauseResume()
    }

    @objc func pomodoroSkip() {
        findPomodoroWidget()?.skipPhase()
    }

    @objc func pomodoroReset() {
        findPomodoroWidget()?.resetTimer()
    }

    // MARK: - Daily Quote Actions

    @objc func copyQuote() {
        for instance in statusBarController.activeInstances {
            if let quoteWidget = instance.widget.underlying(as: DailyQuoteWidget.self) {
                let mode = quoteWidget.render()
                if case .scrollingText(let attr, _) = mode {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(attr.string, forType: .string)
                } else if case .text(let str) = mode {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(str, forType: .string)
                }
                break
            }
        }
    }

    // MARK: - Daily Goal Actions

    private func findGoalWidget() -> DailyGoalWidget? {
        for instance in statusBarController.activeInstances {
            if let goal = instance.widget.underlying(as: DailyGoalWidget.self) {
                return goal
            }
        }
        return nil
    }

    @objc func goalIncrement(_ sender: NSMenuItem) {
        guard let amount = sender.representedObject as? Int else { return }
        findGoalWidget()?.increment(by: amount)
    }

    @objc func goalReset() {
        findGoalWidget()?.resetToday()
    }

    // MARK: - Gallery Search & Filter

    @objc func gallerySearchChanged(_ sender: NSTextField) {
        gallerySearchText = sender.stringValue
        rebuildSettingsUI()
        // Re-focus the search field after rebuild
        if let field = findTextField(withIdentifier: "gallerySearch", in: settingsContentView) {
            settingsWindow?.makeFirstResponder(field)
            field.currentEditor()?.moveToEndOfDocument(nil)
        }
    }

    @objc func galleryCategoryChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let catName = String(id.dropFirst("cat:".count))
        if catName == "all" {
            gallerySelectedCategory = nil
        } else {
            let tapped = WidgetCategory.allCases.first { $0.rawValue == catName }
            // Toggle: tap same category again to deselect
            if gallerySelectedCategory == tapped {
                gallerySelectedCategory = nil
            } else {
                gallerySelectedCategory = tapped
            }
        }
        rebuildSettingsUI()
    }

    // MARK: - Menu Bar Manager Actions

    @objc func requestAccessibility() {
        MenuBarManager.requestAccessibilityPermission()
        // Rebuild after a delay to check if permission was granted
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rebuildSettingsUI()
        }
    }

    @objc func menuBarToggleItem(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let itemID = String(id.dropFirst("menubar-toggle:".count))
        let mgr = MenuBarManager.shared
        if let item = mgr.detectedItems.first(where: { $0.id == itemID }) {
            mgr.toggleItem(item)
            rebuildSettingsUI()
        }
    }

    @objc func menuBarShowAll() {
        MenuBarManager.shared.showAllHidden()
        rebuildSettingsUI()
    }

    // MARK: - New Widget Actions

    // MARK: - App Launcher Actions

    @objc func openCalendarApp() {
        NSWorkspace.shared.launchApplication("Calendar")
    }

    @objc func openMailApp() {
        NSWorkspace.shared.launchApplication("Mail")
    }

    @objc func openRemindersApp() {
        NSWorkspace.shared.launchApplication("Reminders")
    }

    @objc func copyPublicIP() {
        for instance in statusBarController.activeInstances {
            if instance.widgetID == "ip-address",
               let widget = instance.widget.underlying(as: IPAddressWidget.self) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(widget.publicIPValue, forType: .string)
                break
            }
        }
    }

    // MARK: - Menu Bar Appearance

    @objc func toggleMenuBarAppearance(_ sender: NSSwitch) {
        var appearance = MenuBarAppearance.load()
        appearance.isEnabled = sender.state == .on
        if appearance.isEnabled && appearance.mode == MenuBarAppearance.default.mode {
            // If enabling for the first time with default, apply "Midnight" preset
            if let midnight = MenuBarAppearance.presets.first {
                appearance.mode = midnight.1.mode
                appearance.opacity = midnight.1.opacity
            }
        }
        appearance.save()
        MenuBarOverlay.shared.apply(appearance)
        rebuildSettingsUI()
    }

    @objc func selectAppearancePreset(_ sender: NSButton) {
        let presets = MenuBarAppearance.presets
        guard sender.tag >= 0, sender.tag < presets.count else { return }
        let (_, preset) = presets[sender.tag]
        var appearance = MenuBarAppearance.load()
        appearance.isEnabled = true
        appearance.mode = preset.mode
        appearance.opacity = preset.opacity
        appearance.save()
        MenuBarOverlay.shared.apply(appearance)
        rebuildSettingsUI()
    }

    @objc func appearanceOpacityChanged(_ sender: NSSlider) {
        var appearance = MenuBarAppearance.load()
        appearance.opacity = sender.doubleValue
        appearance.save()
        MenuBarOverlay.shared.apply(appearance)
        // Don't rebuild full UI on slider drag - just update the overlay live
    }

    // MARK: - Updates

    @objc func checkForUpdates() {
        // Load Sparkle dynamically so the app doesn't crash if framework isn't bundled
        if sparkleUpdater == nil {
            if let sparkleBundle = Bundle(path: Bundle.main.privateFrameworksPath ?? ""),
               let sparkleClass = sparkleBundle.classNamed("Sparkle.SPUStandardUpdaterController") as? NSObject.Type {
                sparkleUpdater = sparkleClass.init()
            }
        }
        if let updater = sparkleUpdater {
            _ = updater.perform(NSSelectorFromString("checkForUpdates:"), with: nil)
        }
    }

    // MARK: - Launch at Login

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleLaunchAtLogin(_ sender: NSSwitch) {
        if #available(macOS 13.0, *) {
            do {
                if sender.state == .on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                sender.state = sender.state == .on ? .off : .on
            }
        }
    }

    // MARK: - Profile Actions

    @objc func activateProfile(_ sender: NSButton) {
        let presets = ProfileManager.presets
        guard sender.tag >= 0 && sender.tag < presets.count else { return }
        let preset = presets[sender.tag]

        // Create preset profile if it doesn't exist, then activate
        let mgr = ProfileManager.shared
        let existing = mgr.profiles.first { $0.name == preset.name }
        let profile: WidgetProfile
        if let existing = existing {
            profile = existing
        } else {
            profile = mgr.createPreset(name: preset.name, icon: preset.icon, widgetIDs: preset.widgetIDs)
        }

        mgr.activate(id: profile.id)
        statusBarController.removeAllWidgets()
        statusBarController.syncMenuBar()
        rebuildSettingsUI()
    }

    @objc func saveCurrentProfile() {
        let alert = NSAlert()
        alert.messageText = "Save Profile"
        alert.informativeText = "Enter a name for this profile:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = "My Profile"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.isEmpty ? "My Profile" : input.stringValue
            _ = ProfileManager.shared.captureCurrentState(name: name)
            rebuildSettingsUI()
        }
    }

    // MARK: - Settings Refresh Timer

    func startSettingsRefreshTimer() {
        settingsRefreshTimer?.invalidate()
        settingsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let w = self.settingsWindow, w.isVisible,
                  !self.expandedWidgets.isEmpty else { return }
            self.rebuildSettingsUI()
        }
    }

    func stopSettingsRefreshTimer() {
        settingsRefreshTimer?.invalidate()
        settingsRefreshTimer = nil
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        stopSettingsRefreshTimer()
        return false
    }
}
