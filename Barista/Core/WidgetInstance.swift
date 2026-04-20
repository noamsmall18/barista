import Cocoa

class WidgetInstance {
    let id: UUID
    let widgetID: String
    var statusItem: NSStatusItem?
    var widget: AnyBaristaWidget
    var scrollView: TickerScrollView?
    private var refreshTimer: Timer?
    private var cycleTimer: Timer?
    private var clickMonitor: Any?
    private(set) var popoverController: PopoverController?
    var order: Int
    var isEnabled: Bool = true

    /// The actual measured width of this widget's status item in the menu bar
    private(set) var measuredWidth: CGFloat = 0

    init(id: UUID, widgetID: String, widget: AnyBaristaWidget, order: Int) {
        self.id = id
        self.widgetID = widgetID
        self.widget = widget
        self.order = order
    }

    func activate() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        widget.setOnDisplayUpdate { [weak self] in
            self?.updateStatusItem()
        }
        widget.start()

        // For cycleable widgets: click cycles, right-click opens menu
        if widget.isCycleable {
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Start auto-cycle timer if the widget has a cycle interval
            let interval = widget.cycleInterval
            if interval > 0 {
                cycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    guard let self = self, self.widget.itemCount > 1 else { return }
                    self.widget.cycleNext()
                    self.updateStatusItem()
                }
            }
        }

        updateStatusItem()

        // Re-measure after the window has laid out (next run loop)
        DispatchQueue.main.async { [weak self] in
            self?.measureWidth()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp ||
           event.modifierFlags.contains(.control) {
            // Right-click or Ctrl-click: show dropdown menu
            showDropdownMenu()
        } else {
            // Left-click: cycle to next item
            if widget.itemCount > 1 {
                widget.cycleNext()
                updateStatusItem()
            } else {
                // Only one item, show menu instead
                showDropdownMenu()
            }
        }
    }

    private func showDropdownMenu() {
        guard let item = statusItem, let button = item.button else { return }

        // Use NSPopover for widgets with interactive dropdowns
        if widget.hasInteractiveDropdown {
            if popoverController == nil {
                popoverController = PopoverController()
            }
            if popoverController?.isShown == true {
                popoverController?.dismiss()
                return
            }
            let content = widget.buildDropdownPopover()
            let size = widget.dropdownSize
            popoverController?.show(content: content, size: size, relativeTo: button)
            return
        }

        // Standard NSMenu dropdown
        let menu = widget.buildDropdownMenu()
        // Insert "Refresh All Widgets" before the last separator + Quit
        let quitIdx = menu.items.lastIndex(where: { $0.title == "Quit Barista" })
        if let qi = quitIdx, qi >= 1 {
            let refreshItem = NSMenuItem(title: "Refresh All Widgets", action: #selector(AppDelegate.refreshAllWidgets), keyEquivalent: "r")
            menu.insertItem(refreshItem, at: qi - 1)
        }
        item.menu = menu
        button.performClick(nil)
        // Clear menu after showing so left-click cycling works again
        DispatchQueue.main.async {
            item.menu = nil
        }
    }

    func deactivate() {
        widget.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        cycleTimer?.invalidate()
        cycleTimer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        scrollView = nil
    }

    func updateStatusItem() {
        guard let item = statusItem else { return }
        let mode = widget.render()

        // Remove old scroll view if switching modes
        if case .scrollingText = mode {} else {
            scrollView?.removeFromSuperview()
            scrollView = nil
        }

        switch mode {
        case .text(let str):
            item.button?.title = str
            item.button?.image = nil
            item.button?.imagePosition = .noImage

        case .attributedText(let attr):
            item.button?.attributedTitle = attr
            item.button?.image = nil
            item.button?.imagePosition = .noImage

        case .scrollingText(let attr, let width):
            item.length = width
            item.button?.title = ""
            item.button?.image = nil
            item.button?.imagePosition = .noImage
            if scrollView == nil, let button = item.button {
                let tv = TickerScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
                tv.autoresizingMask = [.width, .height]
                button.addSubview(tv)
                scrollView = tv
            }
            // Apply scroll speed from widget config
            if let stock = widget.underlying(as: StockTickerWidget.self) {
                scrollView?.speed = CGFloat(stock.config.scrollSpeed)
            } else if let crypto = widget.underlying(as: CryptoWidget.self) {
                scrollView?.speed = CGFloat(crypto.config.scrollSpeed)
            }
            scrollView?.updateAttributedText(attr)

        case .iconAndText(let image, let str):
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
            item.button?.title = str

        case .sparkline(let data, let label, let width):
            item.length = width
            let imgHeight: CGFloat = 16
            let imgWidth = label != nil ? width - 40 : width - 8
            let sparkImg = SparklineRenderer.render(
                data: data,
                width: imgWidth,
                style: SparklineRenderer.Style(lineColor: Theme.accent, height: imgHeight, pointRadius: 1.5)
            )
            sparkImg.isTemplate = false
            item.button?.image = sparkImg
            item.button?.imagePosition = label != nil ? .imageTrailing : .imageOnly
            item.button?.title = label ?? ""
            if let label = label {
                item.button?.attributedTitle = NSAttributedString(string: label, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: Theme.textPrimary
                ])
            }
        }

        // Measure actual width after rendering
        measureWidth()

        // Accessibility
        let accessLabel: String
        switch mode {
        case .text(let str): accessLabel = str
        case .attributedText(let attr): accessLabel = attr.string
        case .scrollingText(let attr, _): accessLabel = attr.string
        case .iconAndText(_, let str): accessLabel = str
        case .sparkline(_, let label, _): accessLabel = label ?? "sparkline"
        }

        var label = "\(widget.displayName): \(accessLabel)"
        if widget.isCycleable && widget.itemCount > 1 {
            label += " (\(widget.currentIndex + 1) of \(widget.itemCount), click to cycle)"
        }
        item.button?.setAccessibilityLabel(label)
        item.button?.setAccessibilityRole(.button)

        // For non-cycleable widgets, set the dropdown menu directly
        if !widget.isCycleable {
            let menu = widget.buildDropdownMenu()
            let quitIdx = menu.items.lastIndex(where: { $0.title == "Quit Barista" })
            if let qi = quitIdx, qi >= 1 {
                let refreshItem = NSMenuItem(title: "Refresh All Widgets", action: #selector(AppDelegate.refreshAllWidgets), keyEquivalent: "r")
                menu.insertItem(refreshItem, at: qi - 1)
            }
            item.menu = menu
        }
    }

    /// Measures the actual pixel width this status item occupies in the menu bar
    private func measureWidth() {
        guard let item = statusItem else {
            measuredWidth = 0
            return
        }

        // Use the actual window width if available - this is the true space taken
        if let window = item.button?.window, window.frame.width > 0 {
            measuredWidth = window.frame.width
            return
        }

        // Fallback: use set length for fixed-width items
        if item.length > 0 {
            measuredWidth = item.length
            return
        }

        // Fallback: measure button fitting size + padding
        if let button = item.button {
            let fitted = button.fittingSize
            measuredWidth = fitted.width + 14
        } else {
            measuredWidth = 0
        }
    }

}
