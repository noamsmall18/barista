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

    func loadActiveWidgets() -> [SavedWidget] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([SavedWidget].self, from: data)
        else { return defaultWidgets() }
        return saved.sorted { $0.order < $1.order }
    }

    func save(_ widgets: [SavedWidget]) {
        if let data = try? JSONEncoder().encode(widgets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func defaultWidgets() -> [SavedWidget] {
        return [
            SavedWidget(instanceID: UUID(), widgetID: "world-clock", order: 0, configData: nil, isEnabled: true),
            SavedWidget(instanceID: UUID(), widgetID: "stock-ticker", order: 1, configData: nil, isEnabled: true),
        ]
    }

    func addWidget(widgetID: String, configData: Data? = nil) -> SavedWidget {
        var widgets = loadActiveWidgets()
        let maxOrder = widgets.map(\.order).max() ?? -1
        let saved = SavedWidget(
            instanceID: UUID(),
            widgetID: widgetID,
            order: maxOrder + 1,
            configData: configData,
            isEnabled: true
        )
        widgets.append(saved)
        save(widgets)
        return saved
    }

    func removeWidget(instanceID: UUID) {
        var widgets = loadActiveWidgets()
        widgets.removeAll { $0.instanceID == instanceID }
        // Re-order
        for i in widgets.indices {
            widgets[i].order = i
        }
        save(widgets)
    }

    func updateConfig(instanceID: UUID, configData: Data) {
        var widgets = loadActiveWidgets()
        if let idx = widgets.firstIndex(where: { $0.instanceID == instanceID }) {
            widgets[idx].configData = configData
            save(widgets)
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
