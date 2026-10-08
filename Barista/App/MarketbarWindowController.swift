import Cocoa
import ServiceManagement

/// Marketbar's own app window. It observes the existing ticker, so opening it
/// doesn't start another polling loop or change the quote refresh schedule.
final class MarketbarWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    private let widget: StockTickerWidget
    private var observer: NSObjectProtocol?
    private let portfolioPicker = NSPopUpButton()
    private let combinedPortfolioSwitch = NSButton(checkboxWithTitle: "All Portfolios", target: nil, action: nil)
    private let symbolField = NSTextField()
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let sortPicker = NSPopUpButton()
    private var watchlistModel = MarketbarWatchlistModel()
    private var allRows: [MarketbarWatchlistModel.Row] = []
    private let totalLabel = NSTextField(labelWithString: "—")
    private let moveLabel = NSTextField(labelWithString: "")
    private let returnLabel = NSTextField(labelWithString: "")
    private let allocationLabel = NSTextField(labelWithString: "")
    private let freshnessLabel = NSTextField(labelWithString: "")
    private let updateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .medium
        return formatter
    }()
    private let quoteCurrencyFormatter = NumberFormatter()
    private let cashLabel = NSTextField(labelWithString: "")
    private let missingLabel = NSTextField(labelWithString: "")
    private let chart = PortfolioChartView()
    private let chartEmpty = NSTextField(labelWithString: "Your portfolio history will appear here as prices arrive.")
    private let rangeControl = NSSegmentedControl(labels: ["1D", "1W", "1M", "3M", "6M", "ALL"], trackingMode: .selectOne, target: nil, action: nil)
    private let modePicker = NSPopUpButton()
    private let colorSwitch = NSButton(checkboxWithTitle: "Color scrolling ticker", target: nil, action: nil)
    private let extendedSwitch = NSButton(checkboxWithTitle: "Show extended hours", target: nil, action: nil)
    private let widthSlider = NSSlider(value: 200, minValue: 80, maxValue: 500, target: nil, action: nil)
    private let speedSlider = NSSlider(value: 0.3, minValue: 0.1, maxValue: 2, target: nil, action: nil)
    private let loginSwitch = NSButton(checkboxWithTitle: "Open Marketbar at login", target: nil, action: nil)
    private let refreshModeSwitch = NSButton(checkboxWithTitle: "Enable ultra-fast free refresh", target: nil, action: nil)
    private let refreshModeSummaryLabel = NSTextField(labelWithString: "")
    private let refreshModeButton = NSButton(title: "", target: nil, action: nil)
    private let marketStrip = NSStackView()
    private let page = MarketbarPageStackView()
    private let navigation = NSSegmentedControl(labels: ["Portfolio", "Menu bar"], trackingMode: .selectOne, target: nil, action: nil)
    private var rows: [MarketbarWatchlistModel.Row] = []
    private var detailPopover: NSPopover?
    private let modes: [TickerDisplayMode] = [.portfolio, .scrolling, .focused, .compact, .sparkline]
    private var historyRange: PortfolioHistoryService.Range = .today

    init(widget: StockTickerWidget) {
        self.widget = widget
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Marketbar"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1)
        super.init(window: window)
        window.delegate = self
        window.center()
        chart.heightAnchor.constraint(equalToConstant: 190).isActive = true
        widthSlider.widthAnchor.constraint(equalToConstant: 320).isActive = true
        speedSlider.widthAnchor.constraint(equalToConstant: 320).isActive = true
        buildWindow()
        updateData()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateData()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: StockTickerWidget.dataDidChange, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as AnyObject? === self.widget,
                      self.window?.isVisible == true, self.window?.isMiniaturized == false else { return }
                self.updateData()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        detailPopover?.delegate = nil
        detailPopover?.animates = false
        detailPopover?.close()
        detailPopover = nil
        sender.orderOut(nil)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func windowDidDeminiaturize(_ notification: Notification) { updateData() }

    private func buildWindow() {
        guard let root = window?.contentView else { return }
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 18
        sidebar.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 20, right: 20)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(white: 1, alpha: 0.025).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        sidebar.addArrangedSubview(label("MARKETBAR", size: 14, weight: .bold, color: Theme.brandCyan))
        sidebar.addArrangedSubview(label("Your portfolio.\nAlways in view.", size: 12, color: Theme.textMuted))
        sidebar.addArrangedSubview(label("ACTIVE PORTFOLIO", size: 9, weight: .semibold, color: Theme.textFaint))
        portfolioPicker.target = self
        portfolioPicker.action = #selector(selectPortfolio)
        sidebar.addArrangedSubview(portfolioPicker)
        portfolioPicker.widthAnchor.constraint(equalToConstant: 154).isActive = true
        let portfolioActions = NSStackView(views: [button("New", #selector(newPortfolio)), button("Manage", #selector(managePortfolio))])
        portfolioActions.spacing = 8
        sidebar.addArrangedSubview(portfolioActions)
        combinedPortfolioSwitch.target = self
        combinedPortfolioSwitch.action = #selector(toggleCombinedPortfolio)
        combinedPortfolioSwitch.identifier = NSUserInterfaceItemIdentifier("portfolio.combined.toggle")
        combinedPortfolioSwitch.toolTip = "Show an automatic portfolio combining every portfolio's holdings and cash"
        sidebar.addArrangedSubview(combinedPortfolioSwitch)
        navigation.selectedSegment = 0
        navigation.target = self
        navigation.action = #selector(navigate)
        navigation.segmentStyle = .rounded
        sidebar.addArrangedSubview(navigation)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebar.addArrangedSubview(spacer)
        sidebar.addArrangedSubview(button("Research Workspace ↗", #selector(openResearch)))
        sidebar.addArrangedSubview(label("⌘,  Open Marketbar\n⌘⇧Space  Quick actions", size: 10, color: Theme.textFaint))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 18
        page.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = page
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 194),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        buildPage()
    }

    private func addFullWidth(_ view: NSView) {
        page.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -56).isActive = true
    }

    private func buildPage() {
        detailPopover?.delegate = nil
        detailPopover?.animates = false
        detailPopover?.close()
        detailPopover = nil
        page.arrangedSubviews.forEach { page.removeArrangedSubview($0); $0.removeFromSuperview() }
        if navigation.selectedSegment == 1 { buildPreferences(); return }
        refreshModeButton.target = self
        refreshModeButton.action = #selector(toggleFastRefresh)
        refreshModeButton.bezelStyle = .rounded
        refreshModeButton.font = .systemFont(ofSize: 11, weight: .semibold)
        refreshModeButton.toolTip = "Switch between standard polling and the fastest available free polling schedule."
        let heading = NSStackView(views: [label("Portfolio overview", size: 26, weight: .bold), NSView(), refreshModeButton, button("Refresh now", #selector(refresh))])
        heading.orientation = .horizontal
        addFullWidth(heading)
        freshnessLabel.font = .systemFont(ofSize: 11)
        freshnessLabel.textColor = Theme.textMuted
        addFullWidth(freshnessLabel)

        let marketCard = card()
        marketCard.spacing = 9
        marketCard.addArrangedSubview(label("MARKET PULSE", size: 10, weight: .semibold, color: Theme.textFaint))
        marketStrip.orientation = .horizontal
        marketStrip.alignment = .centerY
        marketStrip.distribution = .fillEqually
        marketStrip.spacing = 10
        marketCard.addArrangedSubview(marketStrip)
        marketStrip.widthAnchor.constraint(equalTo: marketCard.widthAnchor, constant: -36).isActive = true
        addFullWidth(marketCard)

        let summary = card()
        summary.spacing = 8
        summary.addArrangedSubview(label("LIVE PORTFOLIO VALUE", size: 10, weight: .semibold, color: Theme.textFaint))
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        totalLabel.textColor = Theme.textPrimary
        totalLabel.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.total")
        summary.addArrangedSubview(totalLabel)
        moveLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        summary.addArrangedSubview(moveLabel)
        returnLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summary.addArrangedSubview(returnLabel)
        allocationLabel.font = .systemFont(ofSize: 11)
        allocationLabel.textColor = Theme.textMuted
        summary.addArrangedSubview(allocationLabel)
        let cashRow = NSStackView(views: [cashLabel, NSView(), button("Edit cash", #selector(editCash))])
        cashLabel.font = .systemFont(ofSize: 11)
        cashLabel.textColor = Theme.textMuted
        summary.addArrangedSubview(cashRow)
        cashRow.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -36).isActive = true
        addFullWidth(summary)
        missingLabel.font = .systemFont(ofSize: 11)
        missingLabel.textColor = Theme.brandAmber
        missingLabel.lineBreakMode = .byWordWrapping
        missingLabel.maximumNumberOfLines = 2
        addFullWidth(missingLabel)

        let chartCard = card()
        rangeControl.target = self
        rangeControl.action = #selector(changeRange)
        rangeControl.selectedSegment = PortfolioHistoryService.Range.allCases.firstIndex(of: historyRange) ?? 0
        let chartHeader = NSStackView(views: [label("VALUE OVER TIME", size: 10, weight: .semibold, color: Theme.textFaint), NSView(), rangeControl])
        chartCard.addArrangedSubview(chartHeader)
        chartHeader.widthAnchor.constraint(equalTo: chartCard.widthAnchor, constant: -36).isActive = true
        chartCard.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: chartCard.widthAnchor, constant: -36).isActive = true
        chartEmpty.font = .systemFont(ofSize: 11)
        chartEmpty.textColor = Theme.textMuted
        chart.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.chart")
        chartEmpty.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.chart-empty")
        chartCard.addArrangedSubview(chartEmpty)
        addFullWidth(chartCard)

        let title = NSStackView(views: [label("Watchlist", size: 20, weight: .semibold), NSView(), button("Position", #selector(editPosition)), button("Remove", #selector(removeSymbol))])
        addFullWidth(title)
        let searchRow = NSStackView()
        searchRow.orientation = .horizontal
        searchRow.spacing = 10
        searchField.placeholderString = "Search symbols or asset type"
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search watchlist")
        searchField.toolTip = "Filter the watchlist by symbol or stock/crypto."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchRow.addArrangedSubview(searchField)
        sortPicker.removeAllItems()
        sortPicker.addItems(withTitles: MarketbarWatchlistModel.Sort.allCases.map(\.rawValue))
        sortPicker.selectItem(at: MarketbarWatchlistModel.Sort.allCases.firstIndex(of: watchlistModel.sort) ?? 0)
        sortPicker.target = self
        sortPicker.action = #selector(sortChanged)
        sortPicker.setAccessibilityLabel("Sort watchlist")
        sortPicker.toolTip = "Choose how watchlist rows are ordered."
        searchRow.addArrangedSubview(sortPicker)
        addFullWidth(searchRow)
        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 8
        symbolField.placeholderString = "Add a ticker or crypto symbol (AAPL, BTC…)"
        symbolField.font = .systemFont(ofSize: 13)
        symbolField.target = self
        symbolField.action = #selector(addSymbol)
        addRow.addArrangedSubview(symbolField)
        addRow.addArrangedSubview(button("Add", #selector(addSymbol)))
        addFullWidth(addRow)
        if table.tableColumns.isEmpty {
            for (id, title, width) in [("symbol", "Symbol", 104.0), ("price", "Price", 100.0), ("change", "Change", 92.0), ("chart", "Today", 100.0), ("holding", "Position", 128.0), ("value", "Value / return", 142.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.width = width
                column.minWidth = 70
                table.addTableColumn(column)
            }
            table.dataSource = self
            table.delegate = self
            table.rowHeight = 38
            table.intercellSpacing = NSSize(width: 12, height: 4)
            table.backgroundColor = .clear
            table.usesAlternatingRowBackgroundColors = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.target = self
            table.doubleAction = #selector(openDetail)
            table.setAccessibilityLabel("Market watchlist")
        }
        let tableScroll = NSScrollView()
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = table
        tableScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        addFullWidth(tableScroll)
        addFullWidth(label("Double-click a ticker for its chart, financials and headlines. Return shows only positions with recorded cost basis.", size: 11, color: Theme.textFaint))
        updateData()
    }

    private func buildPreferences() {
        addFullWidth(label("Menu bar", size: 26, weight: .bold))
        addFullWidth(label("Choose how Marketbar appears alongside your other apps.", size: 12, color: Theme.textMuted))
        let controls = card()
        controls.spacing = 18
        modePicker.removeAllItems()
        modePicker.addItems(withTitles: ["Portfolio value", "Scrolling ticker", "One ticker", "Compact ticker", "Sparkline"])
        modePicker.selectItem(at: modes.firstIndex(of: widget.config.displayMode) ?? 0)
        modePicker.target = self
        modePicker.action = #selector(preferencesChanged)
        controls.addArrangedSubview(label("DISPLAY", size: 10, weight: .semibold, color: Theme.textFaint))
        controls.addArrangedSubview(modePicker)
        for (toggle, enabled) in [(colorSwitch, widget.config.coloredTicker), (extendedSwitch, widget.config.showExtendedHours)] {
            toggle.state = enabled ? .on : .off
            toggle.target = self
            toggle.action = #selector(preferencesChanged)
            controls.addArrangedSubview(toggle)
        }
        controls.addArrangedSubview(label("Ticker width", size: 12))
        widthSlider.doubleValue = widget.config.tickerWidth
        widthSlider.target = self
        widthSlider.action = #selector(preferencesChanged)
        controls.addArrangedSubview(widthSlider)
        controls.addArrangedSubview(label("Scroll speed", size: 12))
        speedSlider.doubleValue = widget.config.scrollSpeed
        speedSlider.target = self
        speedSlider.action = #selector(preferencesChanged)
        controls.addArrangedSubview(speedSlider)
        addFullWidth(controls)
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        addFullWidth(loginSwitch)
        let refreshCard = card()
        refreshCard.addArrangedSubview(label("DATA & REFRESH", size: 10, weight: .semibold, color: Theme.textFaint))
        refreshModeSwitch.state = widget.config.refreshMode == .ultraFast ? .on : .off
        refreshModeSwitch.target = self
        refreshModeSwitch.action = #selector(refreshModePreferenceChanged)
        refreshModeSwitch.toolTip = "Use the fastest available free polling schedule while respecting provider limits."
        refreshCard.addArrangedSubview(refreshModeSwitch)
        refreshModeSummaryLabel.stringValue = widget.refreshModeSummary
        refreshModeSummaryLabel.font = .systemFont(ofSize: 12)
        refreshModeSummaryLabel.textColor = Theme.textMuted
        refreshCard.addArrangedSubview(refreshModeSummaryLabel)
        refreshCard.addArrangedSubview(label("Ultra-fast mode adapts to market hours and provider limits. Manual refresh remains available at any time.", size: 11, color: Theme.textMuted))
        addFullWidth(refreshCard)
    }

    private func updateData() {
        let config = widget.config
        let choices = config.portfolioChoices
        let ids = choices.map(\.id)
        if portfolioPicker.itemArray.compactMap({ $0.representedObject as? String }) != ids
            || portfolioPicker.itemTitles != choices.map(\.name) {
            portfolioPicker.removeAllItems()
            for portfolio in choices {
                portfolioPicker.addItem(withTitle: portfolio.name)
                portfolioPicker.lastItem?.representedObject = portfolio.id
            }
        }
        portfolioPicker.selectItem(at: ids.firstIndex(of: config.activePortfolioID) ?? 0)
        combinedPortfolioSwitch.state = config.combinedPortfolioEnabled ? .on : .off
        if let content = window?.contentView { updatePortfolioEditingControls(in: content) }
        guard navigation.selectedSegment == 0 else { return }
        // An absolute timestamp stays accurate without a UI-only polling timer.
        let freshness: String
        if widget.isBackingOff {
            freshness = "Price provider is rate limiting requests"
        } else if let updated = widget.lastUpdated {
            let prefix = widget.isUsingCachedData || widget.lastFetchFailed ? "Last known response at" : "Latest response at"
            freshness = "\(prefix) \(updateTimeFormatter.string(from: updated))"
        } else {
            freshness = "Waiting for prices…"
        }
        freshnessLabel.stringValue = "\(MarketStatus.current().label) · \(freshness)"
        freshnessLabel.textColor = widget.freshnessColor()
        refreshModeButton.title = widget.config.refreshMode == .ultraFast ? "⚡ Ultra-fast · On" : "⚡ Ultra-fast · Off"
        refreshModeButton.contentTintColor = widget.config.refreshMode == .ultraFast ? Theme.brandCyan : Theme.textMuted
        refreshModeButton.setAccessibilityLabel(widget.config.refreshMode == .ultraFast ? "Turn ultra-fast refresh off" : "Turn ultra-fast refresh on")
        updateMarketStrip()
        let snapshot = widget.portfolioSnapshot()
        let currencyComparable = snapshot.map(isCurrencyComparable) ?? true
        totalLabel.stringValue = currencyComparable ? widget.formatCurrency(snapshot?.liveTotal ?? config.cash) : "—"
        if let snapshot {
            if currencyComparable {
                moveLabel.stringValue = "\(widget.formatSignedCurrency(snapshot.livePL)) (\(String(format: "%+.2f%%", snapshot.livePercent))) vs previous close"
                moveLabel.textColor = widget.intensityColor(for: snapshot.livePercent)
            } else {
                moveLabel.stringValue = "Portfolio values hidden because positions use mixed currencies."
                moveLabel.textColor = Theme.textMuted
            }
            if currencyComparable, let totalPL = snapshot.totalPL, let totalPercent = snapshot.totalPercent {
                let coverage = snapshot.hasPartialCostBasis ? " · cost basis recorded for part of portfolio" : " · since purchase"
                returnLabel.stringValue = "Total return  \(widget.formatSignedCurrency(totalPL)) (\(String(format: "%+.2f%%", totalPercent)))\(coverage)"
                returnLabel.textColor = widget.intensityColor(for: totalPercent)
            } else if !currencyComparable {
                returnLabel.stringValue = "Total return unavailable across mixed currencies."
                returnLabel.textColor = Theme.textMuted
            } else {
                returnLabel.stringValue = "Record position cost basis to track total return."
                returnLabel.textColor = Theme.textMuted
            }
            if currencyComparable {
                let invested = snapshot.positions.map(\.liveValue).reduce(0, +)
                let investedPercent = snapshot.liveTotal > 0 ? invested / snapshot.liveTotal * 100 : 0
                let leader = snapshot.positions.max { $0.liveValue < $1.liveValue }
                allocationLabel.stringValue = "Invested \(String(format: "%.0f%%", investedPercent)) of portfolio\(leader.map { " · largest holding \($0.quote.symbol), \(String(format: "%.0f%%", $0.liveValue / max(snapshot.liveTotal, 1) * 100))" } ?? "")"
            } else {
                allocationLabel.stringValue = "Allocation unavailable across mixed currencies."
            }
        } else {
            moveLabel.stringValue = "Add a position to start tracking your portfolio."
            moveLabel.textColor = Theme.textMuted
            returnLabel.stringValue = ""
            allocationLabel.stringValue = ""
        }
        let automatic = config.isCombinedPortfolioActive ? "Automatic · \(config.portfolios.count) portfolios · " : ""
        cashLabel.stringValue = "\(automatic)Cash \(widget.formatCurrency(config.cash)) · \(config.holdings.count) positions"
        cashLabel.textColor = config.cash < 0 ? Theme.red : Theme.textMuted
        let missing = snapshot?.missingSymbols ?? []
        missingLabel.stringValue = missing.isEmpty ? "" : "Waiting for prices: \(missing.joined(separator: ", ")). Total excludes these positions."
        missingLabel.isHidden = missing.isEmpty
        updateChart()
        guard detailPopover?.isShown != true else { return }
        // Keep the selection stable as sorted prices move, and never recreate the add field.
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil
        let configured = config.symbols.map { (symbol: $0, kind: MarketQuote.Kind.stock) }
            + config.coins.map { (symbol: coinSymbols[$0] ?? String($0.prefix(4)).uppercased(), kind: MarketQuote.Kind.crypto) }
        allRows = configured.map { item in
            let quote = widget.quotes.first { $0.symbol == item.symbol && $0.kind == item.kind }
            let quantity = config.holdings[item.symbol] ?? 0
            let cost = config.costBasis[item.symbol]
            let totalReturn = quote.flatMap { quote -> Double? in
                guard let cost, cost > 0, quantity > 0 else { return nil }
                return (quote.currentPrice - cost) / cost * 100
            }
            return MarketbarWatchlistModel.Row(symbol: item.symbol, kind: item.kind,
                                               price: quote?.currentPrice,
                                               changePercent: quote?.currentChange,
                                               positionValue: quote.flatMap { quantity > 0 ? $0.currentPrice * quantity : nil },
                                               positionCurrency: quote?.currency?.uppercased() ?? "USD",
                                               totalReturnPercent: totalReturn)
        }
        rows = watchlistModel.visibleRows(from: allRows)
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.symbol == selected.symbol && $0.kind == selected.kind }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func updateMarketStrip() {
        marketStrip.arrangedSubviews.forEach { marketStrip.removeArrangedSubview($0); $0.removeFromSuperview() }
        let indices = [("S&P 500 · SPY", "SPY"), ("NASDAQ 100 · QQQ", "QQQ"), ("Dow Jones · DIA", "DIA")]
        for (name, symbol) in indices {
            let quote = widget.indexQuotes.first { $0.symbol == symbol }
            let tile = NSStackView()
            tile.orientation = .vertical
            tile.alignment = .leading
            tile.spacing = 4
            let title = label(name, size: 10, weight: .medium, color: Theme.textFaint)
            let value = label(quote.map { "\(widget.formatCurrency($0.currentPrice))   \(String(format: "%+.2f%%", $0.currentChange))" } ?? "Waiting for quote", size: 12, weight: .semibold)
            value.textColor = quote.map { widget.intensityColor(for: $0.currentChange) } ?? Theme.textMuted
            value.toolTip = quote.map { "\(symbol): \(widget.formatCurrency($0.currentPrice)), \(String(format: "%+.2f%%", $0.currentChange)) today" }
            tile.addArrangedSubview(title)
            tile.addArrangedSubview(value)
            marketStrip.addArrangedSubview(tile)
        }
    }

    private func updateChart() {
        let snapshot = widget.portfolioSnapshot()
        if let snapshot, !isCurrencyComparable(snapshot) {
            chart.samples = []
            chart.benchmark = nil
            chartEmpty.stringValue = "Portfolio history is unavailable across mixed currencies."
            chartEmpty.isHidden = false
            chart.accent = Theme.textMuted
            return
        }
        chartEmpty.stringValue = "Your portfolio history will appear here as prices arrive."
        if historyRange == .today {
            chart.samples = (widget.intradayPortfolioSeries() ?? []).map { .init(date: $0.date, value: $0.value) }
            chart.axisStyle = .time
        } else {
            chart.samples = PortfolioHistoryService.shared.points(for: widget.config.activePortfolioHistoryID, range: historyRange).map { .init(date: $0.time, value: $0.value) }
            chart.axisStyle = .date
        }
        chart.accent = widget.intensityColor(for: snapshot?.livePercent ?? 0)
        chartEmpty.isHidden = chart.samples.count >= 2
    }

    private func isCurrencyComparable(_ snapshot: PortfolioSnapshot) -> Bool {
        snapshot.positions.allSatisfy { ($0.quote.currency ?? "USD").uppercased() == "USD" }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let item = rows[row]
        let quote = widget.quotes.first { $0.symbol == item.symbol && $0.kind == item.kind }
        if id.rawValue == "chart" {
            let cell = NSTableCellView()
            let spark = MarketbarMiniSparklineView()
            spark.values = quote?.chartSeries ?? []
            spark.tint = widget.intensityColor(for: quote?.currentChange ?? 0)
            spark.toolTip = "\(item.symbol) intraday price trend"
            spark.setAccessibilityLabel("\(item.symbol) intraday price chart")
            cell.addSubview(spark)
            spark.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([spark.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         spark.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                                         spark.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                                         spark.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)])
            return cell
        }
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: id.rawValue == "symbol" ? .semibold : .regular)
        value.textColor = Theme.textPrimary
        switch id.rawValue {
        case "symbol": value.stringValue = item.symbol
        case "price": value.stringValue = quote.map { widget.formatCurrency($0.currentPrice) } ?? (widget.failedSymbols.contains(item.symbol) ? "Unavailable" : "Loading…")
        case "change":
            value.stringValue = quote.map { String(format: "%+.2f%%", $0.currentChange) } ?? "—"
            value.textColor = quote.map { widget.intensityColor(for: $0.currentChange) } ?? Theme.textFaint
        case "holding":
            let shares = widget.config.holdings[item.symbol] ?? 0
            value.stringValue = shares > 0 ? "\(widget.formatShareCount(shares)) shares" : "—"
            value.textColor = Theme.textMuted
        default:
            if let positionValue = item.positionValue {
                let ret = item.totalReturnPercent.map { String(format: "  %+.1f%%", $0) } ?? ""
                value.stringValue = "\(formatQuoteCurrency(positionValue, code: item.positionCurrency))\(ret)"
                value.textColor = item.totalReturnPercent.map { widget.intensityColor(for: $0) } ?? Theme.textPrimary
                value.toolTip = item.totalReturnPercent == nil ? "Market value; record cost basis to see total return." : "Market value and return since purchase."
            } else {
                value.stringValue = "—"
                value.textColor = Theme.textFaint
                value.toolTip = "No position in this portfolio."
            }
        }
        value.lineBreakMode = .byTruncatingTail
        value.toolTip = quote?.feedStatusDescription()
        value.setAccessibilityLabel("\(item.symbol), \(id.rawValue): \(value.stringValue)")
        let cell = NSTableCellView()
        cell.addSubview(value)
        value.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([value.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                     value.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                     value.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    @objc private func navigate() { buildPage(); updateData() }
    @objc private func refresh() { widget.refreshNow() }
    @objc private func toggleFastRefresh() {
        widget.setRefreshMode(widget.config.refreshMode == .ultraFast ? .standard : .ultraFast)
        refreshModeSwitch.state = widget.config.refreshMode == .ultraFast ? .on : .off
        refreshModeSummaryLabel.stringValue = widget.refreshModeSummary
        updateData()
    }
    @objc private func refreshModePreferenceChanged() {
        widget.setRefreshMode(refreshModeSwitch.state == .on ? .ultraFast : .standard)
        refreshModeSummaryLabel.stringValue = widget.refreshModeSummary
        updateData()
    }
    @objc private func searchChanged() {
        watchlistModel.query = searchField.stringValue
        reloadVisibleRows()
    }
    @objc private func sortChanged() {
        let sorts = MarketbarWatchlistModel.Sort.allCases
        guard sorts.indices.contains(sortPicker.indexOfSelectedItem) else { return }
        watchlistModel.sort = sorts[sortPicker.indexOfSelectedItem]
        reloadVisibleRows()
    }
    private func reloadVisibleRows() {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil
        rows = watchlistModel.visibleRows(from: allRows)
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.symbol == selected.symbol && $0.kind == selected.kind }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    @objc private func openResearch() { widget.openResearchDashboard() }
    @objc private func toggleCombinedPortfolio() {
        widget.setCombinedPortfolioEnabled(combinedPortfolioSwitch.state == .on)
        updateData()
    }

    private func updatePortfolioEditingControls(in view: NSView) {
        if let button = view as? NSButton,
           [#selector(editCash), #selector(editPosition), #selector(managePortfolio)].contains(where: { button.action == $0 }) {
            button.isEnabled = !widget.config.isCombinedPortfolioActive
            button.toolTip = widget.config.isCombinedPortfolioActive ? "Choose an individual portfolio to make changes" : nil
        }
        view.subviews.forEach { updatePortfolioEditingControls(in: $0) }
    }
    @objc private func selectPortfolio() {
        if let id = portfolioPicker.selectedItem?.representedObject as? String { widget.selectPortfolio(id: id); updateData() }
    }
    @objc private func changeRange() {
        let ranges = PortfolioHistoryService.Range.allCases
        guard ranges.indices.contains(rangeControl.selectedSegment) else { return }
        historyRange = ranges[rangeControl.selectedSegment]
        updateChart()
    }
    @objc private func addSymbol() {
        let raw = symbolField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        widget.addSymbol(raw)
        if widget.config.symbols.contains(raw.uppercased()) || widget.config.coins.contains(raw.lowercased()) || symbolToCoinID[raw.uppercased()].map({ widget.config.coins.contains($0) }) == true {
            symbolField.stringValue = ""
            updateData()
        } else { problem("Enter a valid ticker or a supported crypto symbol.") }
    }
    @objc private func newPortfolio() {
        guard widget.canAddPortfolio else { problem("You can keep up to \(Portfolio.maxCount) portfolios."); return }
        if let name = input(title: "New portfolio", value: "", hint: "Portfolio name") { widget.addPortfolio(named: name); updateData() }
    }
    @objc private func managePortfolio() {
        guard !widget.config.isCombinedPortfolioActive else { return }
        let menu = NSMenu()
        for (title, action) in [("Rename portfolio…", #selector(renamePortfolio)), ("Delete portfolio…", #selector(deletePortfolio))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != #selector(deletePortfolio) || widget.config.portfolios.count > 1
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: portfolioPicker.bounds.minY), in: portfolioPicker)
    }
    @objc private func renamePortfolio() {
        guard !widget.config.isCombinedPortfolioActive else { return }
        if let name = input(title: "Rename portfolio", value: widget.config.activePortfolio?.name ?? "", hint: "Portfolio name") { widget.renameActivePortfolio(to: name); updateData() }
    }
    @objc private func deletePortfolio() {
        guard !widget.config.isCombinedPortfolioActive else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(widget.config.activePortfolio?.name ?? "portfolio")?"
        alert.informativeText = "This removes its positions, trade ledger and value history."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        widget.deletePortfolio(id: widget.config.activePortfolioID)
        updateData()
    }
    @objc private func editCash() {
        guard !widget.config.isCombinedPortfolioActive else { return }
        guard let raw = input(title: "Portfolio cash", value: String(widget.config.cash), hint: "Amount") else { return }
        guard let amount = Double(raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")), amount.isFinite, amount >= 0 else {
            problem("Enter a valid, non-negative cash amount.")
            return
        }
        widget.setCash(amount)
        updateData()
    }
    @objc private func editPosition() {
        guard !widget.config.isCombinedPortfolioActive else { return }
        guard let item = selectedItem else { problem("Select a ticker first."); return }
        let form = HoldingsForm(shares: widget.config.holdings[item.symbol] ?? 0,
                                cost: widget.config.costBasis[item.symbol],
                                availableCash: widget.config.cash,
                                quoteCurrency: widget.quotes.first { $0.symbol == item.symbol && $0.kind == item.kind }?.currency
                                    ?? (item.kind == .crypto ? widget.config.cryptoCurrency : "USD"))
        let alert = NSAlert()
        alert.messageText = "\(item.symbol) position"
        alert.informativeText = "Set is a manual correction and does not change cash or log a trade. Buy and Sell record funded trades and update cash."
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.shareField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let message = form.validationProblem { problem(message); return }
        switch form.mode {
        case .set: widget.setHolding(symbol: item.symbol, kind: item.kind, quantity: form.enteredShares, averageCost: form.enteredCost)
        case .buy, .sell:
            guard let price = form.enteredCost, price > 0, form.enteredShares > 0 else {
                problem("Enter a positive quantity and price to record this trade."); return
            }
            let side: Transaction.Kind = form.mode == .buy ? .buy : .sell
            switch TradeCashConfirmation.recordTrade(widget: widget, symbol: item.symbol, kind: item.kind,
                                                     side: side, quantity: form.enteredShares, price: price) {
            case .recorded: break
            case .cancelled: return
            case .invalid(let message): problem(message); return
            }
        }
        updateData()
    }
    @objc private func removeSymbol() {
        guard let item = selectedItem else { return }
        if (widget.config.holdings[item.symbol] ?? 0) > 0 {
            let alert = NSAlert()
            alert.messageText = "Remove \(item.symbol)?"
            alert.informativeText = "This also removes its position from the active portfolio by recording a correction."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Remove")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        widget.removeQuote(item.symbol, kind: item.kind)
        updateData()
    }
    private var selectedItem: (symbol: String, kind: MarketQuote.Kind)? {
        guard rows.indices.contains(table.selectedRow) else { return nil }
        let row = rows[table.selectedRow]
        return (symbol: row.symbol, kind: row.kind)
    }
    @objc private func openDetail() {
        guard let item = selectedItem,
              let quote = widget.quotes.first(where: { $0.symbol == item.symbol && $0.kind == item.kind }),
              let anchor = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) else { return }
        detailPopover?.delegate = nil
        detailPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = StockDetailPopoverController.preferredSize(on: window?.screen)
        popover.contentViewController = StockDetailPopoverController(widget: widget, quote: quote, screen: window?.screen)
        detailPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
    }
    func popoverDidClose(_ notification: Notification) {
        detailPopover = nil
        DispatchQueue.main.async { [weak self] in self?.updateData() }
    }
    @objc private func preferencesChanged() {
        guard modes.indices.contains(modePicker.indexOfSelectedItem) else { return }
        widget.config.displayMode = modes[modePicker.indexOfSelectedItem]
        widget.config.coloredTicker = colorSwitch.state == .on
        widget.config.showExtendedHours = extendedSwitch.state == .on
        widget.config.tickerWidth = widthSlider.doubleValue
        widget.config.scrollSpeed = speedSlider.doubleValue
        widget.saveConfig()
        widget.onDisplayUpdate?()
    }
    @objc private func toggleLogin() {
        do {
            if loginSwitch.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { problem(error.localizedDescription) }
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private func input(title: String, value: String, hint: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        field.placeholderString = hint
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func problem(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not save change"
        alert.informativeText = message
        alert.runModal()
    }
    private func formatQuoteCurrency(_ amount: Double, code: String) -> String {
        quoteCurrencyFormatter.locale = .autoupdatingCurrent
        quoteCurrencyFormatter.numberStyle = .currency
        quoteCurrencyFormatter.currencyCode = code
        quoteCurrencyFormatter.minimumFractionDigits = 2
        quoteCurrencyFormatter.maximumFractionDigits = 2
        return quoteCurrencyFormatter.string(from: NSNumber(value: amount)) ?? "\(code) \(String(format: "%.2f", amount))"
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.textPrimary) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }
    private func card() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor(white: 1, alpha: 0.035).cgColor
        stack.layer?.cornerRadius = 12
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor(white: 1, alpha: 0.075).cgColor
        return stack
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

private final class MarketbarPageStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class MarketbarMiniSparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var tint: NSColor = Theme.brandCyan { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let points = values.filter { $0.isFinite && $0 > 0 }
        guard points.count > 1, bounds.width > 2, bounds.height > 2 else { return }
        let low = points.min() ?? 0
        let high = points.max() ?? low
        let span = max(max(high - low, abs(high) * 0.0001), 0.000001)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let x = bounds.minX + CGFloat(index) / CGFloat(points.count - 1) * bounds.width
            let y = bounds.minY + CGFloat((point - low) / span) * max(1, bounds.height - 2) + 1
            let location = NSPoint(x: x, y: y)
            if index == 0 { path.move(to: location) } else { path.line(to: location) }
        }
        tint.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}
