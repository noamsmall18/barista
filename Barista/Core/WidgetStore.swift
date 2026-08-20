import Foundation

struct SavedWidget: Codable {
    let instanceID: UUID
    let widgetID: String
    var order: Int
    var configData: Data?
    var isEnabled: Bool
}

class WidgetStore {
    static let shared = WidgetStore()
    private let key = "barista.activeWidgets"
    private let memoryKey = "barista.widgetMemory" // persists config after removal
    private let retiredWidgetIDs: Set<String> = ["wifi-signal", "fan-speed"]
    private let replacementWidgetIDs = ["system-health", "today-brief"]

    func loadActiveWidgets() -> [SavedWidget] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedWidget].self, from: data)
        else { return defaultWidgets() }
        // Filter out widgets whose type no longer exists or has been retired from the live gallery.
        let hadRetiredWidgets = saved.contains { retiredWidgetIDs.contains($0.widgetID) }
        var valid = saved.filter {
            WidgetRegistry.shared.entry(for: $0.widgetID) != nil && !retiredWidgetIDs.contains($0.widgetID)
        }

        if hadRetiredWidgets {
            let existingIDs = Set(valid.map(\.widgetID))
            let nextOrder = (valid.map(\.order).max() ?? -1) + 1
            for (offset, widgetID) in replacementWidgetIDs.enumerated()
            where !existingIDs.contains(widgetID) && WidgetRegistry.shared.entry(for: widgetID) != nil {
                valid.append(SavedWidget(
                    instanceID: UUID(),
                    widgetID: widgetID,
                    order: nextOrder + offset,
                    configData: loadMemory(for: widgetID),
                    isEnabled: true
                ))
            }
        }

        if valid.count != saved.count || hadRetiredWidgets {
            for i in valid.indices { valid[i].order = i }
            save(valid)
        }
        return valid.sorted { $0.order < $1.order }
    }

    func save(_ widgets: [SavedWidget]) {
        if let data = try? JSONEncoder().encode(widgets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func defaultWidgets() -> [SavedWidget] {
        let defaults = AppFlavor.current.defaultWidgetIDs
            .filter { WidgetRegistry.shared.entry(for: $0) != nil }
        return defaults.enumerated().map { index, widgetID in
            SavedWidget(
                instanceID: UUID(),
                widgetID: widgetID,
                order: index,
                configData: nil,
                isEnabled: true
            )
        }
    }

    func addWidget(widgetID: String, configData: Data? = nil) -> SavedWidget {
        var widgets = loadActiveWidgets()
        let maxOrder = widgets.map(\.order).max() ?? -1
        // Restore saved config from memory if no explicit config provided
        let restoredConfig = configData ?? loadMemory(for: widgetID)
        let saved = SavedWidget(
            instanceID: UUID(),
            widgetID: widgetID,
            order: maxOrder + 1,
            configData: restoredConfig,
            isEnabled: true
        )
        widgets.append(saved)
        save(widgets)
        return saved
    }

    func removeWidget(instanceID: UUID) {
        var widgets = loadActiveWidgets()
        // Stash config to memory before removing
        if let widget = widgets.first(where: { $0.instanceID == instanceID }),
           let config = widget.configData {
            saveMemory(config, for: widget.widgetID)
        }
        widgets.removeAll { $0.instanceID == instanceID }
        for i in widgets.indices {
            widgets[i].order = i
        }
        save(widgets)
    }

    // MARK: - Widget Memory (persists config across add/remove)

    private func loadMemory(for widgetID: String) -> Data? {
        let all = loadAllMemory()
        return all[widgetID]
    }

    private func saveMemory(_ data: Data, for widgetID: String) {
        var all = loadAllMemory()
        all[widgetID] = data
        if let encoded = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(encoded, forKey: memoryKey)
        }
    }

    private func loadAllMemory() -> [String: Data] {
        guard let raw = UserDefaults.standard.data(forKey: memoryKey),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: raw)
        else { return [:] }
        return decoded
    }

    func updateConfig(instanceID: UUID, configData: Data) {
        var widgets = loadActiveWidgets()
        if let idx = widgets.firstIndex(where: { $0.instanceID == instanceID }) {
            widgets[idx].configData = configData
            save(widgets)
            // Also update memory so it persists even if widget is removed later
            saveMemory(configData, for: widgets[idx].widgetID)
        }
    }

    func reorder(from: Int, to: Int) {
        var widgets = loadActiveWidgets()
        guard from < widgets.count, to < widgets.count else { return }
        let item = widgets.remove(at: from)
        widgets.insert(item, at: to)
        for i in widgets.indices {
            widgets[i].order = i
        }
        save(widgets)
    }
}
