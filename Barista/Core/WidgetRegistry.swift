import Cocoa

struct WidgetRegistryEntry {
    let widgetID: String
    let displayName: String
    let subtitle: String
    let iconName: String
    let category: WidgetCategory
    let allowsMultiple: Bool
    let isPremium: Bool
    let factory: (Data?) -> AnyBaristaWidget
}

class WidgetRegistry {
    static let shared = WidgetRegistry()

    private(set) var entries: [WidgetRegistryEntry] = []

    func register<W: BaristaWidget>(_ type: W.Type) {
        let entry = WidgetRegistryEntry(
            widgetID: W.widgetID,
            displayName: W.displayName,
            subtitle: W.subtitle,
            iconName: W.iconName,
            category: W.category,
            allowsMultiple: W.allowsMultiple,
            isPremium: W.isPremium,
            factory: { configData in
                let config: W.Config
                if let data = configData,
                   let decoded = try? JSONDecoder().decode(W.Config.self, from: data) {
                    config = decoded
                } else {
                    config = W.defaultConfig
                }
                return AnyBaristaWidget(W(config: config))
            }
        )
        entries.append(entry)
    }

    func entry(for widgetID: String) -> WidgetRegistryEntry? {
        entries.first { $0.widgetID == widgetID }
    }

    func entries(in category: WidgetCategory) -> [WidgetRegistryEntry] {
        entries.filter { $0.category == category }
    }

    /// Registers the widgets this flavour ships.
    ///
    /// Marketbar registers only the market terminal, so nothing else can appear
    /// in its gallery, its settings, or a restored layout.
    func registerAll(for flavor: AppFlavor = .current) {
        guard flavor == .barista else {
            register(StockTickerWidget.self)
            return
        }
        // Finance
        register(StockTickerWidget.self)
        // System
        register(CPUWidget.self)
        register(RAMWidget.self)
        register(NetworkSpeedWidget.self)
        register(BatteryWidget.self)
        register(SystemHealthWidget.self)
        // Weather
        register(WeatherWidget.self)
        // Productivity
        register(PomodoroWidget.self)
        register(CalendarNextWidget.self)
        register(TodayBriefWidget.self)
        // Music & Media
        register(NowPlayingWidget.self)
        // Time & Calendar
        register(WorldClockWidget.self)
        // Sports
        register(LiveScoresWidget.self)
        // Utility
        register(KeepAwakeWidget.self)
        register(ClaudeUsageWidget.self)
    }
}
