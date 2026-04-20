# Barista

A powerful, extensible menu bar widget platform for macOS. 52 widgets across 12 categories, a scrolling stock ticker, menu bar color/gradient customization, rich interactive dropdowns, xbar script compatibility, and profile-based layout switching - all in a single native AppKit app with zero dependencies.

## Features

**52 Built-in Widgets** across 12 categories:

| Category | Widgets |
|----------|---------|
| Finance | Stock Ticker (scrolling), Crypto, Forex, Market Status |
| System | CPU, RAM, GPU, Temperature Sensors, Network Speed, Battery, Disk Space, Uptime, IP Address, Top Processes, Bluetooth Batteries |
| Productivity | Pomodoro, Daily Goal, Calendar Next, Inbox Count, Screen Time, Reminders, Meeting Joiner, Focus Task, Clipboard Peek |
| Time & Calendar | World Clock, Countdown, Custom Date, Timezone Diff, Calendar Grid |
| Weather | Current Weather, Sunrise/Sunset, Air Quality, UV Index |
| Developer | Git Branch, Docker Status, Server Ping |
| Fun & Lifestyle | Daily Quote, Moon Phase, Dad Joke, Dice Roller, Caffeine Tracker |
| Sports | Live Scores, F1 Standings, Soccer Table |
| Social | Hacker News, GitHub Notifications |
| Music & Media | Now Playing |
| Health | Water Reminder, Stand Reminder |
| Utility | Keep Awake, Dark Mode Toggle, Script Widget (xbar-compatible) |

**Menu Bar Styling** - Customize your menu bar with solid colors, gradients, dynamic time-based themes, or frosted glass effects. No other app does this.

**Interactive Dropdowns** - Rich NSPopover-based dropdowns with sparkline charts, calendar grids, process tables, and time scrubbers.

**Script Widgets** - Full xbar/SwiftBar compatibility. Write shell scripts that render to the menu bar with colors, submenus, clickable links, and SF Symbols.

**Profile System** - Save and restore complete widget layouts. Quick-switch between Work, Home, Presentation, Developer, and Minimal presets, or create your own.

**Menu Bar Management** - Detect and hide third-party menu bar items. Auto-hide timer, hover-to-reveal, drag to reorder.

## Requirements

- macOS 13.0+
- Swift 5.9+
- Xcode 15+ (or Swift toolchain)

## Build & Run

```bash
# Clone
git clone https://github.com/noamsmall/barista.git
cd barista

# Build
swift build

# Run directly
.build/debug/Barista

# Or install to /Applications
cp .build/debug/Barista /Applications/Barista.app/Contents/MacOS/Barista
codesign --force --sign - --entitlements Barista/Barista.entitlements /Applications/Barista.app
open /Applications/Barista.app
```

## Architecture

```
Barista/
  main.swift                    # Entry point
  App/
    AppDelegate.swift           # Main app delegate, settings UI
    StatusBarController.swift   # Manages NSStatusItems for all widgets
  Core/
    BaristaWidget.swift         # Core widget protocol + categories
    AnyBaristaWidget.swift      # Type-erased widget wrapper
    WidgetRegistry.swift        # Factory registry for all 52 widgets
    WidgetStore.swift            # UserDefaults persistence for active widgets
    WidgetInstance.swift        # NSStatusItem wrapper per widget
    DataFetcher.swift           # HTTP client with caching
    PopoverController.swift     # Rich dropdown popovers
    SparklineRenderer.swift     # Core Graphics sparkline/bar/ring charts
    TickerScrollView.swift      # CVDisplayLink-powered scrolling text
    MenuBarOverlay.swift        # Color/gradient overlay window
    MenuBarAppearance.swift     # Appearance configuration types
    MenuBarManager.swift        # Third-party item detection + auto-hide
    ProfileManager.swift        # Layout save/restore profiles
    SMCReader.swift             # IOKit SMC for temps/fans
    ScriptRunner.swift          # Shell script execution
    XBarParser.swift            # xbar output format parser
  UI/
    Theme.swift                 # Colors, fonts, semantic styles
    HoverButton.swift           # Animated hover-state buttons
  Widgets/
    Finance/                    # StockTicker, Crypto, Forex, MarketStatus
    System/                     # CPU, RAM, GPU, Temp, Network, Battery, etc.
    Productivity/               # Pomodoro, Calendar, Meeting, Focus, etc.
    TimeCalendar/               # WorldClock, Countdown, CalendarGrid, etc.
    Weather/                    # Weather, Sunrise, AirQuality, UV
    Developer/                  # GitBranch, Docker, ServerPing
    FunLifestyle/               # Quote, MoonPhase, DadJoke, Dice, Caffeine
    Sports/                     # LiveScores, F1, Soccer
    Social/                     # HackerNews, GitHub
    MusicMedia/                 # NowPlaying
    Health/                     # Water, Stand
    Utility/                    # KeepAwake, DarkMode, Script
```

### Key Protocols

- **`BaristaWidget`** - Core protocol. Associated `Config: Codable & Equatable` type, `render() -> WidgetDisplayMode`, `buildDropdownMenu() -> NSMenu`.
- **`Cycleable`** - Click-to-cycle behavior (rotate through items, increment counters).
- **`InteractiveDropdown`** - Rich NSPopover content instead of plain menus.

### Display Modes

Widgets render as one of:
- `.text(String)` - plain text
- `.attributedText(NSAttributedString)` - styled text with colors
- `.scrollingText(NSAttributedString, width: CGFloat)` - CVDisplayLink-powered ticker
- `.sparkline([Double], label: String?, width: CGFloat)` - inline chart

## Creating a Widget

1. Create a new Swift file in the appropriate `Widgets/` subdirectory
2. Implement the `BaristaWidget` protocol:

```swift
struct MyWidgetConfig: Codable, Equatable {
    var someOption: String
    static let `default` = MyWidgetConfig(someOption: "hello")
}

class MyWidget: BaristaWidget {
    static let widgetID = "my-widget"
    static let displayName = "My Widget"
    static let subtitle = "Does something cool"
    static let iconName = "star"  // SF Symbol
    static let category = WidgetCategory.utility
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = MyWidgetConfig.default

    var config: MyWidgetConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { 60 }

    required init(config: MyWidgetConfig) {
        self.config = config
    }

    func start() { /* begin timers/fetching */ }
    func stop() { /* cleanup */ }

    func render() -> WidgetDisplayMode {
        return .text("Hello World")
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        // ... build menu items
        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] {
        return []
    }
}
```

3. Register in `WidgetRegistry.swift`:
```swift
register(MyWidget.self)
```

## Script Widget (xbar format)

The Script Widget supports the [xbar plugin format](https://github.com/matryer/xbar-plugins):

```bash
#!/bin/bash
echo "Hello | color=green sfimage=star.fill"
echo "---"
echo "Item 1 | href=https://example.com"
echo "Item 2 | bash=/usr/bin/open param1=https://example.com terminal=false"
echo "--Submenu Item | color=blue"
```

Supported pipe params: `color`, `font`, `size`, `href`, `bash`, `param1-5`, `terminal`, `image`, `sfimage`, `refresh`.

## License

MIT - see [LICENSE](LICENSE).
