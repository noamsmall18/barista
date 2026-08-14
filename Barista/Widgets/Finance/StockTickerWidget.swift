import Cocoa
import UserNotifications

// MARK: - Data Types

struct MarketQuote: Codable, Equatable {
    enum Kind: String, Codable { case stock, crypto }
    let symbol: String
    let price: Double
    let change: Double
    let kind: Kind
    var previousClose: Double? = nil
    var dayHigh: Double?
    var dayLow: Double?
    var volume: Double?
    var sparkline: [Double]
    var marketCap: Double?
    var fiftyTwoWeekHigh: Double?
    var fiftyTwoWeekLow: Double?
    var openPrice: Double?
    var peRatio: Double?

    // Extended hours (stocks only)
    var preMarketPrice: Double?
    var preMarketChange: Double?
    var postMarketPrice: Double?
    var postMarketChange: Double?
    var marketState: String?

    var isUp: Bool { change >= 0 }

    var currentPrice: Double {
        extendedHours?.price ?? price
    }

    var currentChange: Double {
        if let ext = extendedHours,
           let previousClose,
           previousClose > 0 {
            return (ext.price - previousClose) / previousClose * 100
        }
        return change
    }

    var currentIsUp: Bool { currentChange >= 0 }

    var marketStatus: MarketStatus {
        MarketStatus.fromYahooMarketState(marketState) ?? MarketStatus.current()
    }

    var chartChange: Double {
        kind == .stock ? currentChange : change
    }

    var chartBaseline: Double? {
        switch kind {
        case .stock:
            return previousClose ?? baselinePrice ?? sparkline.first
        case .crypto:
            return sparkline.first ?? baselinePrice
        }
    }

    var chartSeries: [Double] {
        var series = sparkline.filter { $0.isFinite && $0 > 0 }
        if series.isEmpty {
            if let chartBaseline, chartBaseline > 0, currentPrice > 0 {
                return [chartBaseline, currentPrice]
            }
            return []
        }
        if currentPrice > 0 {
            series[series.count - 1] = currentPrice
        }
        if series.count == 1, let chartBaseline, chartBaseline > 0, chartBaseline != series[0] {
            series.insert(chartBaseline, at: 0)
        }
        return series
    }

    var baselinePrice: Double? {
        if let previousClose, previousClose > 0 { return previousClose }
        let denominator = 1 + (change / 100.0)
        guard denominator > 0 else { return nil }
        return price / denominator
    }

    func dailyValueChange(for quantity: Double) -> Double {
        guard quantity > 0 else { return 0 }
        guard let baselinePrice else { return 0 }
        return (price - baselinePrice) * quantity
    }

    func currentValueChange(for quantity: Double) -> Double {
        guard quantity > 0 else { return 0 }
        guard let baselinePrice else { return 0 }
        return (currentPrice - baselinePrice) * quantity
    }

    var extendedHours: (price: Double, change: Double, label: String)? {
        switch marketStatus {
        case .preMarket:
            if let p = preMarketPrice, let c = preMarketChange { return (p, c, "Pre") }
        case .afterHours:
            if let p = postMarketPrice, let c = postMarketChange { return (p, c, "AH") }
        case .closed:
            return nil
        case .open:
            return nil
        }
        return nil
    }
}

struct PortfolioPosition {
    let quote: MarketQuote
    let quantity: Double

    /// Average price paid per share. Nil when it has never been recorded,
    /// which keeps total-return figures hidden rather than showing a fake gain.
    var averageCost: Double? = nil

    var value: Double { quote.currentPrice * quantity }
    var baselinePrice: Double { quote.baselinePrice ?? quote.currentPrice }
    var baselineValue: Double { baselinePrice * quantity }
    var dailyPL: Double { value - baselineValue }

    var dailyPercent: Double {
        guard baselineValue > 0 else { return 0 }
        return dailyPL / baselineValue * 100
    }

    // MARK: - Total return

    var costValue: Double? {
        guard let averageCost, averageCost > 0 else { return nil }
        return averageCost * quantity
    }

    /// Gain or loss since purchase, as opposed to since yesterday's close.
    var totalPL: Double? {
        guard let costValue else { return nil }
        return value - costValue
    }

    var totalPercent: Double? {
        guard let costValue, costValue > 0, let totalPL else { return nil }
        return totalPL / costValue * 100
    }
}

struct PortfolioSnapshot {
    let positions: [PortfolioPosition]
    let missingSymbols: [String]
    let cash: Double
    let total: Double
    let baselineTotal: Double
    let dailyPL: Double

    var dailyPercent: Double {
        guard baselineTotal > 0 else { return 0 }
        return dailyPL / baselineTotal * 100
    }

    var winners: Int { positions.filter { $0.dailyPL > 0.005 }.count }
    var losers: Int { positions.filter { $0.dailyPL < -0.005 }.count }
    var bestPosition: PortfolioPosition? { positions.max { $0.dailyPL < $1.dailyPL } }
    var worstPosition: PortfolioPosition? { positions.min { $0.dailyPL < $1.dailyPL } }
    var topExposure: PortfolioPosition? { positions.max { $0.value < $1.value } }

    func weight(of position: PortfolioPosition) -> Double {
        guard total > 0 else { return 0 }
        return position.value / total * 100
    }

    // MARK: - Total return

    /// Only positions with a recorded cost count toward total return, so a
    /// half-filled portfolio reports on the part it actually knows about.
    var costedPositions: [PortfolioPosition] { positions.filter { $0.costValue != nil } }
    var positionsMissingCost: [PortfolioPosition] { positions.filter { $0.costValue == nil } }

    var totalCost: Double? {
        let costed = costedPositions
        guard !costed.isEmpty else { return nil }
        return costed.compactMap(\.costValue).reduce(0, +)
    }

    /// Gain since purchase across every costed position. Cash is deliberately
    /// excluded from both sides - it was never invested, so counting it would
    /// dilute the percentage.
    var totalPL: Double? {
        let costed = costedPositions
        guard !costed.isEmpty else { return nil }
        return costed.map(\.value).reduce(0, +) - costed.compactMap(\.costValue).reduce(0, +)
    }

    var totalPercent: Double? {
        guard let totalCost, totalCost > 0, let totalPL else { return nil }
        return totalPL / totalCost * 100
    }

    /// True when some positions have a cost recorded and others do not, so the
    /// UI can say the total return covers only part of the portfolio.
    var hasPartialCostBasis: Bool {
        !costedPositions.isEmpty && !positionsMissingCost.isEmpty
    }

    var bestTotalPosition: PortfolioPosition? {
        costedPositions.max { ($0.totalPercent ?? 0) < ($1.totalPercent ?? 0) }
    }
}

struct MarketBreadth {
    let advancing: Int
    let declining: Int
    let flat: Int
    let averageChange: Double
    let leader: MarketQuote?
    let laggard: MarketQuote?

    var total: Int { advancing + declining + flat }
}

private struct QuoteCachePayload: Codable {
    let quotes: [MarketQuote]
    let indexQuotes: [MarketQuote]
    let lastUpdated: Date
}

// MARK: - Enums

enum TickerDisplayMode: String, Codable, Equatable {
    case scrolling     // scrolling ticker tape
    case focused       // one stock at a time, cycling
    case compact       // "AAPL +2.3%" minimal
    case sparkline     // price chart + ticker label
    case portfolio     // total portfolio value + daily change
}

enum TickerSortMode: String, Codable, Equatable {
    case manual, alphabetical, changeDesc, changeAsc, priceDesc
}

enum TickerAccentPreset: String, Codable, Equatable, CaseIterable {
    case blue, cyan, green, amber, purple, red, white

    var color: NSColor {
        switch self {
        case .blue:   return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1)
        case .cyan:   return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1)
        case .green:  return NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1)
        case .amber:  return NSColor(red: 0.96, green: 0.66, blue: 0.23, alpha: 1)
        case .purple: return NSColor(red: 0.65, green: 0.45, blue: 0.90, alpha: 1)
        case .red:    return NSColor(red: 1.0, green: 0.35, blue: 0.30, alpha: 1)
        case .white:  return NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
        }
    }
}

enum TickerColorMode: String, Codable, Equatable {
    case dynamic // green/red based on change direction + intensity
    case fixed   // always uses accentColor
}

// MARK: - Config

struct StockTickerConfig: Codable, Equatable {
    // Watchlist - shared across every portfolio
    var symbols: [String]
    var coins: [String]

    // Portfolios - exactly one is active at a time
    var portfolios: [Portfolio]
    var activePortfolioID: String

    /// Index of the active portfolio, falling back to the first if the id went stale.
    var activePortfolioIndex: Int {
        portfolios.firstIndex { $0.id == activePortfolioID } ?? 0
    }

    var activePortfolio: Portfolio? {
        portfolios.indices.contains(activePortfolioIndex) ? portfolios[activePortfolioIndex] : nil
    }

    private mutating func mutateActive(_ body: (inout Portfolio) -> Void) {
        guard portfolios.indices.contains(activePortfolioIndex) else { return }
        body(&portfolios[activePortfolioIndex])
    }

    /// Positions of the active portfolio. Kept as a proxy so every existing
    /// `config.holdings` call site keeps working against whichever portfolio is selected.
    var holdings: [String: Double] {
        get { activePortfolio?.holdings ?? [:] }
        set { mutateActive { $0.holdings = newValue } }
    }

    /// Uninvested cash of the active portfolio.
    var cash: Double {
        get { activePortfolio?.cash ?? 0 }
        set { mutateActive { $0.cash = newValue } }
    }

    /// Average cost per share for the active portfolio, keyed by symbol.
    var costBasis: [String: Double] {
        get { activePortfolio?.costBasis ?? [:] }
        set { mutateActive { $0.costBasis = newValue } }
    }

    // Display
    var displayMode: TickerDisplayMode
    var colorMode: TickerColorMode
    var accentColor: TickerAccentPreset
    var coloredTicker: Bool
    var showExtendedHours: Bool

    // Ticker bar
    var scrollSpeed: Double
    var tickerWidth: Double
    var focusCycleSeconds: Double

    // Data toggles
    var showVolume: Bool
    var showSparklines: Bool
    var showIndices: Bool
    var showMarketCap: Bool
    var showDayRange: Bool
    var showPERatio: Bool

    // Sorting
    var sortMode: TickerSortMode

    // Refresh
    var refreshInterval: TimeInterval

    // Crypto
    var cryptoCurrency: String

    // Alerts
    var priceAlerts: [String: Double]

    /// Range shown by the portfolio history chart.
    var historyRange: PortfolioHistoryService.Range = .month

    static let `default` = StockTickerConfig(
        symbols: ["AAPL", "MSFT", "SPY"],
        coins: ["bitcoin", "ethereum"],
        holdings: [:],
        cash: 0,
        displayMode: .scrolling,
        colorMode: .dynamic,
        accentColor: .green,
        coloredTicker: true,
        showExtendedHours: true,
        scrollSpeed: 0.3,
        tickerWidth: 200,
        focusCycleSeconds: 5,
        showVolume: true,
        showSparklines: true,
        showIndices: true,
        showMarketCap: true,
        showDayRange: true,
        showPERatio: false,
        sortMode: .manual,
        refreshInterval: 5,
        cryptoCurrency: "usd",
        priceAlerts: [:]
    )

    enum CodingKeys: String, CodingKey {
        case portfolios, activePortfolioID
        case symbols, coins, holdings, cash, scrollSpeed, coloredTicker, refreshInterval
        case tickerWidth, cryptoCurrency, showVolume, showSparklines, showIndices, showExtendedHours
        case displayMode, focusCycleSeconds, sortMode, priceAlerts
        case colorMode, accentColor, showMarketCap, showDayRange, showPERatio
        case historyRange
    }

    init(symbols: [String] = ["AAPL", "MSFT", "SPY"], coins: [String] = ["bitcoin", "ethereum"],
         holdings: [String: Double] = [:], cash: Double = 0, displayMode: TickerDisplayMode = .scrolling,
         colorMode: TickerColorMode = .dynamic, accentColor: TickerAccentPreset = .green,
         coloredTicker: Bool = true, showExtendedHours: Bool = true,
         scrollSpeed: Double = 0.3, tickerWidth: Double = 200,
         focusCycleSeconds: Double = 5,
         showVolume: Bool = true, showSparklines: Bool = true,
         showIndices: Bool = true, showMarketCap: Bool = true,
         showDayRange: Bool = true, showPERatio: Bool = false,
         sortMode: TickerSortMode = .manual, refreshInterval: TimeInterval = 5,
         cryptoCurrency: String = "usd", priceAlerts: [String: Double] = [:]) {
        self.symbols = symbols; self.coins = coins
        let initial = Portfolio(name: Portfolio.fallbackName, holdings: holdings, cash: cash)
        self.portfolios = [initial]
        self.activePortfolioID = initial.id
        self.displayMode = displayMode; self.colorMode = colorMode; self.accentColor = accentColor
        self.coloredTicker = coloredTicker; self.showExtendedHours = showExtendedHours
        self.scrollSpeed = scrollSpeed; self.tickerWidth = tickerWidth
        self.focusCycleSeconds = focusCycleSeconds
        self.showVolume = showVolume; self.showSparklines = showSparklines
        self.showIndices = showIndices; self.showMarketCap = showMarketCap
        self.showDayRange = showDayRange; self.showPERatio = showPERatio
        self.sortMode = sortMode; self.refreshInterval = refreshInterval
        self.cryptoCurrency = cryptoCurrency; self.priceAlerts = priceAlerts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbols = try c.decodeIfPresent([String].self, forKey: .symbols) ?? Self.default.symbols
        coins = try c.decodeIfPresent([String].self, forKey: .coins) ?? []
        // Portfolios. Configs written before multi-portfolio support carry a flat
        // holdings/cash pair - fold those into a single "Main" portfolio so nothing is lost.
        let legacyHoldings = try c.decodeIfPresent([String: Double].self, forKey: .holdings) ?? [:]
        let legacyCash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        let stored = try c.decodeIfPresent([Portfolio].self, forKey: .portfolios) ?? []

        if stored.isEmpty {
            let migrated = Portfolio(name: Portfolio.fallbackName,
                                     holdings: legacyHoldings,
                                     cash: legacyCash)
            portfolios = [migrated]
            activePortfolioID = migrated.id
        } else {
            portfolios = stored
            let savedID = try c.decodeIfPresent(String.self, forKey: .activePortfolioID)
            activePortfolioID = stored.contains { $0.id == savedID } ? savedID! : stored[0].id
        }
        displayMode = try c.decodeIfPresent(TickerDisplayMode.self, forKey: .displayMode) ?? .scrolling
        colorMode = try c.decodeIfPresent(TickerColorMode.self, forKey: .colorMode) ?? .dynamic
        accentColor = try c.decodeIfPresent(TickerAccentPreset.self, forKey: .accentColor) ?? .green
        coloredTicker = try c.decodeIfPresent(Bool.self, forKey: .coloredTicker) ?? true
        showExtendedHours = try c.decodeIfPresent(Bool.self, forKey: .showExtendedHours) ?? true
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 0.3
        tickerWidth = try c.decodeIfPresent(Double.self, forKey: .tickerWidth) ?? 200
        focusCycleSeconds = try c.decodeIfPresent(Double.self, forKey: .focusCycleSeconds) ?? 5
        showVolume = try c.decodeIfPresent(Bool.self, forKey: .showVolume) ?? true
        showSparklines = try c.decodeIfPresent(Bool.self, forKey: .showSparklines) ?? true
        showIndices = try c.decodeIfPresent(Bool.self, forKey: .showIndices) ?? true
        showMarketCap = try c.decodeIfPresent(Bool.self, forKey: .showMarketCap) ?? true
        showDayRange = try c.decodeIfPresent(Bool.self, forKey: .showDayRange) ?? true
        showPERatio = try c.decodeIfPresent(Bool.self, forKey: .showPERatio) ?? false
        sortMode = try c.decodeIfPresent(TickerSortMode.self, forKey: .sortMode) ?? .manual
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 5
        cryptoCurrency = try c.decodeIfPresent(String.self, forKey: .cryptoCurrency) ?? "usd"
        priceAlerts = try c.decodeIfPresent([String: Double].self, forKey: .priceAlerts) ?? [:]
        historyRange = try c.decodeIfPresent(PortfolioHistoryService.Range.self, forKey: .historyRange) ?? .month
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(portfolios, forKey: .portfolios)
        try c.encode(activePortfolioID, forKey: .activePortfolioID)

        // Also written flat so an older build still finds the active portfolio
        // instead of falling back to an empty one.
        try c.encode(holdings, forKey: .holdings)
        try c.encode(cash, forKey: .cash)

        try c.encode(symbols, forKey: .symbols)
        try c.encode(coins, forKey: .coins)
        try c.encode(displayMode, forKey: .displayMode)
        try c.encode(colorMode, forKey: .colorMode)
        try c.encode(accentColor, forKey: .accentColor)
        try c.encode(coloredTicker, forKey: .coloredTicker)
        try c.encode(showExtendedHours, forKey: .showExtendedHours)
        try c.encode(scrollSpeed, forKey: .scrollSpeed)
        try c.encode(tickerWidth, forKey: .tickerWidth)
        try c.encode(focusCycleSeconds, forKey: .focusCycleSeconds)
        try c.encode(showVolume, forKey: .showVolume)
        try c.encode(showSparklines, forKey: .showSparklines)
        try c.encode(showIndices, forKey: .showIndices)
        try c.encode(showMarketCap, forKey: .showMarketCap)
        try c.encode(showDayRange, forKey: .showDayRange)
        try c.encode(showPERatio, forKey: .showPERatio)
        try c.encode(sortMode, forKey: .sortMode)
        try c.encode(refreshInterval, forKey: .refreshInterval)
        try c.encode(cryptoCurrency, forKey: .cryptoCurrency)
        try c.encode(priceAlerts, forKey: .priceAlerts)
        try c.encode(historyRange, forKey: .historyRange)
    }
}

// MARK: - Coin Symbols

let coinSymbols: [String: String] = [
    "bitcoin": "BTC", "ethereum": "ETH", "solana": "SOL",
    "cardano": "ADA", "dogecoin": "DOGE", "ripple": "XRP",
    "polkadot": "DOT", "avalanche-2": "AVAX", "chainlink": "LINK",
    "litecoin": "LTC", "polygon": "MATIC", "uniswap": "UNI",
    "binancecoin": "BNB", "tron": "TRX", "shiba-inu": "SHIB",
    "toncoin": "TON", "stellar": "XLM", "sui": "SUI",
    "pepe": "PEPE", "near": "NEAR", "aptos": "APT",
    "arbitrum": "ARB", "optimism": "OP", "cosmos": "ATOM",
    "hedera": "HBAR", "render-token": "RNDR", "injective-protocol": "INJ",
    "fetch-ai": "FET", "bonk": "BONK", "jupiter-exchange-solana": "JUP",
]

let symbolToCoinID: [String: String] = {
    var m: [String: String] = [:]
    for (id, sym) in coinSymbols { m[sym] = id }
    return m
}()

// MARK: - Market Status

enum MarketStatus {
    case preMarket, open, afterHours, closed

    var label: String {
        switch self {
        case .preMarket: return "Pre-Market"
        case .open: return "Market Open"
        case .afterHours: return "After Hours"
        case .closed: return "Market Closed"
        }
    }

    var color: NSColor {
        switch self {
        case .open: return NSColor(red: 0.25, green: 0.85, blue: 0.55, alpha: 1)
        case .preMarket, .afterHours: return Theme.brandAmber
        case .closed: return Theme.textMuted
        }
    }

    static func current() -> MarketStatus {
        let et = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = et
        let now = Date()
        let wd = cal.component(.weekday, from: now)
        if wd == 1 || wd == 7 { return .closed }
        let t = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        if t < 240 { return .closed }
        if t < 570 { return .preMarket }
        if t < 960 { return .open }
        if t < 1200 { return .afterHours }
        return .closed
    }

    static func fromYahooMarketState(_ raw: String?) -> MarketStatus? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "PRE":
            return .preMarket
        case "REGULAR":
            return .open
        case "POST":
            return .afterHours
        case "CLOSED", "PREPRE", "POSTPOST":
            return .closed
        default:
            return nil
        }
    }
}

// MARK: - Config Changed Notification

extension NSNotification.Name {
    static let baristaWidgetConfigChanged = NSNotification.Name("BaristaWidgetConfigChanged")
}

// MARK: - Market Ticker Widget

class StockTickerWidget: BaristaWidget {
    static let widgetID = "stock-ticker"
    static let displayName = "Market Ticker"
    static let subtitle = "Live stocks & crypto prices"
    static let iconName = "chart.line.uptrend.xyaxis"
    static let category = WidgetCategory.finance
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = StockTickerConfig.default

    var config: StockTickerConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { effectiveRefreshInterval }

    private(set) var quotes: [MarketQuote] = []
    private(set) var indexQuotes: [MarketQuote] = []
    private(set) var lastFetchFailed = false
    private(set) var lastUpdated: Date?
    private(set) var failedSymbols: Set<String> = []
    private(set) var isUsingCachedData = false
    private var timer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    fileprivate var focusedIndex: Int = 0
    fileprivate var popoverVC: MarketPopoverController?
    private var previousPrices: [String: Double] = [:]

    var onDataRefresh: (() -> Void)?

    private static let indexSymbols = ["SPY", "QQQ", "DIA"]
    private static let quoteCacheKey = "barista.stockTicker.lastGoodQuotes"
    static let turboRefreshInterval: TimeInterval = 5

    /// The configured rate, before market hours or backoff are taken into account.
    private var baseRefreshInterval: TimeInterval {
        max(2, min(config.refreshInterval, Self.turboRefreshInterval))
    }

    /// How often equities are worth re-fetching. Prices only move while the
    /// exchange is open, so polling every few seconds overnight buys nothing and
    /// is what gets the app throttled.
    private var stockRefreshInterval: TimeInterval {
        stockInterval(during: MarketStatus.current())
    }

    /// Takes the phase as an argument so the schedule can be checked for hours
    /// other than the one the clock happens to be in.
    func stockInterval(during status: MarketStatus) -> TimeInterval {
        let base = baseRefreshInterval
        switch status {
        case .open:                   return base
        case .preMarket, .afterHours: return max(base * 3, 15)
        case .closed:                 return max(base * 12, 300)
        }
    }

    /// Crypto trades around the clock, so it never gets the closed-market slowdown.
    private var cryptoRefreshInterval: TimeInterval {
        max(baseRefreshInterval, 10)
    }

    /// Timer cadence: the faster of the two, since each fetch decides for itself
    /// whether it is actually due.
    private var effectiveRefreshInterval: TimeInterval {
        let candidates = config.coins.isEmpty
            ? [stockRefreshInterval]
            : [stockRefreshInterval, cryptoRefreshInterval]
        return max(2, candidates.min() ?? baseRefreshInterval)
    }

    // MARK: - Throttling

    /// Set when an endpoint answers 429. Fetches are skipped until it passes.
    private var backoffUntil: Date?
    private var consecutiveRateLimits = 0
    private(set) var lastSuccessfulFetch: Date?
    private(set) var rateLimitedHost: String?

    var isBackingOff: Bool {
        guard let backoffUntil else { return false }
        return backoffUntil > Date()
    }

    /// Seconds until normal polling resumes, for the UI to display.
    var backoffRemaining: TimeInterval {
        guard let backoffUntil else { return 0 }
        return max(0, backoffUntil.timeIntervalSinceNow)
    }

    /// How stale the newest quote is. Nil before the first successful fetch.
    var dataAge: TimeInterval? {
        lastSuccessfulFetch.map { Date().timeIntervalSince($0) }
    }

    /// True once data is older than several refresh cycles, so the UI can stop
    /// presenting stale prices as if they were live.
    var isDataStale: Bool {
        guard let dataAge else { return false }
        return dataAge > max(effectiveRefreshInterval * 4, 90)
    }

    private func noteFetchSuccess() {
        consecutiveRateLimits = 0
        backoffUntil = nil
        rateLimitedHost = nil
        lastSuccessfulFetch = Date()
        recordPortfolioHistory()
    }

    /// Snapshots every portfolio's value, not just the active one, so switching
    /// tabs doesn't leave the others with gaps.
    private func recordPortfolioHistory() {
        let saved = config.activePortfolioID
        for portfolio in config.portfolios {
            config.activePortfolioID = portfolio.id
            if let snapshot = portfolioSnapshot() {
                PortfolioHistoryService.shared.record(portfolioID: portfolio.id, value: snapshot.total)
            }
        }
        config.activePortfolioID = saved
    }

    /// Doubles the wait each time an endpoint throttles us, capped at 10 minutes.
    private func noteFetchFailure(_ error: Error) {
        guard let http = error as? DataFetcher.HTTPError, http.isRateLimited else { return }
        consecutiveRateLimits += 1
        rateLimitedHost = http.host
        let delay = min(30 * pow(2, Double(consecutiveRateLimits - 1)), 600)
        backoffUntil = Date().addingTimeInterval(delay)
    }

    private var quoteCacheAge: TimeInterval {
        max(1, effectiveRefreshInterval * 0.45)
    }

    private var cryptoCacheAge: TimeInterval {
        max(3, effectiveRefreshInterval * 0.8)
    }

    required init(config: StockTickerConfig) {
        self.config = config
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func start() {
        currentTimerInterval = effectiveRefreshInterval
        loadCachedQuotesIfNeeded()
        fetchAll(force: true)
        // Earnings dates change daily at most, and the service throttles itself.
        EarningsCalendarService.shared.refreshIfNeeded { [weak self] in
            self?.onDisplayUpdate?()
            self?.onDataRefresh?()
        }
        timer = Timer.scheduledTimer(withTimeInterval: currentTimerInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Self-correcting timer: if refresh rate changed, rebuild the timer
        let interval = effectiveRefreshInterval
        if currentTimerInterval != interval {
            timer?.invalidate()
            timer = nil
            currentTimerInterval = interval
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        fetchAll()
    }

    func saveConfig() {
        NotificationCenter.default.post(name: .baristaWidgetConfigChanged, object: self)
    }

    // MARK: - Rendering

    func render() -> WidgetDisplayMode {
        switch config.displayMode {
        case .scrolling:  return renderScrolling()
        case .focused:    return renderFocused()
        case .compact:    return renderCompact()
        case .sparkline:  return renderSparkline()
        case .portfolio:  return renderPortfolio()
        }
    }

    private func renderScrolling() -> WidgetDisplayMode {
        guard !quotes.isEmpty else {
            return .text(lastFetchFailed ? "Market: Offline" : "Loading...")
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let sepFont = NSFont.systemFont(ofSize: 9, weight: .light)
        let sep = "  \u{00B7}  "
        let sorted = sortedQuotes()

        if config.coloredTicker {
            let r = NSMutableAttributedString()
            for (i, q) in sorted.enumerated() {
                let session = q.extendedHours?.label
                let sessionText = session.map { " \($0)" } ?? ""
                let mainText = "\(q.symbol)\(sessionText) $\(formatPrice(q.currentPrice)) \(q.currentIsUp ? "\u{25B2}" : "\u{25BC}")\(String(format: "%.1f%%", abs(q.currentChange)))"
                r.append(NSAttributedString(string: mainText, attributes: [.font: font, .foregroundColor: intensityColor(for: q.currentChange)]))
                if config.showExtendedHours, let ext = q.extendedHours, session != nil {
                    let arrow = ext.change >= 0 ? "\u{25B2}" : "\u{25BC}"
                    let extText = " close:\(arrow)\(String(format: "%.1f%%", abs(ext.change)))"
                    let extColor = intensityColor(for: ext.change).withAlphaComponent(0.7)
                    r.append(NSAttributedString(string: extText, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: extColor]))
                }
                if i < sorted.count - 1 {
                    r.append(NSAttributedString(string: sep, attributes: [.font: sepFont, .foregroundColor: NSColor.headerTextColor.withAlphaComponent(0.18)]))
                }
            }
            r.append(NSAttributedString(string: "        ", attributes: [.font: sepFont, .foregroundColor: NSColor.clear]))
            return .scrollingText(r, width: CGFloat(config.tickerWidth))
        } else {
            let text = sorted.map { formatTickerItem($0) }.joined(separator: sep) + "        "
            return .scrollingText(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.headerTextColor]), width: CGFloat(config.tickerWidth))
        }
    }

    private func renderFocused() -> WidgetDisplayMode {
        let sorted = sortedQuotes()
        guard !sorted.isEmpty else { return .text(lastFetchFailed ? "Market: Offline" : "Loading...") }
        let q = sorted[focusedIndex % sorted.count]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let color = config.coloredTicker ? intensityColor(for: q.currentChange) : NSColor.headerTextColor
        return .attributedText(NSAttributedString(string: formatTickerItem(q), attributes: [.font: font, .foregroundColor: color]))
    }

    private func renderCompact() -> WidgetDisplayMode {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let r = NSMutableAttributedString()
        if let spy = indexQuotes.first(where: { $0.symbol == "SPY" }) {
            let c = config.coloredTicker ? intensityColor(for: spy.currentChange) : NSColor.headerTextColor
            let tag = (spy.extendedHours?.label).map { " \($0)" } ?? ""
            r.append(NSAttributedString(string: "S&P\(tag) \(spy.currentIsUp ? "\u{25B2}" : "\u{25BC}")\(String(format: "%.1f%%", abs(spy.currentChange)))", attributes: [.font: font, .foregroundColor: c]))
        }
        if let btc = quotes.first(where: { $0.symbol == "BTC" }) {
            if r.length > 0 { r.append(NSAttributedString(string: " | ", attributes: [.font: font, .foregroundColor: NSColor.headerTextColor.withAlphaComponent(0.3)])) }
            let c = config.coloredTicker ? intensityColor(for: btc.change) : NSColor.headerTextColor
            r.append(NSAttributedString(string: "BTC \(btc.isUp ? "\u{25B2}" : "\u{25BC}")\(String(format: "%.1f%%", abs(btc.change)))", attributes: [.font: font, .foregroundColor: c]))
        }
        return r.length > 0 ? .attributedText(r) : .text(lastFetchFailed ? "Market: Offline" : "Loading...")
    }

    private func renderSparkline() -> WidgetDisplayMode {
        let sorted = sortedQuotes()
        guard !sorted.isEmpty else { return .text(lastFetchFailed ? "Market: Offline" : "Loading...") }
        let q = sorted[focusedIndex % sorted.count]
        let chartData = q.chartSeries
        guard chartData.count >= 2 else {
            return renderFocused()
        }
        let label = "\(q.symbol) \(q.currentIsUp ? "\u{25B2}" : "\u{25BC}")\(String(format: "%.1f%%", abs(q.currentChange)))"
        return .sparkline(chartData, label: label, width: CGFloat(config.tickerWidth))
    }

    private func renderPortfolio() -> WidgetDisplayMode {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        if let pv = portfolioSnapshot() {
            let totalStr = formatCurrency(pv.total)
            let plStr = String(format: " %@ (%@%.1f%%)", formatSignedCurrency(pv.dailyPL), pv.dailyPercent >= 0 ? "+" : "", pv.dailyPercent)
            let r = NSMutableAttributedString()
            r.append(NSAttributedString(string: totalStr, attributes: [.font: font, .foregroundColor: Theme.textPrimary]))
            let plColor = intensityColor(for: pv.dailyPercent)
            r.append(NSAttributedString(string: plStr, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: plColor]))
            return .attributedText(r)
        }
        // No holdings - fall back to compact
        return renderCompact()
    }

    func intensityColor(for change: Double) -> NSColor {
        if case .fixed = config.colorMode { return config.accentColor.color }
        let a = Swift.abs(change)
        let alpha: CGFloat = min(0.6 + a * 0.08, 1.0)
        if change >= 0 {
            if a < 0.5 { return NSColor(red: 0.45, green: 0.72, blue: 0.55, alpha: alpha) }
            if a < 2.0 { return NSColor(red: 0.25, green: 0.82, blue: 0.50, alpha: alpha) }
            if a < 5.0 { return NSColor(red: 0.18, green: 0.90, blue: 0.50, alpha: alpha) }
            return NSColor(red: 0.10, green: 0.98, blue: 0.45, alpha: alpha)
        } else {
            if a < 0.5 { return NSColor(red: 0.75, green: 0.48, blue: 0.45, alpha: alpha) }
            if a < 2.0 { return NSColor(red: 0.90, green: 0.38, blue: 0.35, alpha: alpha) }
            if a < 5.0 { return NSColor(red: 0.98, green: 0.28, blue: 0.28, alpha: alpha) }
            return NSColor(red: 1.0, green: 0.18, blue: 0.18, alpha: alpha)
        }
    }

    func chartQuoteForCurrentFocus() -> MarketQuote? {
        let sorted = sortedQuotes()
        guard !sorted.isEmpty else { return nil }
        return sorted[focusedIndex % sorted.count]
    }

    func chartStyle(for quote: MarketQuote, height: CGFloat, pointRadius: CGFloat, showGrid: Bool) -> SparklineRenderer.Style {
        let color = config.coloredTicker ? intensityColor(for: quote.chartChange) : config.accentColor.color
        return SparklineRenderer.Style(
            lineColor: color,
            fillColor: color.withAlphaComponent(showGrid ? 0.08 : 0.04),
            lineWidth: showGrid ? 1.35 : 1.25,
            height: height,
            pointRadius: pointRadius,
            baselineValue: quote.chartBaseline,
            positiveColor: intensityColor(for: abs(quote.chartChange)),
            negativeColor: intensityColor(for: -abs(quote.chartChange)),
            neutralColor: Theme.textMuted,
            baselineColor: Theme.textGhost.withAlphaComponent(showGrid ? 0.32 : 0.16),
            gridColor: Theme.divider.withAlphaComponent(showGrid ? 0.45 : 0.0),
            showGrid: showGrid,
            smooth: false,
            glow: false,
            endPointColor: color
        )
    }

    private func formatTickerItem(_ q: MarketQuote) -> String {
        let sessionText = (q.extendedHours?.label).map { " \($0)" } ?? ""
        var s = "\(q.symbol)\(sessionText) $\(formatPrice(q.currentPrice)) \(q.currentIsUp ? "\u{25B2}" : "\u{25BC}")\(String(format: "%.1f%%", abs(q.currentChange)))"
        if config.showExtendedHours, let ext = q.extendedHours {
            let arrow = ext.change >= 0 ? "\u{25B2}" : "\u{25BC}"
            s += " close:\(arrow)\(String(format: "%.1f%%", abs(ext.change)))"
        }
        return s
    }

    // MARK: - Sorting

    func sortedQuotes() -> [MarketQuote] {
        let stocks = quotes.filter { $0.kind == .stock }
        let crypto = quotes.filter { $0.kind == .crypto }

        let sortedStocks: [MarketQuote]
        let sortedCrypto: [MarketQuote]

        switch config.sortMode {
        case .manual:
            sortedStocks = stocks.sorted { a, b in
                (config.symbols.firstIndex(of: a.symbol) ?? 999) < (config.symbols.firstIndex(of: b.symbol) ?? 999)
            }
            sortedCrypto = crypto.sorted { a, b in
                let ai = config.coins.firstIndex(where: { (coinSymbols[$0] ?? $0.uppercased()) == a.symbol }) ?? 999
                let bi = config.coins.firstIndex(where: { (coinSymbols[$0] ?? $0.uppercased()) == b.symbol }) ?? 999
                return ai < bi
            }
        case .alphabetical:
            sortedStocks = stocks.sorted { $0.symbol < $1.symbol }
            sortedCrypto = crypto.sorted { $0.symbol < $1.symbol }
        case .changeDesc:
            sortedStocks = stocks.sorted { $0.currentChange > $1.currentChange }
            sortedCrypto = crypto.sorted { $0.currentChange > $1.currentChange }
        case .changeAsc:
            sortedStocks = stocks.sorted { $0.currentChange < $1.currentChange }
            sortedCrypto = crypto.sorted { $0.currentChange < $1.currentChange }
        case .priceDesc:
            sortedStocks = stocks.sorted { $0.currentPrice > $1.currentPrice }
            sortedCrypto = crypto.sorted { $0.currentPrice > $1.currentPrice }
        }
        return sortedStocks + sortedCrypto
    }

    // MARK: - Fallback menu

    func buildDropdownMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { [] }
    @objc func noop() {}

    // MARK: - Last Good Data Cache

    private func loadCachedQuotesIfNeeded() {
        guard quotes.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.quoteCacheKey),
              let payload = try? JSONDecoder().decode(QuoteCachePayload.self, from: data)
        else { return }

        let wantedStocks = Set(config.symbols)
        let wantedCrypto = Set(config.coins.map { coinSymbols[$0] ?? String($0.prefix(4)).uppercased() })
        let cachedQuotes = payload.quotes.filter { quote in
            switch quote.kind {
            case .stock: return wantedStocks.contains(quote.symbol)
            case .crypto: return wantedCrypto.contains(quote.symbol)
            }
        }
        guard !cachedQuotes.isEmpty || !payload.indexQuotes.isEmpty else { return }

        quotes = cachedQuotes
        indexQuotes = payload.indexQuotes.filter { Self.indexSymbols.contains($0.symbol) }
        for quote in quotes + indexQuotes {
            previousPrices[quote.symbol] = quote.price
        }
        lastUpdated = payload.lastUpdated
        isUsingCachedData = true
        onDisplayUpdate?()
        onDataRefresh?()
    }

    private func saveQuoteCache() {
        guard !quotes.isEmpty || !indexQuotes.isEmpty else { return }
        let payload = QuoteCachePayload(
            quotes: quotes,
            indexQuotes: indexQuotes,
            lastUpdated: lastUpdated ?? Date()
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.quoteCacheKey)
        }
    }

    // MARK: - JSON Market Parsing

    private func marketDouble(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value.isFinite ? value : nil
        case let value as Float:
            let d = Double(value)
            return d.isFinite ? d : nil
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            let d = value.doubleValue
            return d.isFinite ? d : nil
        case let value as String:
            guard let d = Double(value), d.isFinite else { return nil }
            return d
        default:
            return nil
        }
    }

    private func marketInt(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func marketSeries(_ value: Any?) -> [Double?] {
        if let arr = value as? [Any] {
            return arr.map { marketDouble($0) }
        }
        if let arr = value as? [Double] {
            return arr.map(Optional.some)
        }
        return []
    }

    private func compact(_ series: [Double?]) -> [Double] {
        series.compactMap { $0 }
    }

    private func lastClose(timestamps: [Int], closes: [Double?], where predicate: (Int) -> Bool) -> Double? {
        guard !timestamps.isEmpty, !closes.isEmpty else { return nil }
        var result: Double?
        for (i, ts) in timestamps.enumerated() where predicate(ts) {
            if i < closes.count, let close = closes[i] {
                result = close
            }
        }
        return result
    }

    private func percentChange(from baseline: Double, to current: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return (current - baseline) / baseline * 100
    }

    // MARK: - Fetching

    private var lastStockFetch: Date?
    private var lastCryptoFetch: Date?

    private func fetchAll(force: Bool = false) {
        // While an endpoint is throttling us, only an explicit refresh gets through.
        guard force || !isBackingOff else { return }

        let now = Date()
        let stocksDue = force || lastStockFetch.map { now.timeIntervalSince($0) >= stockRefreshInterval } ?? true
        let cryptoDue = force || lastCryptoFetch.map { now.timeIntervalSince($0) >= cryptoRefreshInterval } ?? true

        if stocksDue {
            lastStockFetch = now
            for s in config.symbols { fetchStock(symbol: s, force: force) }
            for idx in Self.indexSymbols where !config.symbols.contains(idx) { fetchIndex(symbol: idx, force: force) }
        }
        if cryptoDue, !config.coins.isEmpty {
            lastCryptoFetch = now
            fetchCrypto(force: force)
        }
    }

    private func fetchStock(symbol: String, force: Bool = false) {
        let safe = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(safe)?interval=1m&range=1d&includePrePost=true") else { return }
        DataFetcher.shared.fetch(url: url, maxAge: force ? 0 : quoteCacheAge) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.noteFetchSuccess()
                self.parseStock(data: data, symbol: symbol, isIndex: false)
            case .failure(let error):
                self.noteFetchFailure(error)
                DispatchQueue.main.async {
                    // A throttled host is a whole-feed problem, not a bad ticker,
                    // so don't brand the symbol as failed for it.
                    if !self.isBackingOff { self.failedSymbols.insert(symbol) }
                    self.lastFetchFailed = true
                    self.onDisplayUpdate?()
                    self.onDataRefresh?()
                }
            }
        }
    }

    private func fetchIndex(symbol: String, force: Bool = false) {
        let safe = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(safe)?interval=1m&range=1d&includePrePost=true") else { return }
        DataFetcher.shared.fetch(url: url, maxAge: force ? 0 : quoteCacheAge) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.noteFetchSuccess()
                self.parseStock(data: data, symbol: symbol, isIndex: true)
            case .failure(let error):
                self.noteFetchFailure(error)
            }
        }
    }

    private func parseStock(data: Data, symbol: String, isIndex: Bool) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = json["chart"] as? [String: Any],
                  let results = chart["result"] as? [[String: Any]],
                  let first = results.first,
                  let meta = first["meta"] as? [String: Any] else {
                DispatchQueue.main.async {
                    self.failedSymbols.insert(symbol)
                    self.lastFetchFailed = true
                    self.onDataRefresh?()
                }
                return
            }

            var dayHigh: Double?, dayLow: Double?, volume: Double?, sparkline: [Double] = []
            let timestamps = (first["timestamp"] as? [Any])?.compactMap { marketInt($0) } ?? []

            var preStart: Int = 0, preEnd: Int = 0
            var regularStart: Int = 0, regularEnd: Int = 0
            var postStart: Int = 0, postEnd: Int = 0
            if let ctp = meta["currentTradingPeriod"] as? [String: Any],
               let pre = ctp["pre"] as? [String: Any],
               let reg = ctp["regular"] as? [String: Any],
               let post = ctp["post"] as? [String: Any] {
                preStart = marketInt(pre["start"]) ?? 0
                preEnd = marketInt(pre["end"]) ?? 0
                regularStart = marketInt(reg["start"]) ?? 0
                regularEnd = marketInt(reg["end"]) ?? 0
                postStart = marketInt(post["start"]) ?? 0
                postEnd = marketInt(post["end"]) ?? 0
            } else if let ctp = meta["currentTradingPeriod"] as? [String: Any],
                      let reg = ctp["regular"] as? [String: Any] {
                regularStart = marketInt(reg["start"]) ?? 0
                regularEnd = marketInt(reg["end"]) ?? 0
            }

            let previousClose = marketDouble(meta["chartPreviousClose"])
                ?? marketDouble(meta["previousClose"])
                ?? marketDouble(meta["regularMarketPreviousClose"])
            guard let prev = previousClose else {
                DispatchQueue.main.async {
                    self.failedSymbols.insert(symbol)
                    self.lastFetchFailed = true
                    self.onDataRefresh?()
                }
                return
            }

            let marketCap = marketDouble(meta["marketCap"])
            let fiftyTwoHigh = marketDouble(meta["fiftyTwoWeekHigh"])
            let fiftyTwoLow = marketDouble(meta["fiftyTwoWeekLow"])
            let regularDayHigh = marketDouble(meta["regularMarketDayHigh"])
            let regularDayLow = marketDouble(meta["regularMarketDayLow"])
            let openPrice = marketDouble(meta["regularMarketOpen"]) ?? prev
            let peRatio = marketDouble(meta["trailingPE"]) ?? marketDouble(meta["forwardPE"]) ?? marketDouble(meta["peRatio"])
            let marketState = (meta["marketState"] as? String)?.uppercased()
            let quoteStatus = MarketStatus.fromYahooMarketState(marketState) ?? MarketStatus.current()

            var allCloses: [Double?] = []
            if let ind = first["indicators"] as? [String: Any],
               let qa = ind["quote"] as? [[String: Any]], let qd = qa.first {
                allCloses = marketSeries(qd["close"])
                sparkline = compact(allCloses)
                let highs = compact(marketSeries(qd["high"]))
                let lows = compact(marketSeries(qd["low"]))
                let vols = compact(marketSeries(qd["volume"]))
                if !highs.isEmpty { dayHigh = highs.max() }
                if !lows.isEmpty { dayLow = lows.min() }
                if !vols.isEmpty { volume = vols.reduce(0, +) }
            }
            if let rdh = regularDayHigh { dayHigh = rdh }
            if let rdl = regularDayLow { dayLow = rdl }

            let regularFromSeries = lastClose(timestamps: timestamps, closes: allCloses) { ts in
                regularStart > 0 && regularEnd > 0 && ts >= regularStart && ts < regularEnd
            }
            let rawRegularPrice = marketDouble(meta["regularMarketPrice"])

            sparkline = sampleSparkline(sparkline, count: 48)

            // Extended hours
            var prePrice: Double?, preChgPct: Double?
            var postPrice: Double?, postChgPct: Double?

            let preFromMeta = marketDouble(meta["preMarketPrice"])
            let preFromSeries = lastClose(timestamps: timestamps, closes: allCloses) { ts in
                if preStart > 0 && preEnd > 0 { return ts >= preStart && ts < preEnd }
                return regularStart > 0 && ts < regularStart
            }
            let preFromRegularMeta: Double?
            if quoteStatus == .preMarket, let rawRegularPrice, abs(rawRegularPrice - prev) > 0.000001 {
                preFromRegularMeta = rawRegularPrice
            } else {
                preFromRegularMeta = nil
            }
            let selectedPrePrice = quoteStatus == .preMarket ? (preFromSeries ?? preFromMeta ?? preFromRegularMeta) : (preFromMeta ?? preFromSeries)
            if let pp = selectedPrePrice {
                prePrice = pp
                preChgPct = percentChange(from: prev, to: pp)
            }

            let price: Double
            if case .preMarket = quoteStatus, prePrice != nil {
                price = regularFromSeries ?? prev
            } else {
                price = regularFromSeries ?? rawRegularPrice ?? prev
            }
            let pct = percentChange(from: prev, to: price)

            let postFromMeta = marketDouble(meta["postMarketPrice"])
            let postFromSeries = lastClose(timestamps: timestamps, closes: allCloses) { ts in
                if postStart > 0 && postEnd > 0 { return ts >= postStart && ts < postEnd }
                return regularEnd > 0 && ts >= regularEnd
            }
            let selectedPostPrice = quoteStatus == .afterHours ? (postFromSeries ?? postFromMeta) : (postFromMeta ?? postFromSeries)
            if let pp = selectedPostPrice {
                postPrice = pp
                postChgPct = percentChange(from: price, to: pp)
            }

            let displayTail: Double
            switch quoteStatus {
            case .preMarket:
                displayTail = prePrice ?? price
            case .afterHours:
                displayTail = postPrice ?? price
            case .open, .closed:
                displayTail = price
            }
            if sparkline.isEmpty { sparkline = [prev, displayTail] }
            if !sparkline.isEmpty { sparkline[sparkline.count - 1] = displayTail }

            let q = MarketQuote(symbol: symbol, price: price, change: pct, kind: .stock,
                                previousClose: prev, dayHigh: dayHigh, dayLow: dayLow, volume: volume, sparkline: sparkline,
                                marketCap: marketCap, fiftyTwoWeekHigh: fiftyTwoHigh,
                                fiftyTwoWeekLow: fiftyTwoLow, openPrice: openPrice, peRatio: peRatio,
                                preMarketPrice: prePrice, preMarketChange: preChgPct,
                                postMarketPrice: postPrice, postMarketChange: postChgPct,
                                marketState: marketState)
            DispatchQueue.main.async {
                self.failedSymbols.remove(symbol)
                self.lastFetchFailed = false
                self.isUsingCachedData = false
                self.checkPriceAlert(symbol: symbol, newPrice: q.currentPrice)
                if isIndex {
                    self.indexQuotes.removeAll { $0.symbol == symbol }
                    self.indexQuotes.append(q)
                    if self.config.symbols.contains(symbol) {
                        self.quotes.removeAll { $0.symbol == symbol && $0.kind == .stock }
                        self.quotes.append(q)
                    }
                } else {
                    self.quotes.removeAll { $0.symbol == symbol && $0.kind == .stock }
                    self.quotes.append(q)
                    if Self.indexSymbols.contains(symbol) {
                        self.indexQuotes.removeAll { $0.symbol == symbol }
                        self.indexQuotes.append(q)
                    }
                }
                self.previousPrices[symbol] = q.currentPrice
                self.lastUpdated = Date()
                self.saveQuoteCache()
                self.onDisplayUpdate?()
                self.onDataRefresh?()
            }
        } catch {
            DispatchQueue.main.async {
                self.failedSymbols.insert(symbol)
                self.lastFetchFailed = true
                self.onDataRefresh?()
            }
        }
    }

    private func fetchCrypto(force: Bool = false) {
        let ids = config.coins.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://api.coingecko.com/api/v3/coins/markets?vs_currency=\(config.cryptoCurrency)&ids=\(ids)&sparkline=true&price_change_percentage=24h") else { return }
        DataFetcher.shared.fetch(url: url, maxAge: force ? 0 : cryptoCacheAge) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.noteFetchSuccess()
                self.parseCrypto(data: data)
            case .failure(let error):
                self.noteFetchFailure(error)
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    self.onDataRefresh?()
                    if self.quotes.isEmpty { self.onDisplayUpdate?() }
                }
            }
        }
    }

    private func parseCrypto(data: Data) {
        do {
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var results: [MarketQuote] = []
            for cd in arr {
                guard let coinId = cd["id"] as? String else { continue }
                let sym = coinSymbols[coinId] ?? String(coinId.prefix(4)).uppercased()
                let currentPrice = cd["current_price"] as? Double ?? 0
                var sparkline: [Double] = []
                if let so = cd["sparkline_in_7d"] as? [String: Any], let p = so["price"] as? [Double] {
                    sparkline = sampleSparkline(p, count: 48)
                }
                if !sparkline.isEmpty, currentPrice > 0 {
                    sparkline[sparkline.count - 1] = currentPrice
                }
                results.append(MarketQuote(symbol: sym, price: currentPrice,
                    change: cd["price_change_percentage_24h"] as? Double ?? 0, kind: .crypto,
                    dayHigh: cd["high_24h"] as? Double, dayLow: cd["low_24h"] as? Double,
                    volume: cd["total_volume"] as? Double, sparkline: sparkline,
                    marketCap: cd["market_cap"] as? Double))
            }
            DispatchQueue.main.async {
                for q in results { self.checkPriceAlert(symbol: q.symbol, newPrice: q.price) }
                self.lastFetchFailed = false
                self.isUsingCachedData = false
                self.quotes.removeAll { $0.kind == .crypto }
                self.quotes.append(contentsOf: results)
                for q in results { self.previousPrices[q.symbol] = q.price }
                self.lastUpdated = Date()
                self.saveQuoteCache()
                self.onDisplayUpdate?()
                self.onDataRefresh?()
            }
        } catch {
            DispatchQueue.main.async {
                self.lastFetchFailed = true
                self.onDataRefresh?()
            }
        }
    }

    private func sampleSparkline(_ data: [Double], count: Int) -> [Double] {
        guard data.count > count else { return data }
        let step = Double(data.count - 1) / Double(count - 1)
        return (0..<count).map { data[min(Int(Double($0) * step), data.count - 1)] }
    }

    // MARK: - Price Alerts

    private func checkPriceAlert(symbol: String, newPrice: Double) {
        guard let target = config.priceAlerts[symbol] else { return }
        guard let oldPrice = previousPrices[symbol] else { return }
        let crossedAbove = oldPrice < target && newPrice >= target
        let crossedBelow = oldPrice > target && newPrice <= target
        guard crossedAbove || crossedBelow else { return }

        let direction = crossedAbove ? "above" : "below"
        let content = UNMutableNotificationContent()
        content.title = "\(symbol) Price Alert"
        content.body = "\(symbol) is now $\(formatPrice(newPrice)) - crossed \(direction) $\(formatPrice(target))"
        content.sound = .default

        let req = UNNotificationRequest(identifier: "barista.alert.\(symbol).\(Int(Date().timeIntervalSince1970))",
                                         content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)

        config.priceAlerts.removeValue(forKey: symbol)
        saveConfig()
    }

    // MARK: - Symbol Management

    func addSymbol(_ input: String) {
        let rawTokens = input
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == ";" }
            .map(String.init)
        if rawTokens.count > 1 {
            rawTokens.forEach { addSymbol($0) }
            return
        }

        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        let upper = trimmed.uppercased()
        if let coinID = symbolToCoinID[upper] { addCoin(coinID); return }
        if coinSymbols[trimmed.lowercased()] != nil { addCoin(trimmed.lowercased()); return }
        guard !upper.isEmpty, upper.range(of: #"^[A-Z0-9.\-=^]{1,16}$"#, options: .regularExpression) != nil else { return }
        guard !config.symbols.contains(upper) else { return }
        config.symbols.append(upper)
        saveConfig()
        onDisplayUpdate?()
        onDataRefresh?()
        fetchStock(symbol: upper, force: true)
    }

    func addCoin(_ coinId: String) {
        let coin = coinId.lowercased()
        guard !coin.isEmpty, !config.coins.contains(coin) else { return }
        config.coins.append(coin)
        saveConfig()
        onDisplayUpdate?()
        onDataRefresh?()
        fetchCrypto(force: true)
    }

    func removeQuote(_ symbol: String, kind: MarketQuote.Kind) {
        if kind == .stock {
            config.symbols.removeAll { $0 == symbol }
            config.holdings.removeValue(forKey: symbol)
            config.costBasis.removeValue(forKey: symbol)
            config.priceAlerts.removeValue(forKey: symbol)
            quotes.removeAll { $0.symbol == symbol && $0.kind == .stock }
            failedSymbols.remove(symbol)
        } else {
            let coinId = symbolToCoinID[symbol] ?? symbol.lowercased()
            config.coins.removeAll { $0 == coinId || (coinSymbols[$0] ?? "") == symbol }
            config.holdings.removeValue(forKey: symbol)
            config.costBasis.removeValue(forKey: symbol)
            config.priceAlerts.removeValue(forKey: symbol)
            quotes.removeAll { $0.symbol == symbol && $0.kind == .crypto }
        }
        saveConfig()
        DispatchQueue.main.async { self.onDisplayUpdate?(); self.onDataRefresh?() }
    }

    /// Sets share count and, optionally, the average price paid.
    /// Pass `averageCost: nil` to leave any existing cost untouched; pass 0 to clear it.
    func setHolding(symbol: String, kind: MarketQuote.Kind, quantity rawQuantity: Double,
                    averageCost rawCost: Double? = nil) {
        let normalized = symbol.uppercased()
        let quantity = rawQuantity.isFinite ? max(0, rawQuantity) : 0
        if quantity > 0 {
            config.holdings[normalized] = quantity
            if let rawCost {
                let cost = rawCost.isFinite ? max(0, rawCost) : 0
                if cost > 0 {
                    config.costBasis[normalized] = cost
                } else {
                    config.costBasis.removeValue(forKey: normalized)
                }
            }
            if kind == .stock, !config.symbols.contains(normalized), !Self.indexSymbols.contains(normalized) {
                config.symbols.append(normalized)
            }
        } else {
            config.holdings.removeValue(forKey: normalized)
            config.costBasis.removeValue(forKey: normalized)
        }
        saveConfig()
        onDisplayUpdate?()
        onDataRefresh?()
        if quantity > 0 {
            refreshQuoteNow(symbol: normalized, kind: kind)
        }
    }

    func setCash(_ rawAmount: Double) {
        config.cash = rawAmount.isFinite ? max(0, rawAmount) : 0
        saveConfig()
        onDisplayUpdate?()
        onDataRefresh?()
    }

    // MARK: - Portfolio Management

    var activePortfolioName: String {
        config.activePortfolio?.name ?? Portfolio.fallbackName
    }

    var canAddPortfolio: Bool {
        config.portfolios.count < Portfolio.maxCount
    }

    private func portfoliosChanged() {
        saveConfig()
        onDisplayUpdate?()
        onDataRefresh?()
    }

    func selectPortfolio(id: String) {
        guard id != config.activePortfolioID,
              config.portfolios.contains(where: { $0.id == id }) else { return }
        config.activePortfolioID = id
        portfoliosChanged()
    }

    /// Creates an empty portfolio and makes it active. Returns false at the cap.
    @discardableResult
    func addPortfolio(named rawName: String) -> Bool {
        guard canAddPortfolio else { return false }
        let created = Portfolio(name: Portfolio.sanitize(name: rawName))
        config.portfolios.append(created)
        config.activePortfolioID = created.id
        portfoliosChanged()
        return true
    }

    func renameActivePortfolio(to rawName: String) {
        let idx = config.activePortfolioIndex
        guard config.portfolios.indices.contains(idx) else { return }
        config.portfolios[idx].name = Portfolio.sanitize(name: rawName)
        portfoliosChanged()
    }

    /// Deletes a portfolio, selecting a neighbour if it was active.
    /// The last remaining portfolio is never deleted.
    @discardableResult
    func deletePortfolio(id: String) -> Bool {
        guard config.portfolios.count > 1,
              let idx = config.portfolios.firstIndex(where: { $0.id == id }) else { return false }
        let wasActive = config.activePortfolioID == id
        config.portfolios.remove(at: idx)
        if wasActive {
            config.activePortfolioID = config.portfolios[max(0, idx - 1)].id
        }
        PortfolioHistoryService.shared.forget(portfolioID: id)
        portfoliosChanged()
        return true
    }

    private func refreshQuoteNow(symbol: String, kind: MarketQuote.Kind) {
        switch kind {
        case .stock:
            fetchStock(symbol: symbol, force: true)
        case .crypto:
            fetchCrypto(force: true)
        }
    }

    func refreshNow() {
        onDisplayUpdate?()
        onDataRefresh?()
        fetchAll(force: true)
    }

    // MARK: - Portfolio

    func portfolioSnapshot() -> PortfolioSnapshot? {
        let cash = max(0, config.cash)
        guard !config.holdings.isEmpty || cash > 0 else { return nil }
        var positions: [PortfolioPosition] = []
        var missing: [String] = []

        let costs = config.costBasis
        for (sym, qty) in config.holdings.sorted(by: { $0.key < $1.key }) where qty > 0 {
            if let q = portfolioQuote(for: sym) {
                let avg = costs[sym].flatMap { $0 > 0 ? $0 : nil }
                positions.append(PortfolioPosition(quote: q, quantity: qty, averageCost: avg))
            } else {
                missing.append(sym)
            }
        }

        let positionsValue = positions.map(\.value).reduce(0, +)
        let total = positionsValue + cash
        let baselineTotal = positions.map(\.baselineValue).reduce(0, +) + cash
        let dailyPL = positions.map(\.dailyPL).reduce(0, +)
        guard total > 0 else { return nil }
        return PortfolioSnapshot(positions: positions, missingSymbols: missing, cash: cash, total: total, baselineTotal: baselineTotal, dailyPL: dailyPL)
    }

    private func portfolioQuote(for symbol: String) -> MarketQuote? {
        let normalized = symbol.uppercased()
        if let quote = quotes.first(where: { $0.symbol.uppercased() == normalized }) {
            return quote
        }
        return indexQuotes.first(where: { $0.symbol.uppercased() == normalized })
    }

    func portfolioValue() -> (total: Double, dailyPL: Double)? {
        guard let snapshot = portfolioSnapshot() else { return nil }
        return (snapshot.total, snapshot.dailyPL)
    }

    func portfolioChangePercent(total: Double, dailyPL: Double) -> Double {
        let baseline = total - dailyPL
        guard baseline > 0 else { return 0 }
        return (dailyPL / baseline) * 100
    }

    func marketBreadth() -> MarketBreadth? {
        let items = sortedQuotes()
        guard !items.isEmpty else { return nil }
        let advancing = items.filter { $0.currentChange > 0.05 }.count
        let declining = items.filter { $0.currentChange < -0.05 }.count
        let flat = items.count - advancing - declining
        let average = items.map(\.currentChange).reduce(0, +) / Double(items.count)
        return MarketBreadth(
            advancing: advancing,
            declining: declining,
            flat: flat,
            averageChange: average,
            leader: items.max { $0.currentChange < $1.currentChange },
            laggard: items.min { $0.currentChange < $1.currentChange }
        )
    }

    func freshnessDescription(now: Date = Date()) -> String {
        // Being throttled is the more useful thing to say - it explains why the
        // numbers stopped moving, which a plain "Cached 4m ago" does not.
        if isBackingOff {
            let secs = Int(backoffRemaining.rounded())
            return secs >= 60 ? "Throttled - retry \(secs / 60)m" : "Throttled - retry \(secs)s"
        }
        guard let lastUpdated else { return lastFetchFailed ? "Offline" : "Loading" }
        let age = max(0, now.timeIntervalSince(lastUpdated))
        let prefix = isUsingCachedData || lastFetchFailed ? "Cached" : "Updated"
        if age < 60 { return "\(prefix) \(Int(age))s ago" }
        if age < 3600 { return "\(prefix) \(Int(age / 60))m ago" }
        return "\(prefix) \(Int(age / 3600))h ago"
    }

    func freshnessColor(now: Date = Date()) -> NSColor {
        if isBackingOff { return Theme.red }
        guard let lastUpdated else { return lastFetchFailed ? Theme.red : Theme.textGhost }
        let age = now.timeIntervalSince(lastUpdated)
        if lastFetchFailed || isUsingCachedData { return Theme.brandAmber }
        if age > max(effectiveRefreshInterval * 4, 20) { return Theme.brandAmber }
        return Theme.textGhost
    }

    // MARK: - Formatting

    func formatPrice(_ price: Double) -> String {
        if price >= 10000 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: price)) ?? String(format: "%.0f", price)
        }
        if price >= 100 { return String(format: "%.1f", price) }
        if price >= 1 { return String(format: "%.2f", price) }
        if price >= 0.01 { return String(format: "%.4f", price) }
        return String(format: "%.6f", price)
    }

    func formatCurrency(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    func formatSignedCurrency(_ amount: Double) -> String {
        return "\(amount >= 0 ? "+" : "-")\(formatCurrency(abs(amount)))"
    }

    static func compactNumber(_ v: Double) -> String {
        if v >= 1e12 { return String(format: "%.1fT", v / 1e12) }
        if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return String(format: "%.0f", v)
    }

    func openInBrowser(symbol: String, kind: MarketQuote.Kind) {
        let urlStr: String
        if kind == .crypto {
            let coinId = symbolToCoinID[symbol] ?? symbol.lowercased()
            urlStr = "https://www.coingecko.com/en/coins/\(coinId)"
        } else {
            urlStr = "https://finance.yahoo.com/quote/\(symbol)"
        }
        if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Cycleable

extension StockTickerWidget: Cycleable {
    var itemCount: Int {
        let needsCycle = config.displayMode == .focused || config.displayMode == .sparkline
        return needsCycle ? max(sortedQuotes().count, 1) : 1
    }
    var currentIndex: Int { focusedIndex }
    var cycleInterval: TimeInterval {
        let needsCycle = config.displayMode == .focused || config.displayMode == .sparkline
        return needsCycle ? config.focusCycleSeconds : 0
    }
    func cycleNext() { let c = sortedQuotes().count; if c > 0 { focusedIndex = (focusedIndex + 1) % c } }
}

// MARK: - Interactive Dropdown

extension StockTickerWidget: InteractiveDropdown {
    var dropdownSize: NSSize { NSSize(width: 420, height: 560) }

    func buildDropdownPopover() -> NSView {
        let vc = MarketPopoverController(widget: self)
        self.popoverVC = vc
        return vc.buildView()
    }
}

// MARK: - DeclarativeConfig

extension StockTickerWidget: DeclarativeConfig {
    func configFields() -> [ConfigField] {
        [
            .section(title: "Display"),
            .picker(label: "Display Mode", key: "displayMode", options: [
                (title: "Scrolling Ticker", value: "scrolling"),
                (title: "Focused (one at a time)", value: "focused"),
                (title: "Compact (S&P + BTC)", value: "compact"),
                (title: "Sparkline Chart", value: "sparkline"),
                (title: "Portfolio Value", value: "portfolio"),
            ], get: { [weak self] in self?.config.displayMode.rawValue ?? "scrolling" },
               set: { [weak self] in self?.config.displayMode = TickerDisplayMode(rawValue: $0) ?? .scrolling }),

            .picker(label: "Color Mode", key: "colorMode", options: [
                (title: "Dynamic (green/red intensity)", value: "dynamic"),
                (title: "Fixed Accent Color", value: "fixed"),
            ], get: { [weak self] in self?.config.colorMode.rawValue ?? "dynamic" },
               set: { [weak self] in self?.config.colorMode = TickerColorMode(rawValue: $0) ?? .dynamic }),

            .picker(label: "Accent Color", key: "accentColor", options: [
                (title: "Blue", value: "blue"),
                (title: "Cyan", value: "cyan"),
                (title: "Green", value: "green"),
                (title: "Amber", value: "amber"),
                (title: "Purple", value: "purple"),
                (title: "Red", value: "red"),
                (title: "White", value: "white"),
            ], get: { [weak self] in self?.config.accentColor.rawValue ?? "green" },
               set: { [weak self] in self?.config.accentColor = TickerAccentPreset(rawValue: $0) ?? .green }),

            .section(title: "Ticker Bar"),
            .slider(label: "Ticker Width", key: "tickerWidth", min: 80, max: 500, step: 10,
                    get: { [weak self] in self?.config.tickerWidth ?? 200 },
                    set: { [weak self] in self?.config.tickerWidth = $0 },
                    format: "%.0f px"),
            .slider(label: "Scroll Speed", key: "scrollSpeed", min: 0.1, max: 2.0, step: 0.1,
                    get: { [weak self] in self?.config.scrollSpeed ?? 0.3 },
                    set: { [weak self] in self?.config.scrollSpeed = $0 },
                    format: "%.1f x"),
            .slider(label: "Focus Cycle", key: "focusCycleSeconds", min: 2, max: 15, step: 1,
                    get: { [weak self] in self?.config.focusCycleSeconds ?? 5 },
                    set: { [weak self] in self?.config.focusCycleSeconds = $0 },
                    format: "%.0f s"),

            .section(title: "Data"),
            .toggle(label: "Show Volume", key: "showVolume",
                    get: { [weak self] in self?.config.showVolume ?? true },
                    set: { [weak self] in self?.config.showVolume = $0 }),
            .toggle(label: "Show Market Cap", key: "showMarketCap",
                    get: { [weak self] in self?.config.showMarketCap ?? true },
                    set: { [weak self] in self?.config.showMarketCap = $0 }),
            .toggle(label: "Show Day Range", key: "showDayRange",
                    get: { [weak self] in self?.config.showDayRange ?? true },
                    set: { [weak self] in self?.config.showDayRange = $0 }),
            .toggle(label: "Show Sparkline Charts", key: "showSparklines",
                    get: { [weak self] in self?.config.showSparklines ?? true },
                    set: { [weak self] in self?.config.showSparklines = $0 }),
            .toggle(label: "Show P/E Ratio", key: "showPERatio",
                    get: { [weak self] in self?.config.showPERatio ?? false },
                    set: { [weak self] in self?.config.showPERatio = $0 }),
            .toggle(label: "Show Extended Hours", key: "showExtendedHours",
                    get: { [weak self] in self?.config.showExtendedHours ?? true },
                    set: { [weak self] in self?.config.showExtendedHours = $0 }),
            .toggle(label: "Show Major Indices", key: "showIndices",
                    get: { [weak self] in self?.config.showIndices ?? true },
                    set: { [weak self] in self?.config.showIndices = $0 }),
            .toggle(label: "Colored Ticker Text", key: "coloredTicker",
                    get: { [weak self] in self?.config.coloredTicker ?? true },
                    set: { [weak self] in self?.config.coloredTicker = $0 }),

            .section(title: "Sorting"),
            .picker(label: "Sort Order", key: "sortMode", options: [
                (title: "Manual (watchlist order)", value: "manual"),
                (title: "Alphabetical (A-Z)", value: "alphabetical"),
                (title: "Best Performers First", value: "changeDesc"),
                (title: "Worst Performers First", value: "changeAsc"),
                (title: "Highest Price First", value: "priceDesc"),
            ], get: { [weak self] in self?.config.sortMode.rawValue ?? "manual" },
               set: { [weak self] in self?.config.sortMode = TickerSortMode(rawValue: $0) ?? .manual }),

            .section(title: "Sampling"),
            .slider(label: "Refresh Rate", key: "refreshInterval", min: 5, max: 60, step: 5,
                    get: { [weak self] in self?.config.refreshInterval ?? 5 },
                    set: { [weak self] in self?.config.refreshInterval = $0 },
                    format: "%.0f s"),
        ]
    }
}

// MARK: - Shared Popover View

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
