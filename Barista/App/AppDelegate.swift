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

    static let popularWidgetIDs: [String] = [
        "stock-ticker", "system-health", "today-brief", "weather-current",
        "cpu-monitor", "pomodoro", "world-clock", "battery-health", "now-playing", "calendar-next",
        "network-speed", "ram-monitor", "live-scores", "keep-awake"
    ]
    private var onboardingController: OnboardingController?
    private let quickActions = QuickActionsPanel()
    var globalHotkeyMonitor: Any?
    private var sparkleUpdater: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Marketbar has its own preferences domain, so on its first run it
        // carries the user's portfolios and history over from Barista. Reads
        // only; Barista's copy is left exactly as it was.
        FlavorMigration.importFromBaristaIfNeeded()

        // Register the widget types this flavour ships
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

        // Local hotkeys (when app is active)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Cmd+Shift+B - toggle settings
            if flags == [.command, .shift] && event.charactersIgnoringModifiers == "b" {
                if let w = self?.settingsWindow, w.isVisible {
                    w.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                    self?.stopSettingsRefreshTimer()
                } else {
                    self?.showSettingsWindow()
                }
                return nil
            }
            // Cmd+comma - open settings (standard macOS)
            if flags == .command && event.charactersIgnoringModifiers == "," {
                self?.showSettingsWindow()
                return nil
            }
            // Cmd+Shift+Space - Quick Actions
            if flags == [.command, .shift] && event.keyCode == 49 {
                self?.quickActions.toggle()
                return nil
            }
            // Cmd+W - close settings window
            if flags == .command && event.charactersIgnoringModifiers == "w" {
                if let w = self?.settingsWindow, w.isVisible {
                    w.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                    self?.stopSettingsRefreshTimer()
                    return nil
                }
            }
            return event
        }

        // Request notification permission for widget alerts
        NotificationManager.shared.requestPermission()

        // Global hotkey: Cmd+Shift+Space for Quick Actions
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 49 {
                DispatchQueue.main.async {
                    self?.quickActions.toggle()
                }
            }
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

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettingsWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quick Actions", action: #selector(showQuickActions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh All Widgets", action: #selector(refreshAllWidgets), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Export Layout...", action: #selector(exportCurrentProfile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Import Layout...", action: #selector(importProfile), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let widgetCount = statusBarController.widgetCount
        let infoItem = NSMenuItem(title: "\(widgetCount) widget\(widgetCount == 1 ? "" : "s") active", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        return menu
    }

    @objc func showQuickActions() {
        quickActions.show()
    }

    // MARK: - About Window

    @objc func showAboutWindow() {
        let aboutW: CGFloat = 320
        let aboutH: CGFloat = 280

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: NSRect(
                x: (screenFrame.width - aboutW) / 2,
                y: (screenFrame.height - aboutH) / 2,
                width: aboutW, height: aboutH
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "About Barista"
        window.isReleasedWhenClosed = true
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.hasShadow = true

        let vfx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: aboutW, height: aboutH))
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.autoresizingMask = [.width, .height]

        let tint = NSView(frame: vfx.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(red: 0.04, green: 0.03, blue: 0.06, alpha: 0.45).cgColor
        tint.autoresizingMask = [.width, .height]
        vfx.addSubview(tint)

        var y = aboutH - 50

        // App icon
        let logoSize: CGFloat = 64
        let logo = NSImageView(frame: NSRect(x: (aboutW - logoSize) / 2, y: y - logoSize, width: logoSize, height: logoSize))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            logo.image = appIcon
            logo.imageScaling = .scaleProportionallyUpOrDown
        }
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 16
        Theme.applyGlow(to: logo.layer!, color: Theme.brandAmber, radius: 12)
        vfx.addSubview(logo)
        y -= logoSize + 12

        // App name
        let nameLabel = NSTextField(labelWithString: "Barista")
        nameLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: y - 26, width: aboutW, height: 26)
        vfx.addSubview(nameLabel)
        y -= 30

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = Theme.textMuted
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: y - 18, width: aboutW, height: 18)
        vfx.addSubview(versionLabel)
        y -= 28

        // Tagline
        let tagline = NSTextField(labelWithString: "Your menu bar, your way")
        tagline.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        tagline.textColor = Theme.textFaint
        tagline.alignment = .center
        tagline.frame = NSRect(x: 0, y: y - 18, width: aboutW, height: 18)
        vfx.addSubview(tagline)
        y -= 30

        // Widget count
        let countLabel = NSTextField(labelWithString: "\(WidgetRegistry.shared.entries.count) widgets across \(WidgetCategory.allCases.count) categories")
        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Theme.textMuted
        countLabel.alignment = .center
        countLabel.frame = NSRect(x: 0, y: y - 16, width: aboutW, height: 16)
        vfx.addSubview(countLabel)

        // Copyright
        let copyright = NSTextField(labelWithString: "\u{00A9} 2026 Noam Small. All rights reserved.")
        copyright.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        copyright.textColor = Theme.textGhost
        copyright.alignment = .center
        copyright.frame = NSRect(x: 0, y: 16, width: aboutW, height: 14)
        vfx.addSubview(copyright)

        window.contentView = vfx
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding Window

    func showOnboardingWindow() {
        let controller = OnboardingController()
        controller.onFinish = { [weak self] selectedWidgets in
            guard let self = self else { return }
            UserDefaults.standard.set(true, forKey: "barista.hasLaunched")

            self.statusBarController.removeAllWidgets()
            WidgetStore.shared.save([])

            for widgetID in selectedWidgets {
                _ = self.statusBarController.addWidget(widgetID: widgetID)
            }
        }
        controller.show()
        onboardingController = controller
    }

    // MARK: - Settings Window

    @objc func showSettingsWindow() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            rebuildSettingsUI()
            startSettingsRefreshTimer()
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
        let allEntries = WidgetRegistry.shared.entries
        let galleryEntries = filteredGalleryEntries()
        let galleryCardHeight: CGFloat = 110
        let galleryRows = max(1, (galleryEntries.count + 1) / 2)
        let profileRows = max(1, (ProfileManager.presets.count + 1) / 2)

        // -- Height calculation --
        var totalHeight: CGFloat = 84 // title bar area
        totalHeight += 88 // app health strip
        if statusBarController.widgetCount >= 20 { totalHeight += 48 } // overflow warning
        totalHeight += 30 // "MY WIDGETS" header

        for instance in activeWidgets {
            totalHeight += 62 // collapsed card (52 header + 10 gap)
            if expandedWidgets.contains(instance.id) {
                totalHeight += configPanelHeight(for: instance)
            }
        }
        if activeWidgets.isEmpty { totalHeight += 130 } // empty state card

        totalHeight += 40 // divider + spacing

        // Gallery
        totalHeight += 30 // "WIDGET GALLERY" header
        totalHeight += 112 // search + category filters
        totalHeight += galleryEntries.isEmpty ? 84 : CGFloat(galleryRows) * (galleryCardHeight + 10)
        totalHeight += 20 // spacing after gallery

        totalHeight += 40 // divider + spacing
        totalHeight += 30 // "LAYOUT PRESETS" header
        totalHeight += CGFloat(profileRows) * 62 + 16

        totalHeight += 40 // divider + spacing
        totalHeight += 30 // "MENU BAR APPEARANCE" header
        totalHeight += 40 // enable toggle
        totalHeight += 60 // preset grid row 1
        totalHeight += 60 // preset grid row 2
        totalHeight += 44 // opacity slider
        totalHeight += 16 // spacing

        totalHeight += 40 // divider + spacing
        totalHeight += 30 // "APP SETTINGS" header
        totalHeight += 40 // launch at login toggle
        totalHeight += 36 // about button
        totalHeight += 34 // keyboard shortcut hint
        totalHeight += 74 // footer

        totalHeight = max(totalHeight, windowHeight)
        content.frame = NSRect(x: 0, y: 0, width: w, height: totalHeight)

        var y = totalHeight - 56

        // ============================================================
        // MARK: Title Bar
        // ============================================================
        let titleBar = NSView(frame: NSRect(x: 0, y: totalHeight - 72, width: w, height: 72))
        titleBar.wantsLayer = true

        let logoSize: CGFloat = 44
        let logoView = NSImageView(frame: NSRect(x: pad, y: 16, width: logoSize, height: logoSize))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            logoView.image = appIcon
            logoView.imageScaling = .scaleProportionallyUpOrDown
        }
        logoView.wantsLayer = true
        logoView.layer?.cornerRadius = 12
        logoView.layer?.masksToBounds = true
        logoView.shadow = NSShadow()
        logoView.layer?.shadowColor = Theme.brandAmber.withAlphaComponent(0.35).cgColor
        logoView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        logoView.layer?.shadowRadius = 14
        logoView.layer?.shadowOpacity = 1.0
        titleBar.addSubview(logoView)

        let appTitle = NSTextField(labelWithString: "Barista")
        appTitle.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        appTitle.textColor = Theme.textPrimary
        appTitle.frame = NSRect(x: pad + logoSize + 16, y: 30, width: 200, height: 30)
        titleBar.addSubview(appTitle)

        // Subtle amber accent line under the title
        let accentLine = NSView(frame: NSRect(x: pad + logoSize + 16, y: 26, width: 36, height: 2))
        accentLine.wantsLayer = true
        accentLine.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.6).cgColor
        accentLine.layer?.cornerRadius = 1
        accentLine.layer?.shadowColor = Theme.brandAmber.cgColor
        accentLine.layer?.shadowRadius = 4
        accentLine.layer?.shadowOpacity = 0.5
        accentLine.layer?.shadowOffset = .zero
        titleBar.addSubview(accentLine)

        let subtitle = NSTextField(labelWithString: "Your menu bar, your way")
        subtitle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = Theme.textMuted
        let subtitleAttr = NSMutableAttributedString(string: "Your menu bar, your way")
        subtitleAttr.addAttribute(.kern, value: 0.8, range: NSRange(location: 0, length: subtitleAttr.length))
        subtitleAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: subtitleAttr.length))
        subtitleAttr.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: subtitleAttr.length))
        subtitle.attributedStringValue = subtitleAttr
        subtitle.frame = NSRect(x: pad + logoSize + 16, y: 8, width: 220, height: 16)
        titleBar.addSubview(subtitle)

        content.addSubview(titleBar)
        y -= 32

        y = addAppHealthDashboard(to: content, at: y, width: w, pad: pad)

        // Overflow warning
        if statusBarController.widgetCount >= 20 {
            let warnH: CGFloat = 38
            let warnCard = NSView(frame: NSRect(x: pad, y: y - warnH, width: w - pad * 2, height: warnH))
            warnCard.wantsLayer = true
            warnCard.layer?.backgroundColor = Theme.red.withAlphaComponent(0.06).cgColor
            warnCard.layer?.cornerRadius = 10
            warnCard.layer?.borderWidth = 0.5
            warnCard.layer?.borderColor = Theme.red.withAlphaComponent(0.2).cgColor

            let warnLabel = NSTextField(labelWithString: "Widget limit reached (20). Remove a widget to add another.")
            warnLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            warnLabel.textColor = Theme.red
            warnLabel.frame = NSRect(x: 14, y: 11, width: warnCard.frame.width - 28, height: 16)
            warnCard.addSubview(warnLabel)

            content.addSubview(warnCard)
            y -= warnH + 10
        }

        // ============================================================
        // MARK: MY WIDGETS
        // ============================================================
        let activeLabel = makeTrackedLabel("MY WIDGETS")
        activeLabel.frame = NSRect(x: pad, y: y, width: 120, height: 14)
        content.addSubview(activeLabel)

        let countBadge = NSTextField(labelWithString: "\(activeWidgets.count)")
        countBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        countBadge.textColor = Theme.brandAmber
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.1).cgColor
        countBadge.layer?.cornerRadius = 7
        countBadge.frame = NSRect(x: pad + 104, y: y - 1, width: 22, height: 16)
        content.addSubview(countBadge)
        y -= 18

        for (i, instance) in activeWidgets.enumerated() {
            let isExpanded = expandedWidgets.contains(instance.id)
            let headerHeight: CGFloat = 52

            let card = NSView(frame: NSRect(x: pad, y: y - headerHeight, width: w - pad * 2, height: headerHeight))
            card.wantsLayer = true
            card.layer?.backgroundColor = Theme.cardBg.cgColor
            card.layer?.cornerRadius = 16
            card.layer?.borderWidth = 0.5
            card.layer?.borderColor = (isExpanded ? Theme.cardBorderHover : Theme.cardBorder).cgColor
            card.setAccessibilityLabel("\(instance.widget.displayName) widget, position \(i + 1) of \(activeWidgets.count)")

            // Subtle inner shadow / depth via top specular
            let specular = CAGradientLayer()
            specular.frame = CGRect(x: 0, y: headerHeight - 28, width: Double(w) - Double(pad) * 2, height: 28)
            specular.colors = [NSColor.white.withAlphaComponent(0.06).cgColor, NSColor.clear.cgColor]
            specular.startPoint = CGPoint(x: 0.5, y: 1)
            specular.endPoint = CGPoint(x: 0.5, y: 0)
            specular.cornerRadius = 16
            specular.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            card.layer?.addSublayer(specular)

            // Bottom inner shadow for depth
            let innerShadow = CAGradientLayer()
            innerShadow.frame = CGRect(x: 0, y: 0, width: Double(w) - Double(pad) * 2, height: 12)
            innerShadow.colors = [NSColor.black.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
            innerShadow.startPoint = CGPoint(x: 0.5, y: 0)
            innerShadow.endPoint = CGPoint(x: 0.5, y: 1)
            innerShadow.cornerRadius = 16
            innerShadow.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            card.layer?.addSublayer(innerShadow)

            if isExpanded {
                card.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                card.layer?.shadowColor = NSColor.black.cgColor
                card.layer?.shadowRadius = 16
                card.layer?.shadowOpacity = 0.45
                card.layer?.shadowOffset = CGSize(width: 0, height: -6)
            }

            // Position number - subtle pill
            let posLabel = NSTextField(labelWithString: "\(i + 1)")
            posLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
            posLabel.textColor = Theme.textGhost
            posLabel.alignment = .center
            posLabel.frame = NSRect(x: 4, y: 22, width: 14, height: 10)
            card.addSubview(posLabel)

            // Widget icon tile
            let catColor = Theme.colorForCategory(instance.widget.category)
            let iconTile = NSView(frame: NSRect(x: 18, y: 9, width: 34, height: 34))
            iconTile.wantsLayer = true
            iconTile.layer?.cornerRadius = 10
            iconTile.layer?.backgroundColor = catColor.withAlphaComponent(0.12).cgColor
            iconTile.layer?.borderWidth = 0.5
            iconTile.layer?.borderColor = catColor.withAlphaComponent(0.25).cgColor
            card.addSubview(iconTile)

            if let img = NSImage(systemSymbolName: instance.widget.iconName, accessibilityDescription: nil) {
                let iconView = NSImageView(frame: NSRect(x: 7, y: 7, width: 20, height: 20))
                iconView.image = img
                iconView.contentTintColor = catColor
                iconTile.addSubview(iconView)
            }

            // Widget name
            let nameLabel = NSTextField(labelWithString: instance.widget.displayName)
            nameLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
            nameLabel.textColor = Theme.textPrimary
            nameLabel.frame = NSRect(x: 60, y: 20, width: 180, height: 18)
            card.addSubview(nameLabel)

            // Subtitle
            let inBarLabel = NSTextField(labelWithString: "Active in menu bar")
            inBarLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            inBarLabel.textColor = Theme.textMuted
            inBarLabel.frame = NSRect(x: 60, y: 4, width: 180, height: 14)
            card.addSubview(inBarLabel)

            // Reorder buttons
            if activeWidgets.count > 1 {
                if i > 0 {
                    let upBtn = HoverButton(frame: NSRect(x: card.frame.width - 130, y: 14, width: 24, height: 24))
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
                    let downBtn = HoverButton(frame: NSRect(x: card.frame.width - 106, y: 14, width: 24, height: 24))
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

            // Configure button
            let configBtn = HoverButton(frame: NSRect(x: card.frame.width - 70, y: 14, width: 24, height: 24))
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
            if let xImg = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove") {
                removeBtn.image = xImg
                removeBtn.imagePosition = .imageOnly
            }
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
            y -= headerHeight + (isExpanded ? 0 : 10)

            // Expanded config panel
            if isExpanded {
                let panelHeight = configPanelHeight(for: instance)
                let panel = NSView(frame: NSRect(x: pad, y: y - panelHeight, width: w - pad * 2, height: panelHeight))
                panel.wantsLayer = true
                panel.layer?.backgroundColor = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.3).cgColor
                panel.layer?.cornerRadius = 16
                panel.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                panel.layer?.borderWidth = 0.5
                panel.layer?.borderColor = Theme.cardBorderHover.cgColor

                buildConfigPanel(for: instance, in: panel, width: w - pad * 2)
                content.addSubview(panel)
                y -= panelHeight + 10
            }
        }

        // Empty state
        if activeWidgets.isEmpty {
            let emptyH: CGFloat = 120
            let emptyCard = NSView(frame: NSRect(x: pad, y: y - emptyH, width: w - pad * 2, height: emptyH))
            emptyCard.wantsLayer = true
            emptyCard.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
            emptyCard.layer?.cornerRadius = 16
            emptyCard.layer?.borderWidth = 0.5
            emptyCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

            // Large icon
            if let emptyIcon = NSImage(systemSymbolName: "plus.square.dashed", accessibilityDescription: nil) {
                let iconView = NSImageView(frame: NSRect(x: (emptyCard.frame.width - 36) / 2, y: 68, width: 36, height: 36))
                iconView.image = emptyIcon
                iconView.contentTintColor = Theme.textMuted.withAlphaComponent(0.5)
                emptyCard.addSubview(iconView)
            }

            let emptyTitle = NSTextField(labelWithString: "No widgets yet")
            emptyTitle.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            emptyTitle.textColor = Theme.textPrimary
            emptyTitle.alignment = .center
            emptyTitle.frame = NSRect(x: 20, y: 40, width: emptyCard.frame.width - 40, height: 20)
            emptyCard.addSubview(emptyTitle)

            let emptySub = NSTextField(labelWithString: "Pick a widget from the gallery below to get started")
            emptySub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            emptySub.textColor = Theme.textMuted
            emptySub.alignment = .center
            emptySub.frame = NSRect(x: 20, y: 16, width: emptyCard.frame.width - 40, height: 16)
            emptyCard.addSubview(emptySub)

            content.addSubview(emptyCard)
            y -= emptyH + 10
        }

        y -= 16

        // ============================================================
        // MARK: Divider before Gallery
        // ============================================================
        let divider2 = NSView(frame: NSRect(x: pad + 20, y: y, width: w - pad * 2 - 40, height: 1))
        divider2.wantsLayer = true
        divider2.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider2)
        y -= 24

        // ============================================================
        // MARK: WIDGET GALLERY - flat grid, all widgets
        // ============================================================
        let galleryLabel = makeTrackedLabel("WIDGET GALLERY")
        galleryLabel.frame = NSRect(x: pad, y: y, width: 160, height: 14)
        content.addSubview(galleryLabel)

        let galleryCount = NSTextField(labelWithString: "\(galleryEntries.count) of \(allEntries.count)")
        galleryCount.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        galleryCount.textColor = Theme.textMuted
        galleryCount.alignment = .right
        galleryCount.frame = NSRect(x: w - pad - 80, y: y, width: 80, height: 14)
        content.addSubview(galleryCount)
        y -= 22

        y = addGalleryFilters(to: content, at: y, width: w, pad: pad)

        if galleryEntries.isEmpty {
            y = addEmptyGalleryState(to: content, at: y, width: w, pad: pad)
        } else {
            y = addGalleryGrid(entries: galleryEntries, to: content, at: y, width: w, pad: pad, cardHeight: galleryCardHeight)
        }
        y -= 12

        // ============================================================
        // MARK: Divider before Profiles
        // ============================================================
        let divider3 = NSView(frame: NSRect(x: pad + 20, y: y, width: w - pad * 2 - 40, height: 1))
        divider3.wantsLayer = true
        divider3.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider3)
        y -= 24

        // ============================================================
        // MARK: LAYOUT PRESETS
        // ============================================================
        let profilesLabel = makeTrackedLabel("LAYOUT PRESETS")
        profilesLabel.frame = NSRect(x: pad, y: y, width: 180, height: 14)
        content.addSubview(profilesLabel)

        let saveProfileBtn = HoverButton(frame: NSRect(x: w - pad - 116, y: y - 7, width: 116, height: 26))
        saveProfileBtn.wantsLayer = true
        saveProfileBtn.bezelStyle = .inline
        saveProfileBtn.isBordered = false
        saveProfileBtn.title = "Save Current"
        saveProfileBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        saveProfileBtn.contentTintColor = Theme.brandAmber
        saveProfileBtn.layer?.cornerRadius = 8
        saveProfileBtn.normalBg = Theme.brandAmber.withAlphaComponent(0.08)
        saveProfileBtn.hoverBg = Theme.brandAmber.withAlphaComponent(0.16)
        saveProfileBtn.target = self
        saveProfileBtn.action = #selector(saveCurrentProfile)
        content.addSubview(saveProfileBtn)
        y -= 28

        y = addProfilePresetGrid(to: content, at: y, width: w, pad: pad)
        y -= 12

        // ============================================================
        // MARK: Divider before Appearance
        // ============================================================
        let dividerProfiles = NSView(frame: NSRect(x: pad + 20, y: y, width: w - pad * 2 - 40, height: 1))
        dividerProfiles.wantsLayer = true
        dividerProfiles.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(dividerProfiles)
        y -= 24

        // ============================================================
        // MARK: MENU BAR APPEARANCE
        // ============================================================
        let appearanceLabel = makeTrackedLabel("MENU BAR APPEARANCE")
        appearanceLabel.frame = NSRect(x: pad, y: y, width: 200, height: 14)
        content.addSubview(appearanceLabel)
        y -= 24

        let currentAppearance = MenuBarAppearance.load()

        // Enable toggle row
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

        // Preset grid - 4 per row, larger cards
        let presets = MenuBarAppearance.presets
        let presetCardW: CGFloat = (w - pad * 2 - 18) / 4
        let presetCardH: CGFloat = 48

        for (i, (name, preset)) in presets.enumerated() {
            let col = i % 4
            let row = i / 4
            let cx = pad + CGFloat(col) * (presetCardW + 6)
            let cy = y - CGFloat(row) * (presetCardH + 10) - presetCardH

            let isActive = currentAppearance.isEnabled && currentAppearance.mode == preset.mode

            let card = NSView(frame: NSRect(x: cx, y: cy, width: presetCardW, height: presetCardH))
            card.wantsLayer = true
            card.layer?.cornerRadius = 12
            card.layer?.borderWidth = isActive ? 1.5 : 0.5
            card.layer?.borderColor = isActive ? Theme.accent.withAlphaComponent(0.7).cgColor : Theme.cardBorder.cgColor

            if isActive {
                card.layer?.shadowColor = Theme.accent.cgColor
                card.layer?.shadowRadius = 8
                card.layer?.shadowOpacity = 0.3
                card.layer?.shadowOffset = .zero
            }

            switch preset.mode {
            case .solid(let color):
                card.layer?.backgroundColor = color.nsColor.withAlphaComponent(0.6).cgColor
            case .gradient(let colors, _):
                let gradientLayer = CAGradientLayer()
                gradientLayer.frame = CGRect(x: 0, y: 0, width: presetCardW, height: presetCardH)
                gradientLayer.cornerRadius = 12
                gradientLayer.colors = colors.map { $0.nsColor.withAlphaComponent(0.7).cgColor }
                gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
                gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
                card.layer?.addSublayer(gradientLayer)
            case .dynamicGradient(let style):
                let colors = MenuBarAppearance.dynamicColors(for: style)
                let gradientLayer = CAGradientLayer()
                gradientLayer.frame = CGRect(x: 0, y: 0, width: presetCardW, height: presetCardH)
                gradientLayer.cornerRadius = 12
                gradientLayer.colors = colors.map { $0.nsColor.withAlphaComponent(0.7).cgColor }
                gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
                gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
                card.layer?.addSublayer(gradientLayer)
            case .frostedGlass:
                card.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.4).cgColor
            }

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = NSFont.systemFont(ofSize: 10, weight: isActive ? .bold : .medium)
            nameLabel.textColor = .white
            nameLabel.alignment = .center
            nameLabel.backgroundColor = .clear
            nameLabel.isBezeled = false
            nameLabel.isEditable = false
            nameLabel.frame = NSRect(x: 2, y: 6, width: presetCardW - 4, height: 14)
            nameLabel.shadow = NSShadow()
            nameLabel.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.8)
            nameLabel.shadow?.shadowBlurRadius = 4
            nameLabel.shadow?.shadowOffset = NSSize(width: 0, height: -1)
            card.addSubview(nameLabel)

            if isActive {
                let check = NSTextField(labelWithString: "\u{2713}")
                check.font = NSFont.systemFont(ofSize: 11, weight: .bold)
                check.textColor = Theme.accent
                check.backgroundColor = .clear
                check.isBezeled = false
                check.isEditable = false
                check.alignment = .center
                check.frame = NSRect(x: presetCardW - 22, y: presetCardH - 20, width: 18, height: 14)
                card.addSubview(check)
            }

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
        y -= CGFloat(presetRows) * (presetCardH + 10) + 8

        // Opacity slider
        let opacityRow = NSView(frame: NSRect(x: pad, y: y - 36, width: w - pad * 2, height: 36))
        opacityRow.wantsLayer = true
        opacityRow.layer?.backgroundColor = Theme.cardBg.cgColor
        opacityRow.layer?.cornerRadius = 10
        opacityRow.layer?.borderWidth = 0.5
        opacityRow.layer?.borderColor = Theme.cardBorder.cgColor

        let opacityLabel = NSTextField(labelWithString: "Opacity")
        opacityLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        opacityLabel.textColor = Theme.textSecondary
        opacityLabel.frame = NSRect(x: 12, y: 9, width: 60, height: 18)
        opacityRow.addSubview(opacityLabel)

        let opacitySlider = NSSlider(value: currentAppearance.opacity, minValue: 0.1, maxValue: 1.0, target: self, action: #selector(appearanceOpacityChanged(_:)))
        opacitySlider.frame = NSRect(x: 72, y: 9, width: opacityRow.frame.width - 140, height: 20)
        opacityRow.addSubview(opacitySlider)

        let opacityValue = NSTextField(labelWithString: "\(Int(currentAppearance.opacity * 100))%")
        opacityValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        opacityValue.textColor = Theme.brandAmber.withAlphaComponent(0.8)
        opacityValue.alignment = .right
        opacityValue.frame = NSRect(x: opacityRow.frame.width - 52, y: 9, width: 40, height: 18)
        opacityRow.addSubview(opacityValue)

        content.addSubview(opacityRow)
        y -= 44

        y -= 8

        // ============================================================
        // MARK: Divider before App Settings
        // ============================================================
        let divider4 = NSView(frame: NSRect(x: pad + 20, y: y, width: w - pad * 2 - 40, height: 1))
        divider4.wantsLayer = true
        divider4.layer?.backgroundColor = Theme.divider.cgColor
        content.addSubview(divider4)
        y -= 24

        // ============================================================
        // MARK: APP SETTINGS
        // ============================================================
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

        // About Barista button
        let aboutRow = NSView(frame: NSRect(x: pad, y: y - 28, width: w - pad * 2, height: 28))
        aboutRow.wantsLayer = true

        let aboutBtn = HoverButton(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
        aboutBtn.wantsLayer = true
        aboutBtn.bezelStyle = .inline
        aboutBtn.isBordered = false
        aboutBtn.title = "About Barista..."
        aboutBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        aboutBtn.contentTintColor = Theme.textSecondary
        aboutBtn.layer?.cornerRadius = 8
        aboutBtn.normalBg = .clear
        aboutBtn.hoverBg = Theme.accentBg
        aboutBtn.target = self
        aboutBtn.action = #selector(showAboutWindow)
        aboutRow.addSubview(aboutBtn)

        content.addSubview(aboutRow)
        y -= 36

        // Keyboard shortcut hints
        let shortcutLabel = NSTextField(labelWithString: "Cmd+, Settings  -  Cmd+Shift+Space Quick Actions")
        shortcutLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = Theme.textFaint.withAlphaComponent(0.72)
        shortcutLabel.alignment = .center
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.frame = NSRect(x: pad, y: y - 18, width: w - pad * 2, height: 16)
        content.addSubview(shortcutLabel)
        y -= 32

        // Footer
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let footer = NSTextField(labelWithString: "Barista v\(version)")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        footer.textColor = Theme.textMuted.withAlphaComponent(0.4)
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
            return 76 + CGFloat(quoteCount) * 56 + 52 + 190 + 34
        case "cpu-monitor": return 310
        case "ram-monitor": return 520
        case "network-speed": return 480
        case "battery-health": return 580
        case "weather-current": return 680
        case "pomodoro": return 560
        case "world-clock": return 680
        case "calendar-next": return 290
        case "now-playing": return 520
        case "live-scores": return 560
        case "keep-awake": return 520
        default:
            // Calculate height for declarative config widgets
            if let dc = instance.widget.asDeclarativeConfig() {
                let fields = dc.configFields()
                if !fields.isEmpty {
                    var h: CGFloat = 40 // header
                    for field in fields {
                        switch field {
                        case .section: h += 26
                        case .info: h += 28
                        case .toggle: h += 36
                        case .slider: h += 58
                        case .text: h += 58
                        case .picker: h += 36
                        }
                    }
                    return h + 16
                }
            }
            return 200
        }
    }

    // MARK: - Build Config Panel

    private func buildConfigPanel(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        switch instance.widgetID {
        case "stock-ticker":
            buildStockTickerConfig(for: instance, in: panel, width: width)
        case "ram-monitor":
            break // handled by DeclarativeConfig
        case "network-speed":
            break // handled by DeclarativeConfig
        case "battery-health":
            break // handled by DeclarativeConfig
        case "weather-current":
            break // handled by DeclarativeConfig
        case "pomodoro":
            break // handled by DeclarativeConfig
        case "calendar-next":
            break // handled by DeclarativeConfig
        case "now-playing":
            break // handled by DeclarativeConfig
        case "live-scores":
            break // handled by DeclarativeConfig
        case "world-clock":
            break // handled by DeclarativeConfig
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

        if let portfolio = stockWidget.portfolioSnapshot() {
            summaryCard.layer?.borderColor = Theme.borderForChange(portfolio.dailyPercent).cgColor

            let total = stockWidget.formatCurrency(portfolio.total)
            let avgLabel = NSTextField(labelWithString: String(format: "Portfolio %@  %@ (%@%.2f%%)", total, stockWidget.formatSignedCurrency(portfolio.dailyPL), portfolio.dailyPercent >= 0 ? "+" : "", portfolio.dailyPercent))
            avgLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            avgLabel.textColor = Theme.colorForChange(portfolio.dailyPercent)
            avgLabel.lineBreakMode = .byTruncatingTail
            avgLabel.frame = NSRect(x: 14, y: 16, width: cardW - 28, height: 20)
            summaryCard.addSubview(avgLabel)

            let countLabel = NSTextField(labelWithString: "\(portfolio.positions.count) positions - \(stockWidget.freshnessDescription())")
            countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = stockWidget.freshnessColor()
            countLabel.lineBreakMode = .byTruncatingTail
            countLabel.frame = NSRect(x: 14, y: 2, width: cardW - 28, height: 14)
            summaryCard.addSubview(countLabel)
        } else if let breadth = stockWidget.marketBreadth() {
            summaryCard.layer?.borderColor = Theme.borderForChange(breadth.averageChange).cgColor

            let avgLabel = NSTextField(labelWithString: String(format: "Watchlist Pulse: %@%.2f%% avg", breadth.averageChange >= 0 ? "+" : "", breadth.averageChange))
            avgLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            avgLabel.textColor = Theme.colorForChange(breadth.averageChange)
            avgLabel.frame = NSRect(x: 14, y: 16, width: cardW - 28, height: 20)
            summaryCard.addSubview(avgLabel)

            let countLabel = NSTextField(labelWithString: "\(breadth.advancing) up / \(breadth.declining) down - \(stockWidget.freshnessDescription())")
            countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            countLabel.textColor = stockWidget.freshnessColor()
            countLabel.lineBreakMode = .byTruncatingTail
            countLabel.frame = NSRect(x: 14, y: 2, width: cardW - 28, height: 14)
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
            stockCard.layer?.backgroundColor = Theme.bgForChange(q.currentChange).cgColor
            stockCard.layer?.cornerRadius = 8
            stockCard.layer?.borderWidth = 1
            stockCard.layer?.borderColor = Theme.borderForChange(q.currentChange).cgColor

            // Color accent bar on left
            let accentBar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 42))
            accentBar.wantsLayer = true
            accentBar.layer?.backgroundColor = Theme.colorForChange(q.currentChange).cgColor
            accentBar.layer?.cornerRadius = 1.5
            stockCard.addSubview(accentBar)

            // Symbol
            let symLabel = NSTextField(labelWithString: q.symbol)
            symLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            symLabel.textColor = Theme.textPrimary
            symLabel.lineBreakMode = .byTruncatingTail
            symLabel.frame = NSRect(x: 12, y: 12, width: 60, height: 18)
            stockCard.addSubview(symLabel)

            // Price
            let priceLabel = NSTextField(labelWithString: String(format: "$%.2f", q.currentPrice))
            priceLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            priceLabel.textColor = Theme.textPrimary
            priceLabel.alignment = .center
            priceLabel.lineBreakMode = .byTruncatingTail
            priceLabel.frame = NSRect(x: cardW / 2 - 50, y: 12, width: 100, height: 18)
            stockCard.addSubview(priceLabel)

            // Change pill
            let arrow = q.currentIsUp ? "\u{25B2}" : "\u{25BC}"
            let changeStr = String(format: "%@ %.2f%%", arrow, abs(q.currentChange))
            let changePill = NSView(frame: NSRect(x: cardW - 122, y: 10, width: 86, height: 22))
            changePill.wantsLayer = true
            changePill.layer?.backgroundColor = Theme.colorForChange(q.currentChange).withAlphaComponent(0.15).cgColor
            changePill.layer?.cornerRadius = 6

            let changeLabel = NSTextField(labelWithString: changeStr)
            changeLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            changeLabel.textColor = Theme.colorForChange(q.currentChange)
            changeLabel.alignment = .center
            changeLabel.lineBreakMode = .byTruncatingTail
            changeLabel.frame = NSRect(x: 4, y: 2, width: 78, height: 16)
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
        let speedSlider = NSSlider(frame: NSRect(x: inset + cardW / 2, y: y - 20, width: cardW / 2, height: 20))
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
        let colorToggle = NSSwitch(frame: NSRect(x: inset + cardW - 46, y: y - 22, width: 38, height: 20))
        colorToggle.state = stockWidget.config.coloredTicker ? .on : .off
        colorToggle.target = self
        colorToggle.action = #selector(stockColorToggled(_:))
        colorToggle.identifier = NSUserInterfaceItemIdentifier("colorToggle:\(instance.id.uuidString)")
        panel.addSubview(colorRow)
        panel.addSubview(colorToggle)
        y -= 36

        // Ticker Width slider
        let widthRow = makeSettingRow(label: "Ticker Width", y: y, inset: inset, width: cardW)
        let widthSlider = NSSlider(frame: NSRect(x: inset + cardW / 2, y: y - 20, width: cardW / 2, height: 20))
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
        let refreshPopup = NSPopUpButton(frame: NSRect(x: inset + cardW / 2, y: y - 22, width: cardW / 2, height: 24))
        refreshPopup.addItems(withTitles: ["5 sec", "10 sec", "15 sec", "30 sec", "1 min"])
        let intervals: [TimeInterval] = [5, 10, 15, 30, 60]
        if let idx = intervals.firstIndex(of: stockWidget.config.refreshInterval) {
            refreshPopup.selectItem(at: idx)
        } else {
            refreshPopup.selectItem(at: 0)
        }
        refreshPopup.target = self
        refreshPopup.action = #selector(stockRefreshChanged(_:))
        refreshPopup.identifier = NSUserInterfaceItemIdentifier("refreshPopup:\(instance.id.uuidString)")
        panel.addSubview(refreshRow)
        panel.addSubview(refreshPopup)
    }

    // CPU config panel: handled by DeclarativeConfig - no hardcoded panel needed

    // RAM config is now handled by DeclarativeConfig
    // Network Speed config is now handled by DeclarativeConfig

    // Battery config is now handled by DeclarativeConfig

    // Weather config is now handled by DeclarativeConfig

    // Pomodoro, Calendar Next, Now Playing, Live Scores, World Clock configs
    // are all handled by DeclarativeConfig

    // MARK: - Generic Config Change Handlers

    @objc func configToggleChanged(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":") // cfg:widgetID:field:uuid
        guard parts.count >= 4,
              let uuid = UUID(uuidString: String(parts[3])),
              let instance = statusBarController.instance(for: uuid) else { return }

        let widgetID = String(parts[1])

        switch widgetID {
        case "cpu-monitor":
            break // handled by DeclarativeConfig
        case "ram-monitor":
            break // handled by DeclarativeConfig
        case "network-speed":
            break // handled by DeclarativeConfig
        case "battery-health":
            break // handled by DeclarativeConfig
        case "weather-current":
            break // handled by DeclarativeConfig
        case "pomodoro":
            break // handled by DeclarativeConfig
        case "calendar-next":
            break // handled by DeclarativeConfig
        case "now-playing":
            break // handled by DeclarativeConfig
        case "world-clock":
            break // handled by DeclarativeConfig
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
            break // handled by DeclarativeConfig
        case "battery-health":
            break // handled by DeclarativeConfig
        case "pomodoro":
            break // handled by DeclarativeConfig
        case "calendar-next":
            break // handled by DeclarativeConfig
        case "now-playing":
            break // handled by DeclarativeConfig
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
            break // handled by DeclarativeConfig
        case "ram-monitor":
            break // handled by DeclarativeConfig
        case "now-playing":
            break // handled by DeclarativeConfig
        case "live-scores":
            break // handled by DeclarativeConfig
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

        switch widgetID {
        case "weather-current":
            break // handled by DeclarativeConfig
        case "world-clock":
            break // handled by DeclarativeConfig
        default: break
        }

        saveWidgetConfig(instance: instance)
        instance.updateStatusItem()
    }

    // MARK: - Generic Config Panel

    private func buildGenericConfig(for instance: WidgetInstance, in panel: NSView, width: CGFloat) {
        // Try declarative config first
        if let dc = instance.widget.asDeclarativeConfig() {
            let fields = dc.configFields()
            if !fields.isEmpty {
                buildDeclarativeConfig(fields: fields, instance: instance, panel: panel, width: width)
                return
            }
        }

        // Fall back to legacy buildConfigControls
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

    // MARK: - Declarative Config Builder

    private func buildDeclarativeConfig(fields: [ConfigField], instance: WidgetInstance, panel: NSView, width: CGFloat) {
        let inset: CGFloat = 16
        let cardW = width - inset * 2
        var y = panel.frame.height - 16

        makeSettingsHeader(y: &y, inset: inset, panel: panel)

        for field in fields {
            switch field {
            case .section(let title):
                y -= 4
                let attr = NSMutableAttributedString(string: title.uppercased())
                attr.addAttribute(.kern, value: 1.2, range: NSRange(location: 0, length: attr.length))
                attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .bold), range: NSRange(location: 0, length: attr.length))
                attr.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: attr.length))
                let label = NSTextField(labelWithString: "")
                label.attributedStringValue = attr
                label.frame = NSRect(x: inset, y: y - 14, width: cardW, height: 14)
                panel.addSubview(label)
                y -= 22

            case .info(let label, let value):
                let lbl = NSTextField(labelWithString: label)
                lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                lbl.textColor = Theme.textMuted
                lbl.frame = NSRect(x: inset, y: y - 18, width: cardW / 2, height: 16)
                panel.addSubview(lbl)

                let val = NSTextField(labelWithString: value())
                val.font = NSFont.systemFont(ofSize: 12, weight: .bold)
                val.textColor = Theme.textPrimary
                val.alignment = .right
                val.frame = NSRect(x: inset + cardW / 2, y: y - 18, width: cardW / 2, height: 16)
                panel.addSubview(val)
                y -= 28

            case .toggle(let label, _, let get, let set):
                let lbl = makeSettingRow(label: label, y: y, inset: inset, width: cardW)
                panel.addSubview(lbl)

                let toggle = NSSwitch(frame: NSRect(x: inset + cardW - 46, y: y - 22, width: 38, height: 20))
                toggle.state = get() ? .on : .off
                let handler = DeclToggleHandler(set: set, instance: instance, delegate: self)
                toggle.target = handler
                toggle.action = #selector(DeclToggleHandler.toggled(_:))
                objc_setAssociatedObject(toggle, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
                panel.addSubview(toggle)
                y -= 36

            case .slider(let label, _, let min, let max, let step, let get, let set, let format):
                let lbl = makeSettingRow(label: label, y: y, inset: inset, width: cardW)
                panel.addSubview(lbl)

                let current = get()
                let displayFormat = format ?? (step >= 1 ? "%.0f" : "%.1f")
                let valLabel = NSTextField(labelWithString: String(format: displayFormat, current))
                valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
                valLabel.textColor = Theme.accent
                valLabel.alignment = .right
                valLabel.frame = NSRect(x: inset + cardW - 64, y: y - 18, width: 64, height: 16)
                panel.addSubview(valLabel)
                y -= 28

                let slider = NSSlider(value: current, minValue: min, maxValue: max, target: nil, action: nil)
                slider.frame = NSRect(x: inset, y: y - 20, width: cardW, height: 20)
                slider.numberOfTickMarks = step >= 1 ? Int((max - min) / step) + 1 : 0
                slider.allowsTickMarkValuesOnly = step >= 1
                let sliderHandler = DeclSliderHandler(set: set, valLabel: valLabel, format: displayFormat, step: step, instance: instance, delegate: self)
                slider.target = sliderHandler
                slider.action = #selector(DeclSliderHandler.slid(_:))
                objc_setAssociatedObject(slider, "handler", sliderHandler, .OBJC_ASSOCIATION_RETAIN)
                panel.addSubview(slider)
                y -= 30

            case .text(let label, _, let placeholder, let get, let set):
                let lbl = makeSettingRow(label: label, y: y, inset: inset, width: cardW)
                panel.addSubview(lbl)
                y -= 26

                let field = NSTextField(string: get())
                field.font = NSFont.systemFont(ofSize: 12)
                field.placeholderString = placeholder
                field.frame = NSRect(x: inset, y: y - 24, width: cardW, height: 22)
                field.wantsLayer = true
                field.layer?.cornerRadius = 6
                let textHandler = DeclTextHandler(set: set, instance: instance, delegate: self)
                field.delegate = textHandler
                objc_setAssociatedObject(field, "handler", textHandler, .OBJC_ASSOCIATION_RETAIN)
                panel.addSubview(field)
                y -= 32

            case .picker(let label, _, let options, let get, let set):
                let lbl = makeSettingRow(label: label, y: y, inset: inset, width: cardW)
                panel.addSubview(lbl)

                let popup = NSPopUpButton(frame: NSRect(x: inset + cardW / 2, y: y - 24, width: cardW / 2, height: 24))
                popup.font = NSFont.systemFont(ofSize: 12)
                let currentVal = get()
                for (i, opt) in options.enumerated() {
                    popup.addItem(withTitle: opt.title)
                    if opt.value == currentVal {
                        popup.selectItem(at: i)
                    }
                }
                let pickerHandler = DeclPickerHandler(options: options, set: set, instance: instance, delegate: self)
                popup.target = pickerHandler
                popup.action = #selector(DeclPickerHandler.picked(_:))
                objc_setAssociatedObject(popup, "handler", pickerHandler, .OBJC_ASSOCIATION_RETAIN)
                panel.addSubview(popup)
                y -= 36
            }
        }
    }


    private func makeSettingRow(label: String, y: CGFloat, inset: CGFloat, width: CGFloat) -> NSTextField {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = Theme.textSecondary
        lbl.lineBreakMode = .byTruncatingTail
        lbl.frame = NSRect(x: inset, y: y - 20, width: width / 2, height: 18)
        return lbl
    }

    private func addAppHealthDashboard(to content: NSView, at y: CGFloat, width w: CGFloat, pad: CGFloat) -> CGFloat {
        var y = y
        let cardH: CGFloat = 76
        let card = NSView(frame: NSRect(x: pad, y: y - cardH, width: w - pad * 2, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor

        let active = statusBarController.activeInstances
        let activeCategories = Set(active.map { $0.widget.category }).count
        let capacity = max(0, 20 - active.count)
        let stockFreshness = active
            .compactMap { $0.widget.underlying(as: StockTickerWidget.self)?.freshnessDescription() }
            .first ?? "No market widget"
        let appearance = MenuBarAppearance.load().isEnabled ? "Styled" : "Default"

        let metrics: [(String, String, String, NSColor)] = [
            ("Widgets", "\(active.count)/20", "\(capacity) slots open", Theme.brandAmber),
            ("Categories", "\(activeCategories)", "active groups", Theme.brandCyan),
            ("Market", stockFreshness, "ticker state", Theme.green),
            ("Menu Bar", appearance, "appearance", Theme.purple),
        ]

        let colW = (card.frame.width - 24) / CGFloat(metrics.count)
        for (i, metric) in metrics.enumerated() {
            let x = 12 + CGFloat(i) * colW
            if i > 0 {
                let divider = NSView(frame: NSRect(x: x - 6, y: 14, width: 1, height: cardH - 28))
                divider.wantsLayer = true
                divider.layer?.backgroundColor = Theme.divider.cgColor
                card.addSubview(divider)
            }

            if let img = NSImage(systemSymbolName: metric.0 == "Market" ? "chart.line.uptrend.xyaxis" : metric.0 == "Menu Bar" ? "menubar.rectangle" : metric.0 == "Categories" ? "square.grid.2x2" : "slider.horizontal.3", accessibilityDescription: nil) {
                let icon = NSImageView(frame: NSRect(x: x, y: 45, width: 16, height: 16))
                icon.image = img
                icon.contentTintColor = metric.3
                card.addSubview(icon)
            }

            let label = NSTextField(labelWithString: metric.0.uppercased())
            label.font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: x + 22, y: 47, width: colW - 28, height: 12)
            card.addSubview(label)

            let value = NSTextField(labelWithString: metric.1)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: metric.1.count > 14 ? 10 : 15, weight: .bold)
            value.textColor = metric.3
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: x, y: 23, width: colW - 12, height: 18)
            card.addSubview(value)

            let detail = NSTextField(labelWithString: metric.2)
            detail.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            detail.textColor = Theme.textFaint
            detail.frame = NSRect(x: x, y: 8, width: colW - 12, height: 12)
            card.addSubview(detail)
        }

        content.addSubview(card)
        y -= cardH + 14
        return y
    }

    private func addGalleryFilters(to content: NSView, at y: CGFloat, width w: CGFloat, pad: CGFloat) -> CGFloat {
        var y = y
        let searchH: CGFloat = 34
        let searchCard = NSView(frame: NSRect(x: pad, y: y - searchH, width: w - pad * 2, height: searchH))
        searchCard.wantsLayer = true
        searchCard.layer?.backgroundColor = Theme.sunkenBg.cgColor
        searchCard.layer?.cornerRadius = 10
        searchCard.layer?.borderWidth = 0.5
        searchCard.layer?.borderColor = Theme.inputBorder.cgColor

        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            let icon = NSImageView(frame: NSRect(x: 10, y: 9, width: 15, height: 15))
            icon.image = img
            icon.contentTintColor = Theme.textFaint
            searchCard.addSubview(icon)
        }

        let field = NSTextField(frame: NSRect(x: 32, y: 5, width: searchCard.frame.width - 44, height: 24))
        field.identifier = NSUserInterfaceItemIdentifier("gallerySearch")
        field.stringValue = gallerySearchText
        field.placeholderAttributedString = NSAttributedString(
            string: "Find a widget...",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.textFaint]
        )
        field.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        field.textColor = Theme.textPrimary
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(gallerySearchChanged(_:))
        searchCard.addSubview(field)

        content.addSubview(searchCard)
        y -= searchH + 10

        let categories = WidgetCategory.allCases.filter { category in
            WidgetRegistry.shared.entries.contains { $0.category == category }
        }
        var x = pad
        var rowY = y - 26
        let maxX = w - pad
        let pillFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let allPill = makeCategoryPill(title: "All", identifier: "cat:all", isSelected: gallerySelectedCategory == nil, font: pillFont)
        allPill.frame = NSRect(x: x, y: rowY, width: 48, height: 26)
        content.addSubview(allPill)
        x += 56

        for category in categories {
            let title = category.rawValue
            let textWidth = (title as NSString).size(withAttributes: [.font: pillFont]).width
            let pillW = max(58, min(128, textWidth + 24))
            if x + pillW > maxX {
                x = pad
                rowY -= 32
            }
            let pill = makeCategoryPill(
                title: title,
                identifier: "cat:\(title)",
                isSelected: gallerySelectedCategory == category,
                font: pillFont
            )
            pill.frame = NSRect(x: x, y: rowY, width: pillW, height: 26)
            content.addSubview(pill)
            x += pillW + 8
        }

        return rowY - 36
    }

    private func addEmptyGalleryState(to content: NSView, at y: CGFloat, width w: CGFloat, pad: CGFloat) -> CGFloat {
        var y = y
        let h: CGFloat = 72
        let card = NSView(frame: NSRect(x: pad, y: y - h, width: w - pad * 2, height: h))
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor

        let label = NSTextField(labelWithString: "No matching widgets")
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = Theme.textPrimary
        label.alignment = .center
        label.frame = NSRect(x: 12, y: 38, width: card.frame.width - 24, height: 18)
        card.addSubview(label)

        let detail = NSTextField(labelWithString: "Clear the search or pick another category.")
        detail.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detail.textColor = Theme.textMuted
        detail.alignment = .center
        detail.frame = NSRect(x: 12, y: 18, width: card.frame.width - 24, height: 14)
        card.addSubview(detail)

        content.addSubview(card)
        y -= h + 8
        return y
    }

    private func addProfilePresetGrid(to content: NSView, at y: CGFloat, width w: CGFloat, pad: CGFloat) -> CGFloat {
        var y = y
        let gap: CGFloat = 10
        let cardH: CGFloat = 54
        let cardW = (w - pad * 2 - gap) / 2
        let presets = ProfileManager.presets

        for i in stride(from: 0, to: presets.count, by: 2) {
            for col in 0...1 {
                let idx = i + col
                guard idx < presets.count else { break }
                let preset = presets[idx]
                let x = pad + CGFloat(col) * (cardW + gap)
                let card = NSView(frame: NSRect(x: x, y: y - cardH, width: cardW, height: cardH))
                card.wantsLayer = true
                card.layer?.backgroundColor = Theme.cardBg.cgColor
                card.layer?.cornerRadius = 14
                card.layer?.borderWidth = 0.5
                card.layer?.borderColor = Theme.cardBorder.cgColor

                let color = Theme.colorForCategory(WidgetRegistry.shared.entry(for: preset.widgetIDs.first ?? "")?.category ?? .utility)
                if let img = NSImage(systemSymbolName: preset.icon, accessibilityDescription: nil) {
                    let icon = NSImageView(frame: NSRect(x: 12, y: 18, width: 20, height: 20))
                    icon.image = img
                    icon.contentTintColor = color
                    card.addSubview(icon)
                }

                let title = NSTextField(labelWithString: preset.name)
                title.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                title.textColor = Theme.textPrimary
                title.frame = NSRect(x: 42, y: 28, width: cardW - 52, height: 16)
                card.addSubview(title)

                let validCount = preset.widgetIDs.filter { WidgetRegistry.shared.entry(for: $0) != nil }.count
                let detail = NSTextField(labelWithString: "\(validCount) widgets")
                detail.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                detail.textColor = Theme.textMuted
                detail.frame = NSRect(x: 42, y: 12, width: cardW - 52, height: 12)
                card.addSubview(detail)

                let btn = NSButton(frame: card.bounds)
                btn.isBordered = false
                btn.isTransparent = true
                btn.target = self
                btn.action = #selector(activateProfile(_:))
                btn.tag = idx
                card.addSubview(btn)
                content.addSubview(card)
            }
            y -= cardH + gap
        }

        return y
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


    private func addGallerySectionHeader(title: String, icon: String, count: Int, to content: NSView, at y: CGFloat, width w: CGFloat, pad: CGFloat) -> CGFloat {
        var y = y
        let header = NSView(frame: NSRect(x: pad, y: y - 20, width: w - pad * 2, height: 20))

        if let sfImg = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iconView = NSImageView(frame: NSRect(x: 0, y: 2, width: 14, height: 14))
            iconView.image = sfImg
            iconView.contentTintColor = Theme.textFaint
            header.addSubview(iconView)
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = Theme.textFaint
        let titleAttr = NSMutableAttributedString(string: title)
        titleAttr.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: titleAttr.length))
        titleAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .semibold), range: NSRange(location: 0, length: titleAttr.length))
        titleAttr.addAttribute(.foregroundColor, value: Theme.textFaint, range: NSRange(location: 0, length: titleAttr.length))
        titleLabel.attributedStringValue = titleAttr
        titleLabel.frame = NSRect(x: 18, y: 2, width: 200, height: 14)
        header.addSubview(titleLabel)

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        countLabel.textColor = Theme.textGhost
        countLabel.frame = NSRect(x: w - pad * 2 - 24, y: 2, width: 20, height: 14)
        countLabel.alignment = .right
        header.addSubview(countLabel)

        content.addSubview(header)
        y -= 28
        return y
    }

    /// Lay out entries as a 2-column grid of gallery cards.
    private func addGalleryGrid(entries: [WidgetRegistryEntry], to content: NSView, at y: CGFloat, width w: CGFloat, pad: CGFloat, cardHeight: CGFloat) -> CGFloat {
        var y = y
        let gap: CGFloat = 10
        let cardW = (w - pad * 2 - gap) / 2

        for i in stride(from: 0, to: entries.count, by: 2) {
            for col in 0...1 {
                let idx = i + col
                guard idx < entries.count else { break }
                let entry = entries[idx]
                let cx = pad + CGFloat(col) * (cardW + gap)
                addGalleryCard(entry: entry, to: content, at: NSPoint(x: cx, y: y - cardHeight), width: cardW, cardHeight: cardHeight)
            }
            y -= cardHeight + gap
        }
        return y
    }

    private func addGalleryCard(entry: WidgetRegistryEntry, to content: NSView, at origin: NSPoint, width cardW: CGFloat, cardHeight: CGFloat) {
        let activeWidgets = statusBarController.activeInstances
        let isActive = activeWidgets.contains { $0.widgetID == entry.widgetID }
        let canAdd = entry.allowsMultiple || !isActive
        let catColor = Theme.colorForCategory(entry.category)

        let card = NSView(frame: NSRect(origin: origin, size: NSSize(width: cardW, height: cardHeight)))
        card.wantsLayer = true
        card.layer?.backgroundColor = isActive ? Theme.green.withAlphaComponent(0.04).cgColor : Theme.cardBg.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = isActive ? 1 : 0.5
        card.layer?.borderColor = isActive ? Theme.green.withAlphaComponent(0.25).cgColor : Theme.cardBorder.cgColor

        // Top specular for depth
        let specular = CAGradientLayer()
        specular.frame = CGRect(x: 0, y: cardHeight - 24, width: Double(cardW), height: 24)
        specular.colors = [NSColor.white.withAlphaComponent(0.05).cgColor, NSColor.clear.cgColor]
        specular.startPoint = CGPoint(x: 0.5, y: 1)
        specular.endPoint = CGPoint(x: 0.5, y: 0)
        specular.cornerRadius = 16
        specular.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        card.layer?.addSublayer(specular)

        // Larger icon tile
        let tileSize: CGFloat = 38
        let gIconTile = NSView(frame: NSRect(x: 12, y: cardHeight - tileSize - 12, width: tileSize, height: tileSize))
        gIconTile.wantsLayer = true
        gIconTile.layer?.cornerRadius = 11
        gIconTile.layer?.backgroundColor = catColor.withAlphaComponent(0.14).cgColor
        gIconTile.layer?.borderWidth = 0.5
        gIconTile.layer?.borderColor = catColor.withAlphaComponent(0.25).cgColor
        // Icon glow
        gIconTile.layer?.shadowColor = catColor.cgColor
        gIconTile.layer?.shadowRadius = 6
        gIconTile.layer?.shadowOpacity = 0.15
        gIconTile.layer?.shadowOffset = .zero
        card.addSubview(gIconTile)

        if let img = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: nil) {
            let iconView = NSImageView(frame: NSRect(x: 7, y: 7, width: 24, height: 24))
            iconView.image = img
            iconView.contentTintColor = catColor
            gIconTile.addSubview(iconView)
        }

        // Name - right of icon
        let nameLabel = NSTextField(labelWithString: entry.displayName)
        nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        nameLabel.textColor = Theme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: tileSize + 20, y: cardHeight - 24, width: cardW - tileSize - 28, height: 16)
        card.addSubview(nameLabel)

        // Subtitle
        let subLabel = NSTextField(labelWithString: entry.subtitle)
        subLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        subLabel.textColor = Theme.textMuted
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.frame = NSRect(x: tileSize + 20, y: cardHeight - 40, width: cardW - tileSize - 28, height: 14)
        card.addSubview(subLabel)

        // Category badge
        let catBadge = NSTextField(labelWithString: entry.category.rawValue)
        catBadge.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        catBadge.textColor = catColor.withAlphaComponent(0.8)
        catBadge.wantsLayer = true
        catBadge.layer?.backgroundColor = catColor.withAlphaComponent(0.08).cgColor
        catBadge.layer?.cornerRadius = 4
        catBadge.layer?.borderWidth = 0.5
        catBadge.layer?.borderColor = catColor.withAlphaComponent(0.15).cgColor
        catBadge.alignment = .center
        catBadge.isBezeled = false
        catBadge.isEditable = false
        catBadge.backgroundColor = .clear
        let catTextWidth = (entry.category.rawValue as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .medium)]).width + 12
        catBadge.frame = NSRect(x: tileSize + 20, y: cardHeight - 54, width: catTextWidth, height: 14)
        card.addSubview(catBadge)

        // Add / Active indicator at bottom
        let hasRoom = statusBarController.widgetCount < 20
        if canAdd && hasRoom {
            let addBtn = HoverButton(frame: NSRect(x: 12, y: 4, width: cardW - 24, height: 24))
            addBtn.wantsLayer = true
            addBtn.bezelStyle = .inline
            addBtn.isBordered = false
            addBtn.title = "+ Add"
            addBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            addBtn.contentTintColor = Theme.accent
            addBtn.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.08).cgColor
            addBtn.layer?.cornerRadius = 8
            addBtn.layer?.borderWidth = 0.5
            addBtn.layer?.borderColor = Theme.accent.withAlphaComponent(0.2).cgColor
            addBtn.normalBg = Theme.accent.withAlphaComponent(0.08)
            addBtn.hoverBg = Theme.accent.withAlphaComponent(0.2)
            addBtn.target = self
            addBtn.action = #selector(addWidgetAction(_:))
            addBtn.identifier = NSUserInterfaceItemIdentifier(entry.widgetID)
            addBtn.setAccessibilityLabel("Add \(entry.displayName) widget")
            card.addSubview(addBtn)
        } else if !canAdd {
            let badgeBg = NSView(frame: NSRect(x: 12, y: 4, width: cardW - 24, height: 24))
            badgeBg.wantsLayer = true
            badgeBg.layer?.backgroundColor = Theme.green.withAlphaComponent(0.06).cgColor
            badgeBg.layer?.cornerRadius = 8

            let badge = NSTextField(labelWithString: "\u{2713} Active")
            badge.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            badge.textColor = Theme.green
            badge.alignment = .center
            badge.frame = NSRect(x: 0, y: 4, width: cardW - 24, height: 14)
            badgeBg.addSubview(badge)
            card.addSubview(badgeBg)
        } else {
            let badge = NSTextField(labelWithString: "Menu bar full")
            badge.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            badge.textColor = Theme.red
            badge.alignment = .center
            badge.frame = NSRect(x: 12, y: 8, width: cardW - 24, height: 14)
            card.addSubview(badge)
        }

        content.addSubview(card)
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
        stockWidget.removeQuote(symbol, kind: .stock)
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
        let intervals: [TimeInterval] = [5, 10, 15, 30, 60]
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
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config)
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

    func activateProfilePreset(at index: Int) {
        let presets = ProfileManager.presets
        guard index >= 0 && index < presets.count else { return }
        let preset = presets[index]

        let mgr = ProfileManager.shared
        let existing = mgr.profiles.first { $0.name == preset.name }
        let profile: WidgetProfile
        if let existing = existing {
            profile = existing
        } else {
            profile = mgr.createPreset(name: preset.name, icon: preset.icon, widgetIDs: preset.widgetIDs)
        }

        mgr.activate(id: profile.id)
        expandedWidgets.removeAll()
        statusBarController.removeAllWidgets()
        statusBarController.syncMenuBar()
        rebuildSettingsUI()
    }

    @objc func activateProfile(_ sender: NSButton) {
        activateProfilePreset(at: sender.tag)
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

    @objc func exportCurrentProfile() {
        ProfileExporter.exportCurrent(name: "My Barista Layout")
    }

    @objc func importProfile() {
        ProfileExporter.importProfile()
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
