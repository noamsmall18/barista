import Cocoa

/// Manages showing NSPopover dropdowns anchored to status item buttons.
/// Used by widgets that conform to InteractiveDropdown for rich content
/// (graphs, sliders, calendars) instead of plain NSMenu.
class PopoverController {
    private var popover: NSPopover?
    private var clickMonitor: Any?

    func show(content: NSView, size: NSSize, relativeTo button: NSStatusBarButton) {
        dismiss()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = size
        popover.animates = true

        let vc = NSViewController()

        // Glassmorphism background
        let wrapper = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        wrapper.material = .hudWindow
        wrapper.blendingMode = .behindWindow
        wrapper.state = .active
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 12

        // Dark tint with subtle gradient
        let tint = NSView(frame: wrapper.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]

        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = tint.bounds
        gradientLayer.colors = [
            NSColor(red: 0.04, green: 0.03, blue: 0.08, alpha: 0.55).cgColor,
            NSColor(red: 0.03, green: 0.02, blue: 0.05, alpha: 0.40).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        tint.layer?.addSublayer(gradientLayer)
        wrapper.addSubview(tint)

        // Subtle inner border
        let border = NSView(frame: wrapper.bounds)
        border.wantsLayer = true
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        border.layer?.cornerRadius = 12
        border.autoresizingMask = [.width, .height]
        wrapper.addSubview(border)

        // Content with padding
        let padded = NSView(frame: NSRect(origin: .zero, size: size))
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        padded.addSubview(content)
        padded.autoresizingMask = [.width, .height]
        wrapper.addSubview(padded)

        vc.view = wrapper
        popover.contentViewController = vc

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover

        // Click outside to dismiss
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        popover?.performClose(nil)
        popover = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    var isShown: Bool { popover?.isShown ?? false }
}
