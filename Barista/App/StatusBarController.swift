import Cocoa

class StatusBarController {
    private(set) var instances: [UUID: WidgetInstance] = [:]
    private let registry = WidgetRegistry.shared
    private let store = WidgetStore.shared

    // MARK: - Menu Bar Space Measurement

    /// The left boundary where status items can't go past.
    /// Uses the actual auxiliary top-right area on notched Macs,
    /// or estimates for non-notch screens.
    private var leftBoundary: CGFloat {
        guard let screen = NSScreen.main else { return 300 }
        if #available(macOS 12.0, *) {
            if let rightArea = screen.auxiliaryTopRightArea {
                // This gives us the exact start of the right side of the menu bar
                return rightArea.origin.x
            }
        }
        if hasNotch(screen: screen) {
            return (screen.frame.width / 2) + 90
        }
        // No notch - app menus take the left ~40%
        return screen.frame.width * 0.40
    }

    /// Total width our widgets are actually using, measured from their real positions.
    var usedMenuBarWidth: CGFloat {
        var total: CGFloat = 0
        for (_, instance) in instances {
            total += instance.measuredWidth
        }
        return total
    }

    /// How much space is left before our widgets hit the danger zone,
    /// measured from the actual position of our leftmost status item.
    var remainingMenuBarWidth: CGFloat {
        // Find the leftmost x position among our status items
        var leftmostX: CGFloat = .greatestFiniteMagnitude
        for (_, instance) in instances {
            if let window = instance.statusItem?.button?.window {
                let x = window.frame.origin.x
                if x < leftmostX {
                    leftmostX = x
                }
            }
        }

        // If no items have windows yet, estimate
        if leftmostX == .greatestFiniteMagnitude {
            return 200
        }

        // Remaining = distance from our leftmost item to the boundary
        return max(leftmostX - leftBoundary, 0)
    }

    /// Total space that's available for Barista widgets (what we use + what's left).
    var availableMenuBarWidth: CGFloat {
        return usedMenuBarWidth + remainingMenuBarWidth
    }

    /// Percentage of available space used (0.0 to 1.0+)
    var menuBarUsagePercent: CGFloat {
        let available = availableMenuBarWidth
        guard available > 0 else { return 1.0 }
        return usedMenuBarWidth / available
    }

    /// Whether there's enough room for another widget (~80px minimum)
    var canAddMore: Bool {
        return remainingMenuBarWidth > 80
    }

    var widgetCount: Int { instances.count }

    // MARK: - Notch Detection

    private func hasNotch(screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    // MARK: - Widget Management

    func syncMenuBar() {
        let savedWidgets = store.loadActiveWidgets()

        let savedIDs = Set(savedWidgets.map(\.instanceID))
        for (id, instance) in instances {
            if !savedIDs.contains(id) {
                instance.deactivate()
                instances.removeValue(forKey: id)
            }
        }

        for saved in savedWidgets where saved.isEnabled {
            if instances[saved.instanceID] == nil {
                guard let entry = registry.entry(for: saved.widgetID) else { continue }
                let widget = entry.factory(saved.configData)
                let instance = WidgetInstance(
                    id: saved.instanceID,
                    widgetID: saved.widgetID,
                    widget: widget,
                    order: saved.order
                )
                instances[saved.instanceID] = instance
                instance.activate()
            }
        }
    }

    func addWidget(widgetID: String) -> UUID? {
        guard canAddMore else { return nil }

        let saved = store.addWidget(widgetID: widgetID)
        guard let entry = registry.entry(for: widgetID) else { return nil }
        let widget = entry.factory(nil)
        let instance = WidgetInstance(
            id: saved.instanceID,
            widgetID: widgetID,
            widget: widget,
            order: saved.order
        )
        instances[saved.instanceID] = instance
        instance.activate()
        return saved.instanceID
    }

    func removeWidget(instanceID: UUID) {
        if let instance = instances[instanceID] {
            instance.deactivate()
            instances.removeValue(forKey: instanceID)
        }
        store.removeWidget(instanceID: instanceID)
    }

    func removeAllWidgets() {
        for (_, instance) in instances {
            instance.deactivate()
        }
        instances.removeAll()
    }

    func refreshAll() {
        for (_, instance) in instances {
            instance.widget.refresh()
        }
    }

    func instance(for id: UUID) -> WidgetInstance? {
        instances[id]
    }

    var activeInstances: [WidgetInstance] {
        instances.values.sorted { $0.order < $1.order }
    }

}
