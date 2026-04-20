import Foundation

/// Named profile for saving/restoring complete widget configurations.
/// Supports quick switching between Work / Home / Presentation layouts.
struct WidgetProfile: Codable {
    let id: UUID
    var name: String
    var widgets: [SavedWidget]
    var appearance: MenuBarAppearance?
    var createdAt: Date
    var icon: String  // SF Symbol name

    init(name: String, widgets: [SavedWidget], appearance: MenuBarAppearance? = nil, icon: String = "square.grid.2x2") {
        self.id = UUID()
        self.name = name
        self.widgets = widgets
        self.appearance = appearance
        self.createdAt = Date()
        self.icon = icon
    }
}

class ProfileManager {
    static let shared = ProfileManager()

    private let key = "barista.profiles"
    private let activeKey = "barista.activeProfile"
    private(set) var profiles: [WidgetProfile] = []
    private(set) var activeProfileID: UUID?

    init() {
        load()
    }

    // MARK: - CRUD

    func save(profile: WidgetProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        persist()
    }

    func rename(id: UUID, to name: String) {
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx].name = name
            persist()
        }
    }

    // MARK: - Snapshot & Restore

    /// Capture current state as a new profile.
    func captureCurrentState(name: String, icon: String = "square.grid.2x2") -> WidgetProfile {
        let widgets = WidgetStore.shared.loadActiveWidgets()
        let appearance = MenuBarAppearance.load()
        let profile = WidgetProfile(name: name, widgets: widgets, appearance: appearance, icon: icon)
        save(profile: profile)
        return profile
    }

    /// Activate a profile, replacing current widget set.
    func activate(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        // Save widgets
        WidgetStore.shared.save(profile.widgets)

        // Apply appearance if stored
        if let appearance = profile.appearance {
            appearance.save()
            MenuBarOverlay.shared.apply(appearance)
        }

        activeProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
    }

    /// Built-in profile presets.
    static let presets: [(name: String, icon: String, widgetIDs: [String])] = [
        ("Work", "briefcase", ["calendar-next", "meeting-joiner", "pomodoro", "focus-task", "cpu-monitor"]),
        ("Home", "house", ["weather-current", "now-playing", "daily-quote", "moon-phase"]),
        ("Presentation", "play.rectangle", ["focus-task", "keep-awake", "battery-health"]),
        ("Developer", "terminal", ["git-branch", "docker-status", "cpu-monitor", "ram-monitor", "server-ping"]),
        ("Minimal", "circle", ["world-clock", "battery-health"]),
    ]

    func createPreset(name: String, icon: String, widgetIDs: [String]) -> WidgetProfile {
        let widgets = widgetIDs.enumerated().map { (i, id) in
            SavedWidget(instanceID: UUID(), widgetID: id, order: i, configData: nil, isEnabled: true)
        }
        let profile = WidgetProfile(name: name, widgets: widgets, icon: icon)
        save(profile: profile)
        return profile
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WidgetProfile].self, from: data) {
            profiles = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: activeKey) {
            activeProfileID = UUID(uuidString: idStr)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
