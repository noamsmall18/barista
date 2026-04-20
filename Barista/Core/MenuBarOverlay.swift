import Cocoa

/// Manages a transparent overlay window positioned over the menu bar
/// to apply custom colors, gradients, and effects.
class MenuBarOverlay {
    static let shared = MenuBarOverlay()

    private var overlayWindows: [NSScreen: NSWindow] = [:]
    private var dynamicTimer: Timer?
    private var appearance: MenuBarAppearance = .default
    private var screenObserver: Any?
    private var spaceObserver: Any?
    private var fullscreenObserver: Any?

    private init() {}

    // MARK: - Public API

    func apply(_ appearance: MenuBarAppearance) {
        self.appearance = appearance
        if appearance.isEnabled {
            createOverlays()
            startObserving()
        } else {
            removeAll()
            stopObserving()
        }
    }

    func removeAll() {
        for (_, window) in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        dynamicTimer?.invalidate()
        dynamicTimer = nil
    }

    func refresh() {
        guard appearance.isEnabled else { return }
        for (screen, window) in overlayWindows {
            positionWindow(window, on: screen)
            renderAppearance(in: window)
        }
    }

    // MARK: - Window Management

    private func createOverlays() {
        // Remove stale windows for disconnected screens
        let currentScreens = Set(NSScreen.screens)
        for (screen, window) in overlayWindows {
            if !currentScreens.contains(screen) {
                window.orderOut(nil)
                overlayWindows.removeValue(forKey: screen)
            }
        }

        // Create or update windows for each screen
        for screen in NSScreen.screens {
            if let existing = overlayWindows[screen] {
                positionWindow(existing, on: screen)
                renderAppearance(in: existing)
            } else {
                let window = createOverlayWindow(for: screen)
                overlayWindows[screen] = window
                renderAppearance(in: window)
                window.orderFrontRegardless()
            }
        }

        // Start dynamic timer if needed
        if case .dynamicGradient = appearance.mode {
            startDynamicTimer()
        } else {
            dynamicTimer?.invalidate()
            dynamicTimer = nil
        }
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y + screen.frame.origin.y
        let height = max(menuBarHeight, 24)

        let window = NSWindow(
            contentRect: NSRect(
                x: screen.frame.origin.x,
                y: screen.frame.origin.y + screen.frame.height - height,
                width: screen.frame.width,
                height: height
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        return window
    }

    private func positionWindow(_ window: NSWindow, on screen: NSScreen) {
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y + screen.frame.origin.y
        let height = max(menuBarHeight, 24)

        window.setFrame(
            NSRect(
                x: screen.frame.origin.x,
                y: screen.frame.origin.y + screen.frame.height - height,
                width: screen.frame.width,
                height: height
            ),
            display: true
        )
    }

    // MARK: - Rendering

    private func renderAppearance(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let bounds = contentView.bounds
        let opacity = CGFloat(appearance.opacity)

        switch appearance.mode {
        case .solid(let color):
            contentView.layer?.backgroundColor = color.nsColor.withAlphaComponent(opacity).cgColor

        case .gradient(let colors, let angle):
            let gradientLayer = CAGradientLayer()
            gradientLayer.frame = bounds
            gradientLayer.colors = colors.map { $0.nsColor.withAlphaComponent(opacity).cgColor }

            // Convert angle to start/end points
            let radians = angle * .pi / 180.0
            let dx = cos(radians)
            let dy = sin(radians)
            gradientLayer.startPoint = CGPoint(
                x: 0.5 - dx * 0.5,
                y: 0.5 - dy * 0.5
            )
            gradientLayer.endPoint = CGPoint(
                x: 0.5 + dx * 0.5,
                y: 0.5 + dy * 0.5
            )

            contentView.layer?.addSublayer(gradientLayer)

        case .dynamicGradient(let style):
            let colors = MenuBarAppearance.dynamicColors(for: style)
            let gradientLayer = CAGradientLayer()
            gradientLayer.frame = bounds
            gradientLayer.colors = colors.map { $0.nsColor.withAlphaComponent(opacity).cgColor }
            gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
            gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
            contentView.layer?.addSublayer(gradientLayer)

        case .frostedGlass(let tintColor):
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            contentView.addSubview(effect)

            let tint = NSView(frame: bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = tintColor.nsColor.withAlphaComponent(opacity * CGFloat(tintColor.alpha)).cgColor
            tint.autoresizingMask = [.width, .height]
            contentView.addSubview(tint)
        }
    }

    // MARK: - Dynamic Updates

    private func startDynamicTimer() {
        dynamicTimer?.invalidate()
        dynamicTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Observing

    private func startObserving() {
        stopObserving()

        // Screen configuration changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.createOverlays()
        }

        // Space changes (fullscreen apps)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Brief delay to let the space transition complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.handleSpaceChange()
            }
        }
    }

    private func stopObserving() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
    }

    private func handleSpaceChange() {
        // Check if any window is fullscreen - if so, hide overlay on that screen
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        var fullscreenScreens: Set<CGDirectDisplayID> = []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            // Check if window covers entire screen
            for screen in NSScreen.screens {
                let screenFrame = screen.frame
                if let w = boundsDict["Width"], let h = boundsDict["Height"],
                   w >= screenFrame.width && h >= screenFrame.height {
                    if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                        fullscreenScreens.insert(displayID)
                    }
                }
            }
        }

        // Show/hide overlays based on fullscreen state
        for (screen, window) in overlayWindows {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if fullscreenScreens.contains(displayID) {
                    window.orderOut(nil)
                } else {
                    window.orderFrontRegardless()
                }
            }
        }
    }
}
