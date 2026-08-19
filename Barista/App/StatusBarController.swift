import Cocoa

class StatusBarController {
    private(set) var instances: [UUID: WidgetInstance] = [:]
    private let registry = WidgetRegistry.shared
    private let store = WidgetStore.shared

    var widgetCount: Int { instances.count }

    // MARK: - Widget Management

    func syncMenuBar() {
        let savedWidgets = store.loadActiveWidgets()

        let savedIDs = Set(savedWidgets.map(\.instanceID))
        let toRemove = instances.keys.filter { !savedIDs.contains($0) }
        for id in toRemove {
            instances[id]?.deactivate()
            instances.removeValue(forKey: id)
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
                if applyFastUpdateProfile(to: instance),
                   let data = instance.widget.getConfigData() {
                    store.updateConfig(instanceID: instance.id, configData: data)
                }
                instances[saved.instanceID] = instance
                instance.activate()
            }
        }
    }

    func addWidget(widgetID: String) -> UUID? {
        guard instances.count < 20 else { return nil }
        guard let entry = registry.entry(for: widgetID) else { return nil }

        if !entry.allowsMultiple && instances.values.contains(where: { $0.widgetID == widgetID }) {
            return nil
        }

        let saved = store.addWidget(widgetID: widgetID)
        let widget = entry.factory(saved.configData)
        let instance = WidgetInstance(
            id: saved.instanceID,
            widgetID: widgetID,
            widget: widget,
            order: saved.order
        )
        if applyFastUpdateProfile(to: instance),
           let data = instance.widget.getConfigData() {
            store.updateConfig(instanceID: instance.id, configData: data)
        }
        instances[saved.instanceID] = instance
        instance.activate()
        return saved.instanceID
    }

    func removeWidget(instanceID: UUID) {
        if let instance = instances[instanceID] {
            // Save live config to store before removal so memory gets the freshest state
            if let data = instance.widget.getConfigData() {
                store.updateConfig(instanceID: instanceID, configData: data)
            }
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

    @discardableResult
    private func applyFastUpdateProfile(to instance: WidgetInstance) -> Bool {
        var changed = false

        func cap(_ value: inout TimeInterval, to maximum: TimeInterval) {
            if value > maximum {
                value = maximum
                changed = true
            }
        }

        if let widget = instance.widget.underlying(as: StockTickerWidget.self) {
            cap(&widget.config.refreshInterval, to: StockTickerWidget.turboRefreshInterval)
        }
        if let widget = instance.widget.underlying(as: CPUWidget.self) {
            cap(&widget.config.refreshRate, to: 1)
        }
        if let widget = instance.widget.underlying(as: RAMWidget.self) {
            cap(&widget.config.refreshRate, to: 1)
        }
        if let widget = instance.widget.underlying(as: NetworkSpeedWidget.self) {
            cap(&widget.config.refreshRate, to: 1)
        }
        if let widget = instance.widget.underlying(as: SystemHealthWidget.self) {
            cap(&widget.config.refreshRate, to: 1)
        }
        if let widget = instance.widget.underlying(as: BatteryWidget.self) {
            cap(&widget.config.refreshRate, to: 5)
        }
        if let widget = instance.widget.underlying(as: CalendarNextWidget.self) {
            cap(&widget.config.refreshRate, to: 5)
        }
        if let widget = instance.widget.underlying(as: TodayBriefWidget.self) {
            cap(&widget.config.refreshRate, to: 5)
        }
        if let widget = instance.widget.underlying(as: NowPlayingWidget.self) {
            cap(&widget.config.refreshRate, to: 1)
        }
        if let widget = instance.widget.underlying(as: LiveScoresWidget.self) {
            cap(&widget.config.refreshRate, to: 30)
            cap(&widget.config.liveRefreshRate, to: 10)
        }
        if let widget = instance.widget.underlying(as: WeatherWidget.self) {
            cap(&widget.config.refreshRate, to: 120)
        }
        if let widget = instance.widget.underlying(as: ClaudeUsageWidget.self) {
            cap(&widget.config.refreshInterval, to: 1)
            if !widget.config.autoRefresh {
                widget.config.autoRefresh = true
                changed = true
            }
        }

        return changed
    }
}
