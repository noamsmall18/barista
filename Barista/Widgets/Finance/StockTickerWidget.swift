import Cocoa

// MARK: - Stock Quote

struct StockQuote {
    let symbol: String
    let price: Double
    let change: Double

    var isUp: Bool { change >= 0 }
    var arrow: String { isUp ? "+" : "" }

    var formatted: String {
        String(format: "%@ $%.2f %@%.1f%%", symbol, price, isUp ? "+" : "", change)
    }
}

// MARK: - Stock Ticker Config

struct StockTickerConfig: Codable, Equatable {
    var symbols: [String]
    var scrollSpeed: Double
    var coloredTicker: Bool
    var refreshInterval: TimeInterval
    var tickerWidth: Double

    static let `default` = StockTickerConfig(
        symbols: ["DUOL", "HIMS", "NOW", "PGY", "QQQ", "SPY"],
        scrollSpeed: 0.3,
        coloredTicker: true,
        refreshInterval: 60,
        tickerWidth: 160
    )
}

// MARK: - Stock Ticker Widget

class StockTickerWidget: BaristaWidget {
    static let widgetID = "stock-ticker"
    static let displayName = "Stock Ticker"
    static let subtitle = "Live scrolling stock prices"
    static let iconName = "chart.line.uptrend.xyaxis"
    static let category = WidgetCategory.finance
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = StockTickerConfig.default

    var config: StockTickerConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshInterval }

    private(set) var quotes: [StockQuote] = []
    private(set) var lastFetchFailed = false
    private var timer: Timer?

    required init(config: StockTickerConfig) {
        self.config = config
    }

    func start() {
        fetchAll()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchAll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func render() -> WidgetDisplayMode {
        guard !quotes.isEmpty else {
            return .text(lastFetchFailed ? "Stocks: Offline" : "Loading...")
        }

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let separator = "    "

        if config.coloredTicker {
            let result = NSMutableAttributedString()
            for (i, q) in quotes.enumerated() {
                let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
                let text = String(format: "%@ $%.2f %@%.1f%%", q.symbol, q.price, arrow, abs(q.change))
                let color = Theme.colorForChange(q.change)
                result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
                if i < quotes.count - 1 {
                    result.append(NSAttributedString(string: separator, attributes: [.font: font, .foregroundColor: NSColor.headerTextColor.withAlphaComponent(0.3)]))
                }
            }
            result.append(NSAttributedString(string: separator, attributes: [.font: font, .foregroundColor: NSColor.headerTextColor.withAlphaComponent(0.3)]))
            return .scrollingText(result, width: CGFloat(config.tickerWidth))
        } else {
            let parts = quotes.map { q -> String in
                let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
                return String(format: "%@ $%.2f %@%.1f%%", q.symbol, q.price, arrow, abs(q.change))
            }
            let text = parts.joined(separator: separator) + separator
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.headerTextColor])
            return .scrollingText(attr, width: CGFloat(config.tickerWidth))
        }
    }

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let white = NSColor.white
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .bold)

        // Header
        let header = NSMenuItem(title: "", action: #selector(StockTickerWidget.noop), keyEquivalent: "")
        header.target = self
        header.attributedTitle = NSAttributedString(string: "WATCHLIST", attributes: [.font: headerFont, .foregroundColor: white.withAlphaComponent(0.5)])
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Stock items
        for q in quotes {
            let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
            let color = Theme.colorForChange(q.change)
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: "\(q.symbol)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: white]))
            text.append(NSAttributedString(string: String(format: "    $%.2f    ", q.price), attributes: [.font: font, .foregroundColor: white]))
            text.append(NSAttributedString(string: String(format: "%@%.2f%%", arrow, abs(q.change)), attributes: [.font: font, .foregroundColor: color]))
            let item = NSMenuItem(title: "", action: #selector(StockTickerWidget.noop), keyEquivalent: "")
            item.target = self
            item.attributedTitle = text
            menu.addItem(item)
        }

        if quotes.isEmpty {
            let item = NSMenuItem(title: "", action: #selector(StockTickerWidget.noop), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: "Loading...", attributes: [.font: font, .foregroundColor: white])
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Average
        if !quotes.isEmpty {
            let avg = quotes.map(\.change).reduce(0, +) / Double(quotes.count)
            let avgColor = Theme.colorForChange(avg)
            let avgText = NSMutableAttributedString()
            avgText.append(NSAttributedString(string: "Avg: ", attributes: [.font: font, .foregroundColor: white]))
            avgText.append(NSAttributedString(string: String(format: "%@%.2f%%", avg >= 0 ? "+" : "", avg), attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: avgColor]))
            let avgItem = NSMenuItem(title: "", action: #selector(StockTickerWidget.noop), keyEquivalent: "")
            avgItem.target = self
            avgItem.attributedTitle = avgText
            menu.addItem(avgItem)
            menu.addItem(NSMenuItem.separator())
        }

        let settingsItem = NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ",")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] {
        // Will be built out in the settings phase
        return []
    }

    // MARK: - Fetching

    private func fetchAll() {
        for symbol in config.symbols {
            fetchSingle(symbol: symbol)
        }
    }

    private func fetchSingle(symbol: String) {
        let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=1d"
        guard let url = URL(string: urlStr) else { return }

        DataFetcher.shared.fetch(url: url, maxAge: max(config.refreshInterval * 0.8, 10)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.parseQuote(data: data, symbol: symbol)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.quotes.isEmpty { self.onDisplayUpdate?() }
                }
            }
        }
    }

    private func parseQuote(data: Data, symbol: String) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let chart = json["chart"] as? [String: Any],
               let results = chart["result"] as? [[String: Any]],
               let meta = results.first?["meta"] as? [String: Any],
               let price = meta["regularMarketPrice"] as? Double,
               let prev = meta["chartPreviousClose"] as? Double {
                let pct = prev > 0 ? (price - prev) / prev * 100 : 0
                let quote = StockQuote(symbol: symbol, price: price, change: pct)
                DispatchQueue.main.async {
                    if let idx = self.quotes.firstIndex(where: { $0.symbol == symbol }) {
                        self.quotes[idx] = quote
                    } else {
                        self.quotes.append(quote)
                        self.quotes.sort { a, b in
                            (self.config.symbols.firstIndex(of: a.symbol) ?? 0) < (self.config.symbols.firstIndex(of: b.symbol) ?? 0)
                        }
                    }
                    self.onDisplayUpdate?()
                }
            }
        } catch {}
    }

    @objc func noop() {}

    // MARK: - Symbol Management

    func addSymbol(_ symbol: String) {
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty, !config.symbols.contains(sym) else { return }
        config.symbols.append(sym)
        fetchSingle(symbol: sym)
    }

    func removeSymbol(_ symbol: String) {
        config.symbols.removeAll { $0 == symbol }
        quotes.removeAll { $0.symbol == symbol }
        DispatchQueue.main.async { self.onDisplayUpdate?() }
    }
}
