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

    func registerAll() {
        // Time & Calendar
        register(WorldClockWidget.self)
        register(CountdownWidget.self)
        register(CustomDateWidget.self)
        register(TimeZoneDiffWidget.self)
        register(CalendarGridWidget.self)
        // Weather
        register(WeatherWidget.self)
        register(SunriseSunsetWidget.self)
        register(AirQualityWidget.self)
        register(UVIndexWidget.self)
        // Finance
        register(StockTickerWidget.self)
        register(CryptoWidget.self)
        register(MarketStatusWidget.self)
        register(ForexWidget.self)
        // System
        register(CPUWidget.self)
        register(RAMWidget.self)
        register(NetworkSpeedWidget.self)
        register(BatteryWidget.self)
        register(UptimeWidget.self)
        register(DiskSpaceWidget.self)
        register(IPAddressWidget.self)
        register(GPUWidget.self)
        register(TemperatureWidget.self)
        register(TopProcessesWidget.self)
        register(BluetoothBatteryWidget.self)
        // Productivity
        register(PomodoroWidget.self)
        register(DailyGoalWidget.self)
        register(CalendarNextWidget.self)
        register(InboxCountWidget.self)
        register(ScreenTimeWidget.self)
        register(RemindersWidget.self)
        register(MeetingJoinerWidget.self)
        register(FocusTaskWidget.self)
        register(ClipboardWidget.self)
        // Music & Media
        register(NowPlayingWidget.self)
        // Social
        register(HackerNewsWidget.self)
        register(GitHubNotificationsWidget.self)
        // Fun & Lifestyle
        register(DailyQuoteWidget.self)
        register(MoonPhaseWidget.self)
        register(DadJokeWidget.self)
        register(DiceRollerWidget.self)
        register(CaffeineTrackerWidget.self)
        // Sports
        register(LiveScoresWidget.self)
        register(F1StandingsWidget.self)
        register(SoccerTableWidget.self)
        // Developer
        register(GitBranchWidget.self)
        register(DockerWidget.self)
        register(ServerPingWidget.self)
        // Health
        register(WaterReminderWidget.self)
        register(StandReminderWidget.self)
        // Utility
        register(KeepAwakeWidget.self)
        register(DarkModeWidget.self)
        register(ScriptWidget.self)
    }
}
