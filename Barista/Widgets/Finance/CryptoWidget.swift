import Cocoa

struct CryptoConfig: Codable, Equatable {
    var coins: [String]
    var currency: String
    var showChange: Bool
    var coloredTicker: Bool
    var scrollSpeed: Double
    var tickerWidth: Double
    var refreshInterval: TimeInterval

    static let `default` = CryptoConfig(
        coins: ["bitcoin", "ethereum"],
        currency: "usd",
        showChange: true,
        coloredTicker: true,
        scrollSpeed: 0.3,
        tickerWidth: 160,
        refreshInterval: 60
    )
}

struct CryptoQuote {
    let coin: String
    let symbol: String
    let price: Double
    let change: Double

    var isUp: Bool { change >= 0 }
}

class CryptoWidget: BaristaWidget {
    static let widgetID = "crypto"
    static let displayName = "Crypto Tracker"
    static let subtitle = "Live cryptocurrency prices"
    static let iconName = "bitcoinsign.circle"
    static let category = WidgetCategory.finance
    static let allowsMultiple = false
    static let isPremium = false
    static let defaultConfig = CryptoConfig.default

    var config: CryptoConfig
    var onDisplayUpdate: (() -> Void)?
    var refreshInterval: TimeInterval? { config.refreshInterval }

    private var timer: Timer?
    private(set) var quotes: [CryptoQuote] = []
    private(set) var lastFetchFailed = false

    static let coinSymbols: [String: String] = [
        "bitcoin": "BTC", "ethereum": "ETH", "solana": "SOL",
        "cardano": "ADA", "dogecoin": "DOGE", "ripple": "XRP",
        "polkadot": "DOT", "avalanche-2": "AVAX", "chainlink": "LINK",
        "litecoin": "LTC", "polygon": "MATIC", "uniswap": "UNI",
        "binancecoin": "BNB", "tron": "TRX", "shiba-inu": "SHIB",
        "toncoin": "TON", "stellar": "XLM", "sui": "SUI",
    ]

    required init(config: CryptoConfig) {
        self.config = config
    }

    func start() {
        fetchPrices()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchPrices()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Rendering

    func render() -> WidgetDisplayMode {
        guard !quotes.isEmpty else {
            return .text(lastFetchFailed ? "Crypto: Offline" : "Loading...")
        }

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let separator = "    "

        if config.coloredTicker {
            let result = NSMutableAttributedString()
            for (i, q) in quotes.enumerated() {
                let priceStr = formatPrice(q.price)
                var text = "\(q.symbol) $\(priceStr)"
                if config.showChange {
                    let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
                    text += " \(arrow)\(String(format: "%.1f%%", abs(q.change)))"
                }
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
                let priceStr = formatPrice(q.price)
                var text = "\(q.symbol) $\(priceStr)"
                if config.showChange {
                    let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
                    text += " \(arrow)\(String(format: "%.1f%%", abs(q.change)))"
                }
                return text
            }
            let text = parts.joined(separator: separator) + separator
            let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.headerTextColor])
            return .scrollingText(attr, width: CGFloat(config.tickerWidth))
        }
    }

    // MARK: - Dropdown Menu

    func buildDropdownMenu() -> NSMenu {
        let menu = NSMenu()
        let white = NSColor.white
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .bold)

        let header = NSMenuItem(title: "", action: #selector(CryptoWidget.noop), keyEquivalent: "")
        header.target = self
        header.attributedTitle = NSAttributedString(string: "CRYPTO", attributes: [.font: headerFont, .foregroundColor: white.withAlphaComponent(0.5)])
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for q in quotes {
            let color = Theme.colorForChange(q.change)
            let arrow = q.isUp ? "\u{25B2}" : "\u{25BC}"
            let priceStr = formatPrice(q.price)
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: q.symbol, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: white]))
            text.append(NSAttributedString(string: "    $\(priceStr)    ", attributes: [.font: font, .foregroundColor: white]))
            text.append(NSAttributedString(string: "\(arrow)\(String(format: "%.2f%%", abs(q.change)))", attributes: [.font: font, .foregroundColor: color]))
            let item = NSMenuItem(title: "", action: #selector(CryptoWidget.noop), keyEquivalent: "")
            item.target = self
            item.attributedTitle = text
            menu.addItem(item)
        }

        if quotes.isEmpty {
            let item = NSMenuItem(title: "", action: #selector(CryptoWidget.noop), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: "Loading...", attributes: [.font: font, .foregroundColor: white])
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        if !quotes.isEmpty {
            let avg = quotes.map(\.change).reduce(0, +) / Double(quotes.count)
            let avgColor = Theme.colorForChange(avg)
            let avgText = NSMutableAttributedString()
            avgText.append(NSAttributedString(string: "Avg: ", attributes: [.font: font, .foregroundColor: white]))
            avgText.append(NSAttributedString(string: String(format: "%@%.2f%%", avg >= 0 ? "+" : "", avg), attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: avgColor]))
            let avgItem = NSMenuItem(title: "", action: #selector(CryptoWidget.noop), keyEquivalent: "")
            avgItem.target = self
            avgItem.attributedTitle = avgText
            menu.addItem(avgItem)
            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(NSMenuItem(title: "Customize...", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Barista", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { return [] }

    @objc func noop() {}

    // MARK: - Fetching

    private func fetchPrices() {
        let ids = config.coins.joined(separator: ",")
        let urlStr = "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=\(config.currency)&include_24hr_change=true"
        guard let url = URL(string: urlStr) else { return }

        DataFetcher.shared.fetch(url: url, maxAge: max(config.refreshInterval * 0.8, 30)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                self.lastFetchFailed = false
                self.parsePrices(data: data)
            case .failure:
                DispatchQueue.main.async {
                    self.lastFetchFailed = true
                    if self.quotes.isEmpty { self.onDisplayUpdate?() }
                }
            }
        }
    }

    private func parsePrices(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var results: [CryptoQuote] = []
                for coinId in config.coins {
                    if let coinData = json[coinId] as? [String: Any] {
                        let price = coinData[config.currency] as? Double ?? 0
                        let change = coinData["\(config.currency)_24h_change"] as? Double ?? 0
                        let sym = CryptoWidget.coinSymbols[coinId] ?? String(coinId.prefix(4)).uppercased()
                        results.append(CryptoQuote(coin: coinId, symbol: sym, price: price, change: change))
                    }
                }
                DispatchQueue.main.async {
                    self.quotes = results
                    self.onDisplayUpdate?()
                }
            }
        } catch {}
    }

    // MARK: - Coin Management

    func addCoin(_ coinId: String) {
        let coin = coinId.lowercased().trimmingCharacters(in: .whitespaces)
        guard !coin.isEmpty, !config.coins.contains(coin) else { return }
        config.coins.append(coin)
        fetchPrices()
    }

    func removeCoin(_ coinId: String) {
        config.coins.removeAll { $0 == coinId }
        quotes.removeAll { $0.coin == coinId }
        DispatchQueue.main.async { self.onDisplayUpdate?() }
    }

    // MARK: - Helpers

    private func formatPrice(_ price: Double) -> String {
        if price >= 1000 { return String(format: "%.0f", price) }
        if price >= 1 { return String(format: "%.2f", price) }
        return String(format: "%.4f", price)
    }
}
