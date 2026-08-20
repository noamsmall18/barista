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

    private var configObserver: NSObjectProtocol?

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

        // Listen for config changes from interactive dropdowns (popovers)
        configObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BaristaWidgetConfigChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, let obj = note.object as AnyObject?,
                  self.widget.isUnderlyingIdentical(to: obj) else { return }
            if let data = self.widget.getConfigData() {
                WidgetStore.shared.updateConfig(instanceID: self.id, configData: data)
            }
        }

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
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp ||
           event.modifierFlags.contains(.control) {
            // Right-click or Ctrl-click: show dropdown menu
            showDropdownMenu()
        } else if widget.hasInteractiveDropdown {
            if event.modifierFlags.contains(.option), widget.itemCount > 1 {
                widget.cycleNext()
                updateStatusItem()
                return
            }
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
                // Anything that happened while the dropdown was open - an edit,
                // a price refresh - is drawn the moment it closes, instead of
                // waiting for the next poll.
                popoverController?.onDismiss = { [weak self] in
                    guard let self, self.pendingRedraw.take() else { return }
                    self.updateStatusItem()
                }
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
        if let obs = configObserver { NotificationCenter.default.removeObserver(obs) }
        configObserver = nil
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

    private var pendingRedraw = DeferredRedraw()

    func updateStatusItem() {
        guard let item = statusItem else { return }

        // While the popover is open it is anchored to this status-item button.
        // Mutating the button (length/title/subviews) here dismisses a transient
        // NSPopover, so a periodic data refresh would make the popover vanish.
        // The redraw is therefore deferred rather than dropped: onDismiss
        // performs it the instant the popover closes. Dropping it meant an edit
        // made in the dropdown waited for the next poll, which is five minutes
        // when the market is closed.
        if popoverController?.isShown == true {
            pendingRedraw.request()
            return
        }

        let mode = widget.render()

        // Remove old scroll view if switching away from scrolling mode
        if case .scrollingText = mode {} else {
            scrollView?.removeFromSuperview()
            scrollView = nil
        }

        switch mode {
        case .text(let str):
            item.length = NSStatusItem.variableLength
            item.button?.title = str
            item.button?.image = nil
            item.button?.imagePosition = .noImage

        case .attributedText(let attr):
            item.length = NSStatusItem.variableLength
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
            } else if let sv = scrollView, abs(sv.frame.width - width) > 1 {
                // Width changed (e.g., switching between normal and compact scroll)
                sv.frame = NSRect(x: 0, y: 0, width: width, height: 22)
            }
            // Apply scroll speed from widget config
            if let stock = widget.underlying(as: StockTickerWidget.self) {
                scrollView?.speed = CGFloat(stock.config.scrollSpeed)
            }
            scrollView?.updateAttributedText(attr)

        case .iconAndText(let image, let str):
            item.length = NSStatusItem.variableLength
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
            item.button?.title = str

        case .sparkline(let data, let label, let width):
            item.length = width
            let imgHeight: CGFloat = 16
            let imgWidth = label != nil ? width - 40 : width - 8
            let style: SparklineRenderer.Style
            if let stock = widget.underlying(as: StockTickerWidget.self),
               let quote = stock.chartQuoteForCurrentFocus() {
                style = stock.chartStyle(for: quote, height: imgHeight, pointRadius: 1.6, showGrid: false)
            } else {
                style = SparklineRenderer.Style(lineColor: Theme.accent, height: imgHeight, pointRadius: 1.5)
            }
            let sparkImg = SparklineRenderer.render(
                data: data,
                width: imgWidth,
                style: style
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
        if widget.hasInteractiveDropdown {
            label += widget.itemCount > 1 ? " (\(widget.currentIndex + 1) of \(widget.itemCount), click to open, option-click to cycle)" : " (click to open)"
        } else if widget.isCycleable && widget.itemCount > 1 {
            label += " (\(widget.currentIndex + 1) of \(widget.itemCount), click to cycle)"
        }
        item.button?.setAccessibilityLabel(label)
        item.button?.setAccessibilityRole(.button)

        // For non-cycleable widgets, set the dropdown menu directly
        // (but not for interactive dropdown widgets - they use the popover via click handler)
        if !widget.isCycleable && !widget.hasInteractiveDropdown {
            let menu = widget.buildDropdownMenu()
            let quitIdx = menu.items.lastIndex(where: { $0.title == "Quit Barista" })
            if let qi = quitIdx, qi >= 1 {
                let refreshItem = NSMenuItem(title: "Refresh All Widgets", action: #selector(AppDelegate.refreshAllWidgets), keyEquivalent: "r")
                menu.insertItem(refreshItem, at: qi - 1)
            }
            item.menu = menu
        }

        // For interactive dropdown widgets, use click target so the popover shows.
        // Some widgets are both cycleable and interactive; those use option-click
        // for cycling and normal click for the popover.
        if widget.hasInteractiveDropdown {
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.menu = nil
        }
    }


}
