import Cocoa

/// A status-item dropdown must be able to become key without activating the
/// accessory app (which otherwise changes Spaces or closes a transient popover).
final class StatusDropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static var spaceBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
    }

    static func placement(anchor: NSRect, size: NSSize, screen: NSRect) -> NSRect {
        let width = min(size.width, max(1, screen.width - 16))
        let height = min(size.height, max(1, screen.height - 40))
        let x = min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        let y = max(screen.minY + 8, min(anchor.minY - height - 5, screen.maxY - height - 8))
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

final class PopoverController {
    private var panel: StatusDropdownPanel?
    private var monitors: [Any] = []
    private var spaceObserver: Any?
    var onDismiss: (() -> Void)?
    var isShown: Bool { panel?.isVisible ?? false }

    func show(content: NSView, size: NSSize, relativeTo button: NSStatusBarButton) {
        dismiss()
        guard let anchorWindow = button.window else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen ?? NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
        guard let screen else { return }
        let frame = StatusDropdownPanel.placement(anchor: anchor, size: size, screen: screen.frame)
        let panel = StatusDropdownPanel(contentRect: frame,
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        panel.title = "Menu bar dropdown"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = StatusDropdownPanel.spaceBehavior
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let wrapper = NSView(frame: NSRect(origin: .zero, size: frame.size))
        wrapper.appearance = NSAppearance(named: .darkAqua)
        wrapper.wantsLayer = true
        // An opaque charcoal surface keeps text legible over bright browser windows.
        wrapper.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.105, alpha: 1).cgColor
        wrapper.layer?.cornerRadius = 12
        wrapper.layer?.masksToBounds = true
        wrapper.layer?.borderWidth = 0.5
        wrapper.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        content.frame = wrapper.bounds
        content.autoresizingMask = [.width, .height]
        wrapper.addSubview(content)
        panel.contentView = wrapper
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown, event.keyCode == 53, event.window === panel {
                self.dismiss()
                return nil
            }
            // Let nested research popovers and modal editors handle their clicks.
            if event.type != .keyDown, event.window !== panel,
               event.window?.level == .normal, NSApp.modalWindow == nil {
                self.dismiss()
            }
            return event
        }) { monitors.append(monitor) }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        panel?.orderOut(nil)
        // Closing an unreleased NSPanel can leave its content attached. Detach
        // explicitly so nested popovers and data observers end with the parent.
        panel?.contentView = nil
        panel?.close()
        panel = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        onDismiss?()
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }
}
