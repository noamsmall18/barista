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
    private let realizedLabel = NSTextField(labelWithString: "")
    private let allocationLabel = NSTextField(labelWithString: "")
    private let returnDetail = NSTextField(wrappingLabelWithString: "")
    private let realizedDetail = NSTextField(wrappingLabelWithString: "")
    private let allocationDetail = NSTextField(wrappingLabelWithString: "")
    private let cashDetail = NSTextField(wrappingLabelWithString: "")
    private let sharpeLabel = NSTextField(labelWithString: "—")
    private let sharpeDetail = NSTextField(wrappingLabelWithString: "")
    private let riskTable = NSStackView()
    private let riskNote = NSTextField(wrappingLabelWithString: "")
    private let riskRateButton = NSButton(title: "", target: nil, action: nil)
    private var shownRiskRows: [PortfolioRiskRow]?
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
    private let historyRaw = NSButton(checkboxWithTitle: "Raw", target: nil, action: nil)
    private let historyNote = NSTextField(labelWithString: "")
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
        let sidebarEdge = NSView()
        sidebarEdge.wantsLayer = true
        sidebarEdge.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        sidebarEdge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarEdge)
        NSLayoutConstraint.activate([
            sidebarEdge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 193),
            sidebarEdge.widthAnchor.constraint(equalToConstant: 1),
            sidebarEdge.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarEdge.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        let brand = label("MARKETBAR", size: 14, weight: .bold, color: Theme.brandCyan)
        sidebar.addArrangedSubview(brand)
        sidebar.setCustomSpacing(6, after: brand)
        let tagline = label("Your portfolio.\nAlways in view.", size: 12, color: Theme.textMuted)
        sidebar.addArrangedSubview(tagline)
        sidebar.setCustomSpacing(26, after: tagline)
        let activeCaption = caption("ACTIVE PORTFOLIO")
        sidebar.addArrangedSubview(activeCaption)
        sidebar.setCustomSpacing(8, after: activeCaption)
        portfolioPicker.target = self
        portfolioPicker.action = #selector(selectPortfolio)
        sidebar.addArrangedSubview(portfolioPicker)
        sidebar.setCustomSpacing(8, after: portfolioPicker)
        portfolioPicker.widthAnchor.constraint(equalToConstant: 154).isActive = true
        let portfolioActions = NSStackView(views: [button("New", #selector(newPortfolio)), button("Manage", #selector(managePortfolio))])
        portfolioActions.spacing = 8
        portfolioActions.distribution = .fillEqually
        sidebar.addArrangedSubview(portfolioActions)
        portfolioActions.widthAnchor.constraint(equalToConstant: 154).isActive = true
        sidebar.setCustomSpacing(12, after: portfolioActions)
        combinedPortfolioSwitch.target = self
        combinedPortfolioSwitch.action = #selector(toggleCombinedPortfolio)
        combinedPortfolioSwitch.identifier = NSUserInterfaceItemIdentifier("portfolio.combined.toggle")
        combinedPortfolioSwitch.toolTip = "Show an automatic portfolio combining every portfolio's holdings and cash"
        sidebar.addArrangedSubview(combinedPortfolioSwitch)
        sidebar.setCustomSpacing(26, after: combinedPortfolioSwitch)
        let viewCaption = caption("VIEW")
        sidebar.addArrangedSubview(viewCaption)
        sidebar.setCustomSpacing(8, after: viewCaption)
        navigation.selectedSegment = 0
        navigation.target = self
        navigation.action = #selector(navigate)
        navigation.segmentStyle = .rounded
        sidebar.addArrangedSubview(navigation)
        navigation.widthAnchor.constraint(equalToConstant: 154).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebar.addArrangedSubview(spacer)
        sidebar.addArrangedSubview(button("Research Workspace ↗", #selector(openResearch)))
        sidebar.addArrangedSubview(label("⌘,  Open Marketbar\n⌘⇧Space  Quick actions", size: 10, color: Theme.textFaint))
        let recovery = button("Backup & Recovery…", #selector(openRecovery))
        recovery.identifier = NSUserInterfaceItemIdentifier("recovery.open")
        recovery.isBordered = false
        recovery.controlSize = .mini
        recovery.font = .systemFont(ofSize: 10)
        recovery.contentTintColor = Theme.textMuted
        sidebar.addArrangedSubview(recovery)

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
        let headingText = NSStackView(views: [label("Portfolio overview", size: 26, weight: .bold), freshnessLabel])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 3
        freshnessLabel.font = .systemFont(ofSize: 11, weight: .medium)
        freshnessLabel.textColor = Theme.textMuted
        let heading = NSStackView(views: [headingText, NSView(), refreshModeButton, button("Refresh now", #selector(refresh))])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        addFullWidth(heading)

        let marketCard = card()
        marketCard.spacing = 10
        marketCard.addArrangedSubview(caption("MARKET PULSE"))
        marketStrip.orientation = .horizontal
        marketStrip.alignment = .top
        marketStrip.distribution = .fillEqually
        marketStrip.spacing = 10
        marketCard.addArrangedSubview(marketStrip)
        marketStrip.widthAnchor.constraint(equalTo: marketCard.widthAnchor, constant: -36).isActive = true
        addFullWidth(marketCard)

        let summary = card()
        summary.spacing = 6
        summary.addArrangedSubview(caption("LIVE PORTFOLIO VALUE"))
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        totalLabel.textColor = Theme.textPrimary
        totalLabel.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.total")
        summary.addArrangedSubview(totalLabel)
        moveLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        summary.addArrangedSubview(moveLabel)
        summary.setCustomSpacing(16, after: moveLabel)

        realizedLabel.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.realizedYTD")
        sharpeLabel.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.sharpe")
        sharpeDetail.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.sharpe-detail")
        let realizedTile = statTile("REALIZED YTD", value: realizedLabel, detail: realizedDetail)
        realizedTile.toolTip = "Current calendar year in Eastern Time. Uses a broker reconciliation, when supplied, plus subsequent recorded sales. Edit under Manage."
        let sharpeTile = statTile("SHARPE RATIO", value: sharpeLabel, detail: sharpeDetail)
        sharpeTile.toolTip = "Annualized Sharpe ratio from this portfolio's daily closes, in excess of the risk-free rate. Holding and cash changes are neutralized first."
        let performanceRow = tileRow([statTile("UNREALIZED RETURN", value: returnLabel, detail: returnDetail), realizedTile, sharpeTile])
        summary.addArrangedSubview(performanceRow)
        performanceRow.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -36).isActive = true
        summary.setCustomSpacing(10, after: performanceRow)
        let cashTile = statTile("CASH", value: cashLabel, detail: cashDetail, accessory: button("Edit cash", #selector(editCash)))
        let holdingsRow = tileRow([statTile("ALLOCATION", value: allocationLabel, detail: allocationDetail), cashTile])
        summary.addArrangedSubview(holdingsRow)
        holdingsRow.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -36).isActive = true
        addFullWidth(summary)
        missingLabel.font = .systemFont(ofSize: 11)
        missingLabel.textColor = Theme.brandAmber
        missingLabel.lineBreakMode = .byWordWrapping
        missingLabel.maximumNumberOfLines = 2
        addFullWidth(missingLabel)

        let riskCard = card()
        riskRateButton.target = self
        riskRateButton.action = #selector(editRiskFreeRate)
        riskRateButton.bezelStyle = .rounded
        riskRateButton.font = .systemFont(ofSize: 11, weight: .medium)
        riskRateButton.identifier = NSUserInterfaceItemIdentifier("marketbar.risk.rate")
        riskRateButton.toolTip = "Annual risk-free rate subtracted from returns. Set it to the current Treasury bill yield."
        let riskHeader = NSStackView(views: [caption("SHARPE RATIO BY PORTFOLIO"), NSView(), riskRateButton])
        riskHeader.alignment = .centerY
        riskCard.addArrangedSubview(riskHeader)
        riskHeader.widthAnchor.constraint(equalTo: riskCard.widthAnchor, constant: -36).isActive = true
        riskTable.orientation = .vertical
        riskTable.alignment = .leading
        riskTable.spacing = 0
        riskTable.identifier = NSUserInterfaceItemIdentifier("marketbar.risk.table")
        riskCard.addArrangedSubview(riskTable)
        riskTable.widthAnchor.constraint(equalTo: riskCard.widthAnchor, constant: -36).isActive = true
        riskNote.font = .systemFont(ofSize: 10)
        riskNote.textColor = Theme.textMuted
        riskCard.addArrangedSubview(riskNote)
        riskNote.widthAnchor.constraint(equalTo: riskCard.widthAnchor, constant: -36).isActive = true
        shownRiskRows = nil
        addFullWidth(riskCard)

        let chartCard = card()
        rangeControl.target = self
        rangeControl.action = #selector(changeRange)
        rangeControl.selectedSegment = PortfolioHistoryService.Range.allCases.firstIndex(of: historyRange) ?? 0
        historyRaw.target = self
        historyRaw.action = #selector(changeHistoryRaw)
        historyRaw.identifier = NSUserInterfaceItemIdentifier("portfolio.history.raw")
        historyRaw.toolTip = "Inspect original recorded values, including edits and suspect observations."
        let chartHeader = NSStackView(views: [caption("VALUE OVER TIME"), NSView(), historyRaw, rangeControl])
        chartHeader.alignment = .centerY
        chartCard.addArrangedSubview(chartHeader)
        chartHeader.widthAnchor.constraint(equalTo: chartCard.widthAnchor, constant: -36).isActive = true
        chartCard.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: chartCard.widthAnchor, constant: -36).isActive = true
        chartEmpty.font = .systemFont(ofSize: 11)
        chartEmpty.textColor = Theme.textMuted
        chart.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.chart")
        chartEmpty.identifier = NSUserInterfaceItemIdentifier("marketbar.portfolio.chart-empty")
        chartCard.addArrangedSubview(chartEmpty)
        historyNote.font = .systemFont(ofSize: 10)
        historyNote.textColor = Theme.textMuted
        historyNote.identifier = NSUserInterfaceItemIdentifier("portfolio.history.note")
        chartCard.addArrangedSubview(historyNote)
        addFullWidth(chartCard)

        let title = NSStackView(views: [label("Watchlist", size: 20, weight: .semibold), NSView(), button("Position", #selector(editPosition)), button("Remove", #selector(removeSymbol))])
        title.alignment = .centerY
        addFullWidth(title)
        page.setCustomSpacing(12, after: title)
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
            table.rowHeight = 40
            table.intercellSpacing = NSSize(width: 12, height: 2)
            table.gridStyleMask = .solidHorizontalGridLineMask
            table.gridColor = NSColor(white: 1, alpha: 0.05)
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
        tableScroll.wantsLayer = true
        tableScroll.layer?.cornerRadius = 12
        tableScroll.layer?.borderWidth = 1
        tableScroll.layer?.borderColor = NSColor(white: 1, alpha: 0.075).cgColor
        tableScroll.layer?.backgroundColor = NSColor(white: 1, alpha: 0.02).cgColor
        tableScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        addFullWidth(tableScroll)
        addFullWidth(label("Double-click a ticker for its chart, financials and headlines. Return shows only positions with recorded cost basis.", size: 11, color: Theme.textFaint))
        updateData()
    }

    @objc private func openRecovery() {
        NSApp.sendAction(#selector(AppDelegate.showRecoveryWindow), to: NSApp.delegate, from: self)
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
                returnLabel.stringValue = "\(widget.formatSignedCurrency(totalPL)) (\(String(format: "%+.2f%%", totalPercent)))"
                returnLabel.textColor = widget.intensityColor(for: totalPercent)
                returnDetail.stringValue = snapshot.hasPartialCostBasis ? "Cost basis recorded for part of portfolio" : "Since purchase"
            } else if !currencyComparable {
                returnLabel.stringValue = "—"
                returnLabel.textColor = Theme.textMuted
                returnDetail.stringValue = "Total return unavailable across mixed currencies."
            } else {
                returnLabel.stringValue = "—"
                returnLabel.textColor = Theme.textMuted
                returnDetail.stringValue = "Record position cost basis to track total return."
            }
            if currencyComparable {
                let invested = snapshot.positions.map(\.liveValue).reduce(0, +)
                let investedPercent = snapshot.liveTotal > 0 ? invested / snapshot.liveTotal * 100 : 0
                let leader = snapshot.positions.max { $0.liveValue < $1.liveValue }
                allocationLabel.stringValue = "\(String(format: "%.0f%%", investedPercent)) invested"
                allocationDetail.stringValue = leader.map { "Largest holding \($0.quote.symbol), \(String(format: "%.0f%%", $0.liveValue / max(snapshot.liveTotal, 1) * 100)) of portfolio" } ?? "No positions held"
            } else {
                allocationLabel.stringValue = "—"
                allocationDetail.stringValue = "Allocation unavailable across mixed currencies."
            }
        } else {
            moveLabel.stringValue = "Add a position to start tracking your portfolio."
            moveLabel.textColor = Theme.textMuted
            returnLabel.stringValue = "—"
            returnLabel.textColor = Theme.textMuted
            returnDetail.stringValue = ""
            allocationLabel.stringValue = "—"
            allocationDetail.stringValue = ""
        }
        let realized = config.realizedYearToDate()
        realizedLabel.stringValue = currencyComparable ? widget.formatSignedCurrency(realized) : "—"
        realizedLabel.textColor = currencyComparable ? widget.intensityColor(for: realized >= 0 ? 1 : -1) : Theme.textMuted
        realizedDetail.stringValue = currencyComparable ? "This calendar year · Eastern Time" : "Realized YTD unavailable across mixed currencies."
        cashLabel.stringValue = widget.formatCurrency(config.cash)
        cashLabel.textColor = config.cash < 0 ? Theme.red : Theme.textPrimary
        let positionCount = "\(config.holdings.count) position\(config.holdings.count == 1 ? "" : "s")"
        cashDetail.stringValue = config.isCombinedPortfolioActive
            ? "Automatic · \(config.portfolios.count) portfolios · \(positionCount)" : positionCount
        updateRisk(currencyComparable: currencyComparable)
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
            let price = NSTextField(labelWithString: quote.map { widget.formatCurrency($0.currentPrice) } ?? "Waiting for quote")
            price.font = .monospacedDigitSystemFont(ofSize: quote == nil ? 12 : 16, weight: .semibold)
            price.textColor = quote == nil ? Theme.textMuted : Theme.textPrimary
            let change = NSTextField(wrappingLabelWithString: quote.map { "\(String(format: "%+.2f%%", $0.currentChange)) today" } ?? "")
            change.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            change.textColor = quote.map { widget.intensityColor(for: $0.currentChange) } ?? Theme.textMuted
            let tile = statTile(name, value: price, detail: change, keepsFonts: true)
            tile.toolTip = quote.map { "\(symbol): \(widget.formatCurrency($0.currentPrice)), \(String(format: "%+.2f%%", $0.currentChange)) today" }
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
        let presentation = widget.portfolioHistoryPresentation(range: historyRange)
        let points = presentation.points
        let originals = Dictionary(uniqueKeysWithValues: widget.portfolioHistoryPoints(range: historyRange, raw: true).map { ($0.time, $0.value) })
        chart.samples = points.map { .init(date: $0.time, value: $0.value, observedValue: originals[$0.time]) }
        chart.axisStyle = historyRange.isIntraday ? .time : .date
        chart.compressesExtendedHours = historyRange.isIntraday && !widget.portfolioTradesContinuously
        chart.accent = widget.intensityColor(for: points.first.map { first in
            first.value > 0 ? ((points.last?.value ?? first.value) / first.value - 1) * 100 : 0
        } ?? 0)
        historyRaw.state = widget.config.historyShowsRaw && !historyRange.isIntraday ? .on : .off
        historyRaw.isEnabled = !historyRange.isIntraday
        historyNote.stringValue = historyRange.isIntraday ? (presentation.estimated ? "Current holdings estimate · Eastern Time" : "Recorded market movement · Eastern Time")
            : widget.config.historyShowsRaw ? "Recorded totals · market closures compressed"
            : "Market movement · holding/cash changes adjusted · isolated glitches hidden"
        chart.toolTip = historyNote.stringValue

        chartEmpty.isHidden = chart.samples.count >= 2
    }

    // MARK: - Sharpe ratio

    private func sharpeColor(_ metrics: PortfolioRiskMetrics) -> NSColor {
        guard let sharpe = metrics.sharpe else { return Theme.textMuted }
        return sharpe < 0 ? Theme.red : sharpe >= 1 ? Theme.green : Theme.textPrimary
    }

    private func updateRisk(currencyComparable: Bool) {
        let rate = String(format: "%.2f%%", widget.config.riskFreeRatePercent)
        riskRateButton.title = "Risk-free \(rate)…"
        riskNote.stringValue = "Annualized from each portfolio's daily closes over all recorded history, in excess of a \(rate) risk-free rate. Holding and cash changes are neutralized. An estimate from this app's observations, not a broker figure."
        guard currencyComparable else {
            sharpeLabel.stringValue = "—"
            sharpeLabel.textColor = Theme.textMuted
            sharpeDetail.stringValue = "Sharpe ratio unavailable across mixed currencies."
            return
        }
        let active = widget.activePortfolioRiskMetrics()
        sharpeLabel.stringValue = active.sharpeText
        sharpeLabel.textColor = sharpeColor(active)
        sharpeDetail.stringValue = active.annualVolatilityPercent.map {
            "\(active.coverageText) · volatility \(String(format: "%.1f%%", $0))"
        } ?? active.coverageText

        let rows = widget.portfolioRiskRows()
        guard rows != shownRiskRows else { return }
        shownRiskRows = rows
        riskTable.arrangedSubviews.forEach { riskTable.removeArrangedSubview($0); $0.removeFromSuperview() }
        let header = riskRow(["PORTFOLIO", "SHARPE", "RETURN", "VOLATILITY", "HISTORY"].map { caption($0) })
        riskTable.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: riskTable.widthAnchor).isActive = true
        for row in rows {
            let m = row.metrics
            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: 12, weight: row.isActive ? .semibold : .regular)
            name.textColor = row.isActive ? Theme.brandCyan : Theme.textPrimary
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = row.isActive ? "\(row.name) · shown above" : row.name
            let sharpe = Theme.monoLabel(m.sharpeText, size: 13, color: sharpeColor(m))
            sharpe.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            sharpe.identifier = NSUserInterfaceItemIdentifier("marketbar.risk.sharpe.\(row.id)")
            let period = Theme.monoLabel(m.periodReturnPercent.map { String(format: "%+.2f%%", $0) } ?? "—", size: 12,
                                         color: m.periodReturnPercent.map { widget.intensityColor(for: $0) } ?? Theme.textMuted)
            period.toolTip = "Total market movement across the recorded history"
            let volatility = Theme.monoLabel(m.annualVolatilityPercent.map { String(format: "%.1f%%", $0) } ?? "—", size: 12,
                                             color: m.annualVolatilityPercent == nil ? Theme.textMuted : Theme.textPrimary)
            volatility.toolTip = "Annualized standard deviation of daily returns"
            let coverage = NSTextField(labelWithString: m.coverageText)
            coverage.font = .systemFont(ofSize: 11)
            coverage.textColor = Theme.textMuted
            coverage.lineBreakMode = .byTruncatingTail
            coverage.toolTip = m.coverageText
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            riskTable.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: riskTable.widthAnchor).isActive = true
            let view = riskRow([name, sharpe, period, volatility, coverage])
            view.setAccessibilityLabel("\(row.name): Sharpe ratio \(m.sharpeText), \(m.coverageText)")
            riskTable.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: riskTable.widthAnchor).isActive = true
        }
    }

    /// Fixed column shares, so every row lines up without a table view.
    private func riskRow(_ cells: [NSView]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let shares: [CGFloat] = [0.24, 0.12, 0.14, 0.14, 0.36]
        var offset: CGFloat = 0
        for (cell, share) in zip(cells, shares) {
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addSubview(cell)
            let guide = NSLayoutGuide()
            row.addLayoutGuide(guide)
            NSLayoutConstraint.activate([
                guide.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                guide.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: max(offset, 0.0001)),
                cell.leadingAnchor.constraint(equalTo: offset == 0 ? row.leadingAnchor : guide.trailingAnchor),
                cell.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: share, constant: -10),
                cell.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            offset += share
        }
        return row
    }

    @objc private func editRiskFreeRate() {
        guard let raw = input(title: "Risk-free rate", value: String(format: "%.2f", widget.config.riskFreeRatePercent),
                              hint: "Annual percent, e.g. 4.00") else { return }
        guard let percent = Double(raw.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")),
              widget.setRiskFreeRate(percent: percent) else {
            problem("Enter an annual rate between 0 and 25 percent.")
            return
        }
        updateData()
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
    @objc private func changeHistoryRaw() {
        widget.config.historyShowsRaw.toggle()
        widget.saveConfig()
        updateData()
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
        for (title, action) in [("Reconcile realized YTD…", #selector(reconcileRealizedYTD)), ("Rename portfolio…", #selector(renamePortfolio)), ("Delete portfolio…", #selector(deletePortfolio))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != #selector(deletePortfolio) || widget.config.portfolios.count > 1
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: portfolioPicker.bounds.minY), in: portfolioPicker)
    }
    @objc private func reconcileRealizedYTD() {
        if RealizedYearToDateForm.present(widget: widget) { updateData() }
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
        guard widget.deletePortfolio(id: widget.config.activePortfolioID) else {
            problem("The portfolio was kept because a recovery backup could not be saved. Open Backup & Recovery for details.")
            return
        }
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
    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Theme.textFaint,
            .kern: 0.9
        ])
        return label
    }

    /// A caption, one prominent figure and a line of context. The value and
    /// detail labels are owned by the caller so live updates never rebuild it.
    private func statTile(_ title: String, value: NSTextField, detail: NSTextField, accessory: NSView? = nil,
                          keepsFonts: Bool = false) -> NSStackView {
        if !keepsFonts {
            value.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = Theme.textMuted
        }
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.maximumNumberOfLines = 2
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tile = NSStackView()
        tile.orientation = .vertical
        tile.alignment = .leading
        tile.spacing = 5
        tile.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        tile.wantsLayer = true
        tile.layer?.backgroundColor = NSColor(white: 1, alpha: 0.035).cgColor
        tile.layer?.cornerRadius = 10
        if let accessory {
            let top = NSStackView(views: [caption(title), NSView(), accessory])
            top.alignment = .centerY
            tile.addArrangedSubview(top)
            top.widthAnchor.constraint(equalTo: tile.widthAnchor, constant: -28).isActive = true
        } else {
            tile.addArrangedSubview(caption(title))
        }
        tile.addArrangedSubview(value)
        tile.addArrangedSubview(detail)
        for view in [value, detail] {
            view.widthAnchor.constraint(lessThanOrEqualTo: tile.widthAnchor, constant: -28).isActive = true
        }
        return tile
    }

    private func tileRow(_ tiles: [NSView]) -> NSStackView {
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 10
        if let first = tiles.first {
            tiles.dropFirst().forEach { $0.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true }
        }
        return row
    }

    private func card() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor(white: 1, alpha: 0.035).cgColor
        stack.layer?.cornerRadius = 14
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
