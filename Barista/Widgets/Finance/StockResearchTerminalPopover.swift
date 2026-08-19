import Cocoa

// MARK: - Stock Research Terminal Popovers

private struct ResearchMetric {
    let id: String
    let label: String
    let value: String
    let detail: String
    let color: NSColor
    let lineData: [Double]
    let barData: [Double]
    let thesis: String
}

class StockDetailPopoverController: NSViewController, XMLParserDelegate {
    private weak var widget: StockTickerWidget?
    private let quote: MarketQuote
    private let popoverW: CGFloat = 620
    private let popoverH: CGFloat = 760
    private var newsContainer: NSView?
    private var secFundamentalsContainer: NSView?
    private var terminalChartView: TerminalStockChartView?
    private var chartRangeButtons: [StockChartRange: NSButton] = [:]
    private var chartRange: StockChartRange = .oneDay
    private var newsItems: [(title: String, link: String)] = []
    private var metricLookup: [String: ResearchMetric] = [:]
    private var fundamentalLookup: [String: FundamentalMetricSeries] = [:]
    private var metricPopover: NSPopover?
    private var fundamentalPopover: NSPopover?
    private var liveRefreshTimer: Timer?

    private var parsingItem = false
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var parsedNews: [(title: String, link: String)] = []

    init(widget: StockTickerWidget, quote: MarketQuote) {
        self.widget = widget
        self.quote = quote
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = buildView()
        fetchNews()
        fetchFundamentals()
        fetchPriceHistory(range: chartRange)
        startLiveRefreshTimer()
    }

    deinit {
        liveRefreshTimer?.invalidate()
    }

    private func startLiveRefreshTimer() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: StockTickerWidget.turboRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshLiveData(forceChart: true)
        }
    }

    private func buildView() -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: popoverW, height: popoverH))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: popoverW, height: 2400))
        doc.wantsLayer = true
        scroll.documentView = doc

        let pad: CGFloat = 16
        let cw = popoverW - pad * 2
        var y: CGFloat = 14

        y = addHeader(to: doc, y: y, pad: pad, cw: cw)
        y = addTerminalNavigator(to: doc, y: y + 8, pad: pad, cw: cw)
        y = addChart(to: doc, y: y + 8, pad: pad, cw: cw)
        y = addSnapshot(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addCompanyIntelligence(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addFundamentals(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addSECFundamentals(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addFinancialStack(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addScenarioModel(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addOwnershipAndFlow(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addFilingsAndEvents(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addResearchReadout(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addNews(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addDataAudit(to: doc, y: y + 10, pad: pad, cw: cw)
        y = addActions(to: doc, y: y + 10, pad: pad, cw: cw)

        doc.frame.size.height = max(y + 16, popoverH + 1)
        return scroll
    }

    private func addHeader(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let h: CGFloat = 86
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let accent = w.intensityColor(for: quote.chartChange)
        let symbol = NSTextField(labelWithString: quote.symbol)
        symbol.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        symbol.textColor = Theme.textPrimary
        symbol.frame = NSRect(x: 14, y: 12, width: 128, height: 30)
        card.addSubview(symbol)

        let type = quote.kind == .stock ? "Stock" : "Crypto"
        let session = quote.extendedHours?.label ?? (quote.kind == .stock ? quote.marketStatus.label : "24/7 Market")
        let subtitle = NSTextField(labelWithString: "\(type)  \(session)  \(w.freshnessDescription())")
        subtitle.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = Theme.textFaint
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 15, y: 44, width: 240, height: 14)
        card.addSubview(subtitle)

        let price = NSTextField(labelWithString: "$" + w.formatPrice(quote.currentPrice))
        price.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        price.textColor = Theme.textPrimary
        price.alignment = .right
        price.frame = NSRect(x: cw - 190, y: 12, width: 176, height: 30)
        card.addSubview(price)

        let move = quote.currentPrice - (quote.chartBaseline ?? quote.price)
        let changeText = String(format: "%@%.2f%%  %@",
                                quote.chartChange >= 0 ? "+" : "",
                                quote.chartChange,
                                w.formatSignedCurrency(move))
        let change = NSTextField(labelWithString: changeText)
        change.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        change.textColor = accent
        change.alignment = .right
        change.frame = NSRect(x: cw - 230, y: 44, width: 216, height: 15)
        card.addSubview(change)

        let chips = headerChips()
        let chipW = (cw - 28 - CGFloat(max(chips.count - 1, 0)) * 8) / CGFloat(max(chips.count, 1))
        for (i, chip) in chips.enumerated() {
            let chipView = NSView(frame: NSRect(x: 14 + CGFloat(i) * (chipW + 8), y: 64, width: chipW, height: 16))
            chipView.wantsLayer = true
            chipView.layer?.cornerRadius = 8
            chipView.layer?.backgroundColor = chip.color.withAlphaComponent(0.10).cgColor
            chipView.layer?.borderWidth = 0.5
            chipView.layer?.borderColor = chip.color.withAlphaComponent(0.24).cgColor
            card.addSubview(chipView)

            let label = NSTextField(labelWithString: chip.text)
            label.font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
            label.textColor = chip.color.withAlphaComponent(0.88)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 6, y: 3, width: chipW - 12, height: 10)
            chipView.addSubview(label)
        }

        return y + h
    }

    private func addTerminalNavigator(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let h: CGFloat = 54
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = NSTextField(labelWithString: "BARISTA RESEARCH TERMINAL")
        title.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        title.textColor = Theme.textFaint
        title.frame = NSRect(x: 12, y: 9, width: 190, height: 12)
        card.addSubview(title)

        let score = terminalScore()
        let scoreLabel = NSTextField(labelWithString: String(format: "Terminal Score %.0f", score))
        scoreLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        scoreLabel.textColor = w.intensityColor(for: score - 50)
        scoreLabel.alignment = .right
        scoreLabel.frame = NSRect(x: cw - 142, y: 9, width: 128, height: 12)
        card.addSubview(scoreLabel)

        let chips = [
            ("Overview", true, Theme.brandCyan),
            ("Financials", quote.marketCap != nil || quote.peRatio != nil, Theme.brandAmber),
            ("Estimates", quote.kind == .stock, Theme.purple),
            ("Ownership", widget?.config.holdings[quote.symbol] != nil, Theme.brandCyan),
            ("Filings", quote.kind == .stock, Theme.textSecondary),
            ("News", quote.kind == .stock, Theme.green)
        ]
        let gap: CGFloat = 6
        let chipW = (cw - 24 - gap * CGFloat(chips.count - 1)) / CGFloat(chips.count)
        for (i, chip) in chips.enumerated() {
            let x = 12 + CGFloat(i) * (chipW + gap)
            let pill = NSView(frame: NSRect(x: x, y: 28, width: chipW, height: 16))
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 8
            pill.layer?.backgroundColor = chip.1 ? chip.2.withAlphaComponent(0.10).cgColor : Theme.cardBg.cgColor
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = chip.1 ? chip.2.withAlphaComponent(0.24).cgColor : Theme.cardBorder.cgColor
            card.addSubview(pill)

            let label = NSTextField(labelWithString: chip.0)
            label.font = NSFont.systemFont(ofSize: 8, weight: .semibold)
            label.textColor = chip.1 ? chip.2.withAlphaComponent(0.88) : Theme.textGhost
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 4, y: 3, width: chipW - 8, height: 10)
            pill.addSubview(label)
        }

        return y + h
    }

    private func addChart(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let h: CGFloat = 360
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("PRICE TERMINAL")
        title.frame = NSRect(x: 14, y: 12, width: 160, height: 14)
        card.addSubview(title)

        let period = NSTextField(labelWithString: quote.kind == .stock ? "MULTI-RANGE + VOLUME + MA" : "7D LIVE SAMPLES")
        period.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        period.textColor = Theme.textFaint
        period.alignment = .right
        period.frame = NSRect(x: cw - 210, y: 13, width: 196, height: 12)
        card.addSubview(period)

        if quote.kind == .stock {
            addChartRangeControls(to: card, cw: cw)
        }

        let chartH: CGFloat = 236
        let chartW = cw - 24
        let chartBg = NSView(frame: NSRect(x: 12, y: 66, width: chartW, height: chartH))
        chartBg.wantsLayer = true
        chartBg.layer?.cornerRadius = 9
        chartBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        chartBg.layer?.borderWidth = 0.5
        chartBg.layer?.borderColor = Theme.cardBorder.withAlphaComponent(0.6).cgColor
        card.addSubview(chartBg)

        if quote.chartSeries.count >= 2 {
            let chart = TerminalStockChartView(widget: w, quote: quote, history: nil, frame: chartBg.bounds)
            chart.autoresizingMask = [.width, .height]
            chartBg.addSubview(chart)
            terminalChartView = chart
        } else {
            let empty = NSTextField(labelWithString: "Chart loading...")
            empty.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            empty.textColor = Theme.textFaint
            empty.alignment = .center
            empty.frame = chartBg.bounds
            chartBg.addSubview(empty)
        }

        let stats = chartStats()
        let statW = (cw - 24 - CGFloat(stats.count - 1) * 8) / CGFloat(stats.count)
        for (i, stat) in stats.enumerated() {
            let sx = 12 + CGFloat(i) * (statW + 8)
            let box = NSView(frame: NSRect(x: sx, y: 314, width: statW, height: 28))
            box.wantsLayer = true
            box.layer?.cornerRadius = 7
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
            card.addSubview(box)

            let label = NSTextField(labelWithString: stat.0.uppercased())
            label.font = NSFont.systemFont(ofSize: 7, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 7, y: 5, width: statW - 14, height: 8)
            box.addSubview(label)

            let value = NSTextField(labelWithString: stat.1)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
            value.textColor = stat.2 ?? Theme.textSecondary
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 7, y: 16, width: statW - 14, height: 10)
            box.addSubview(value)
        }

        return y + h
    }

    private func addChartRangeControls(to card: NSView, cw: CGFloat) {
        chartRangeButtons.removeAll()
        let ranges = StockChartRange.allCases
        let gap: CGFloat = 6
        let totalW: CGFloat = 270
        let buttonW = (totalW - gap * CGFloat(ranges.count - 1)) / CGFloat(ranges.count)
        let startX = cw - totalW - 12
        for (index, range) in ranges.enumerated() {
            let x = startX + CGFloat(index) * (buttonW + gap)
            let button = NSButton(frame: NSRect(x: x, y: 34, width: buttonW, height: 20))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.tag = index
            button.target = self
            button.action = #selector(chartRangeClicked(_:))
            styleChartRangeButton(button, range: range)
            card.addSubview(button)
            chartRangeButtons[range] = button
        }

        let legend = NSTextField(labelWithString: "Price  MA20  MA50  Volume")
        legend.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        legend.textColor = Theme.textGhost
        legend.frame = NSRect(x: 14, y: 39, width: 168, height: 10)
        card.addSubview(legend)
    }

    private func styleChartRangeButton(_ button: NSButton, range: StockChartRange) {
        let selected = range == chartRange
        let color = selected ? Theme.brandCyan : Theme.textMuted
        button.layer?.backgroundColor = selected ? Theme.brandCyan.withAlphaComponent(0.13).cgColor : NSColor.black.withAlphaComponent(0.12).cgColor
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = selected ? Theme.brandCyan.withAlphaComponent(0.32).cgColor : Theme.cardBorder.cgColor
        button.attributedTitle = NSAttributedString(string: range.rawValue, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: color
        ])
    }

    private func addSnapshot(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let hasDayRange = quote.dayLow != nil && quote.dayHigh != nil
        let hasYearRange = quote.fiftyTwoWeekLow != nil && quote.fiftyTwoWeekHigh != nil
        let barCount = [hasDayRange, hasYearRange].filter { $0 }.count
        let h: CGFloat = barCount == 0 ? 118 : (barCount == 1 ? 154 : 190)
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("SNAPSHOT")
        title.frame = NSRect(x: 14, y: 12, width: 110, height: 14)
        card.addSubview(title)

        let summary = snapshotSummary()
        let boxW = (cw - 36) / 3
        for (i, item) in summary.enumerated() {
            let box = NSView(frame: NSRect(x: 12 + CGFloat(i) * (boxW + 6), y: 34, width: boxW, height: 56))
            box.wantsLayer = true
            box.layer?.cornerRadius = 8
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
            box.layer?.borderWidth = 0.5
            box.layer?.borderColor = item.color.withAlphaComponent(0.18).cgColor
            card.addSubview(box)

            let label = NSTextField(labelWithString: item.label.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 8, y: 8, width: boxW - 16, height: 9)
            box.addSubview(label)

            let value = NSTextField(labelWithString: item.value)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            value.textColor = item.color
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 8, y: 20, width: boxW - 16, height: 17)
            box.addSubview(value)

            let detail = NSTextField(labelWithString: item.detail)
            detail.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
            detail.textColor = Theme.textFaint
            detail.lineBreakMode = .byTruncatingTail
            detail.frame = NSRect(x: 8, y: 39, width: boxW - 16, height: 10)
            box.addSubview(detail)
        }

        var barY: CGFloat = 102
        if let low = quote.dayLow, let high = quote.dayHigh, high > low {
            addRangeRow(to: card,
                        y: barY,
                        w: cw,
                        title: "Day range",
                        low: low,
                        high: high,
                        current: quote.currentPrice,
                        tint: w.intensityColor(for: quote.chartChange))
            barY += 36
        }

        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, high > low {
            addRangeRow(to: card,
                        y: barY,
                        w: cw,
                        title: "52 week range",
                        low: low,
                        high: high,
                        current: quote.currentPrice,
                        tint: Theme.brandCyan)
        }

        return y + h
    }

    private func addCompanyIntelligence(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let h: CGFloat = 190
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("COMPANY INTELLIGENCE")
        title.frame = NSRect(x: 12, y: 12, width: 190, height: 14)
        card.addSubview(title)

        let source = NSTextField(labelWithString: quote.kind == .stock ? "LIVE QUOTE + LOCAL RESEARCH LAYER" : "LIVE CRYPTO + LOCAL RESEARCH LAYER")
        source.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        source.textColor = Theme.brandCyan.withAlphaComponent(0.68)
        source.alignment = .right
        source.frame = NSRect(x: cw - 250, y: 13, width: 236, height: 10)
        card.addSubview(source)

        let cells = companyIntelligenceCells()
        let gap: CGFloat = 8
        let cellW = (cw - 24 - gap * CGFloat(cells.count - 1)) / CGFloat(cells.count)
        for (i, cell) in cells.enumerated() {
            addMiniStatCard(to: card,
                            frame: NSRect(x: 12 + CGFloat(i) * (cellW + gap), y: 36, width: cellW, height: 54),
                            label: cell.label,
                            value: cell.value,
                            detail: cell.detail,
                            color: cell.color)
        }

        let rows = intelligenceRows()
        for (i, row) in rows.enumerated() {
            let rowY = 104 + CGFloat(i) * 25
            let dot = NSView(frame: NSRect(x: 14, y: rowY + 6, width: 7, height: 7))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = row.color.withAlphaComponent(0.9).cgColor
            card.addSubview(dot)

            let label = NSTextField(labelWithString: row.label.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 28, y: rowY, width: 86, height: 9)
            card.addSubview(label)

            let value = NSTextField(labelWithString: row.value)
            value.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            value.textColor = Theme.textSecondary
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 28, y: rowY + 10, width: cw - 42, height: 13)
            card.addSubview(value)
        }

        let health = TerminalFlowBarsView(frame: NSRect(x: 12, y: 166, width: cw - 24, height: 10),
                                          values: terminalHealthBars(),
                                          colors: [w.intensityColor(for: quote.chartChange), Theme.brandAmber, Theme.brandCyan, Theme.purple])
        card.addSubview(health)

        return y + h
    }

    private func addFinancialStack(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let rows = financialRows()
        let h: CGFloat = 48 + CGFloat(rows.count) * 30
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("FINANCIALS, RATIOS & KPI PROXIES")
        title.frame = NSRect(x: 12, y: 12, width: 240, height: 14)
        card.addSubview(title)

        let badge = NSTextField(labelWithString: "CLICK METRICS ABOVE FOR CHARTS")
        badge.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        badge.textColor = Theme.textGhost
        badge.alignment = .right
        badge.frame = NSRect(x: cw - 210, y: 13, width: 196, height: 10)
        card.addSubview(badge)

        addTableHeader(to: card, y: 34, cw: cw, columns: ["Metric", "Value", "Context", "Source"])
        for (i, row) in rows.enumerated() {
            addFinancialRow(to: card, y: 52 + CGFloat(i) * 30, cw: cw, row: row)
        }

        return y + h
    }

    private func addScenarioModel(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let h: CGFloat = 190
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("ESTIMATES & VALUATION SCENARIOS")
        title.frame = NSRect(x: 12, y: 12, width: 235, height: 14)
        card.addSubview(title)

        let note = NSTextField(labelWithString: quote.kind == .stock ? "Scenario layer uses live price, 52W range, P/E and session momentum." : "Crypto scenario layer uses live price, 24h range and tape momentum.")
        note.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        note.textColor = Theme.textFaint
        note.alignment = .right
        note.lineBreakMode = .byTruncatingTail
        note.frame = NSRect(x: cw - 342, y: 13, width: 328, height: 11)
        card.addSubview(note)

        let scenarios = scenarioTargets()
        let gap: CGFloat = 8
        let boxW = (cw - 24 - gap * 2) / 3
        for (i, scenario) in scenarios.enumerated() {
            let x = 12 + CGFloat(i) * (boxW + gap)
            let box = NSView(frame: NSRect(x: x, y: 38, width: boxW, height: 88))
            box.wantsLayer = true
            box.layer?.cornerRadius = 9
            box.layer?.backgroundColor = scenario.color.withAlphaComponent(0.055).cgColor
            box.layer?.borderWidth = 0.5
            box.layer?.borderColor = scenario.color.withAlphaComponent(0.16).cgColor
            card.addSubview(box)

            let name = NSTextField(labelWithString: scenario.name.uppercased())
            name.font = NSFont.systemFont(ofSize: 8, weight: .bold)
            name.textColor = Theme.textGhost
            name.frame = NSRect(x: 9, y: 8, width: boxW - 18, height: 10)
            box.addSubview(name)

            let target = NSTextField(labelWithString: "$" + w.formatPrice(scenario.target))
            target.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
            target.textColor = scenario.color
            target.frame = NSRect(x: 9, y: 25, width: boxW - 18, height: 22)
            box.addSubview(target)

            let upside = scenario.target > 0 ? (scenario.target - quote.currentPrice) / quote.currentPrice * 100 : 0
            let up = NSTextField(labelWithString: String(format: "%@%.1f%% vs now", upside >= 0 ? "+" : "", upside))
            up.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            up.textColor = w.intensityColor(for: upside)
            up.frame = NSRect(x: 9, y: 51, width: boxW - 18, height: 12)
            box.addSubview(up)

            let driver = NSTextField(labelWithString: scenario.driver)
            driver.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
            driver.textColor = Theme.textFaint
            driver.lineBreakMode = .byTruncatingTail
            driver.frame = NSRect(x: 9, y: 67, width: boxW - 18, height: 10)
            box.addSubview(driver)
        }

        addTerminalButton(to: card, title: "Yahoo Analysis", id: "analysis", frame: NSRect(x: 12, y: 140, width: 116, height: 24), color: Theme.brandCyan)
        addTerminalButton(to: card, title: "Financials", id: "financials", frame: NSRect(x: 136, y: 140, width: 96, height: 24), color: Theme.brandAmber)
        addTerminalButton(to: card, title: "Fiscal.ai", id: "fiscal", frame: NSRect(x: cw - 98, y: 140, width: 86, height: 24), color: Theme.purple)

        let disclaimer = NSTextField(labelWithString: "Scenarios are Barista research math, not analyst consensus. Use the linked sources for official estimates.")
        disclaimer.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        disclaimer.textColor = Theme.textGhost
        disclaimer.lineBreakMode = .byTruncatingTail
        disclaimer.frame = NSRect(x: 12, y: 169, width: cw - 24, height: 10)
        card.addSubview(disclaimer)

        return y + h
    }

    private func addOwnershipAndFlow(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let h: CGFloat = 184
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("OWNERSHIP, PORTFOLIO & FLOW")
        title.frame = NSRect(x: 12, y: 12, width: 210, height: 14)
        card.addSubview(title)

        let leftW = (cw - 32) * 0.47
        let rightW = cw - 44 - leftW

        let positionTitle = NSTextField(labelWithString: "LOCAL POSITION")
        positionTitle.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        positionTitle.textColor = Theme.textGhost
        positionTitle.frame = NSRect(x: 12, y: 38, width: leftW, height: 10)
        card.addSubview(positionTitle)

        let positionRows = ownershipRows()
        for (i, row) in positionRows.enumerated() {
            addSimpleKV(to: card,
                        y: 58 + CGFloat(i) * 25,
                        x: 12,
                        width: leftW,
                        label: row.label,
                        value: row.value,
                        color: row.color)
        }

        addTerminalButton(to: card, title: "Yahoo Holders", id: "holders", frame: NSRect(x: 12, y: 146, width: 112, height: 24), color: Theme.brandCyan)

        let flowTitle = NSTextField(labelWithString: "TAPE FLOW")
        flowTitle.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        flowTitle.textColor = Theme.textGhost
        flowTitle.frame = NSRect(x: 28 + leftW, y: 38, width: rightW, height: 10)
        card.addSubview(flowTitle)

        let flowBars = TerminalFlowBarsView(frame: NSRect(x: 28 + leftW, y: 58, width: rightW, height: 46),
                                            values: terminalHealthBars(),
                                            colors: [w.intensityColor(for: quote.chartChange), Theme.brandAmber, Theme.brandCyan, Theme.purple])
        card.addSubview(flowBars)

        let flowRows = flowRows()
        for (i, row) in flowRows.enumerated() {
            addSimpleKV(to: card,
                        y: 112 + CGFloat(i) * 20,
                        x: 28 + leftW,
                        width: rightW,
                        label: row.label,
                        value: row.value,
                        color: row.color)
        }

        return y + h
    }

    private func addFilingsAndEvents(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let h: CGFloat = 158
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("FILINGS, EVENTS & SOURCE TRAIL")
        title.frame = NSRect(x: 12, y: 12, width: 220, height: 14)
        card.addSubview(title)

        let rows = filingRows()
        for (i, row) in rows.enumerated() {
            let yPos = 40 + CGFloat(i) * 25
            let label = NSTextField(labelWithString: row.label.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 14, y: yPos, width: 100, height: 9)
            card.addSubview(label)

            let value = NSTextField(labelWithString: row.value)
            value.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            value.textColor = row.color
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 114, y: yPos - 1, width: cw - 128, height: 13)
            card.addSubview(value)
        }

        addTerminalButton(to: card, title: "SEC Search", id: "sec", frame: NSRect(x: 12, y: 122, width: 96, height: 24), color: Theme.textSecondary)
        addTerminalButton(to: card, title: "Profile", id: "profile", frame: NSRect(x: 116, y: 122, width: 82, height: 24), color: Theme.brandCyan)
        addTerminalButton(to: card, title: "Events", id: "calendar", frame: NSRect(x: 206, y: 122, width: 82, height: 24), color: Theme.brandAmber)
        addTerminalButton(to: card, title: "News", id: "news", frame: NSRect(x: 296, y: 122, width: 72, height: 24), color: Theme.green)

        return y + h
    }

    private func addRangeRow(to card: NSView, y: CGFloat, w: CGFloat, title: String, low: Double, high: Double, current: Double, tint: NSColor) {
        guard let widget = widget else { return }
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        titleLabel.textColor = Theme.textGhost
        titleLabel.frame = NSRect(x: 14, y: y, width: 110, height: 10)
        card.addSubview(titleLabel)

        let lowLabel = smallMono("$" + widget.formatPrice(low), color: Theme.textFaint, align: .left)
        lowLabel.frame = NSRect(x: 14, y: y + 19, width: 72, height: 10)
        card.addSubview(lowLabel)

        let highLabel = smallMono("$" + widget.formatPrice(high), color: Theme.textFaint, align: .right)
        highLabel.frame = NSRect(x: w - 86, y: y + 19, width: 72, height: 10)
        card.addSubview(highLabel)

        let track = StockRangeTrackView(frame: NSRect(x: 92, y: y + 15, width: w - 184, height: 14),
                                        low: low,
                                        high: high,
                                        current: current,
                                        tint: tint)
        card.addSubview(track)

        let pos = rangePosition(value: current, low: low, high: high) ?? 0
        let currentLabel = smallMono(String(format: "%.0f%%", pos * 100), color: tint, align: .right)
        currentLabel.frame = NSRect(x: w - 62, y: y, width: 48, height: 10)
        card.addSubview(currentLabel)
    }

    private func addFundamentals(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let metrics = fundamentals()
        metricLookup = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0) })
        let rows = CGFloat((metrics.count + 1) / 2)
        let h = 32 + rows * 48 + 10
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("TERMINAL METRICS")
        title.frame = NSRect(x: 12, y: 10, width: 160, height: 14)
        card.addSubview(title)

        let badge = NSTextField(labelWithString: "CHART LAYERS")
        badge.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        badge.textColor = Theme.brandCyan.withAlphaComponent(0.64)
        badge.alignment = .right
        badge.frame = NSRect(x: cw - 104, y: 11, width: 92, height: 10)
        card.addSubview(badge)

        let gap: CGFloat = 8
        let metricW = (cw - 24 - gap) / 2
        for (i, item) in metrics.enumerated() {
            let col = i % 2
            let row = i / 2
            let mx = 12 + CGFloat(col) * (metricW + gap)
            let my = 34 + CGFloat(row) * 48
            let mcard = NSView(frame: NSRect(x: mx, y: my, width: metricW, height: 40))
            mcard.wantsLayer = true
            mcard.layer?.cornerRadius = 8
            mcard.layer?.backgroundColor = item.color.withAlphaComponent(0.055).cgColor
            mcard.layer?.borderWidth = 0.5
            mcard.layer?.borderColor = item.color.withAlphaComponent(0.14).cgColor
            card.addSubview(mcard)

            let label = NSTextField(labelWithString: item.label.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 8, y: 6, width: metricW - 34, height: 9)
            mcard.addSubview(label)

            let value = NSTextField(labelWithString: item.value)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            value.textColor = item.color
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 8, y: 16, width: metricW - 16, height: 13)
            mcard.addSubview(value)

            let detail = NSTextField(labelWithString: item.detail)
            detail.font = NSFont.systemFont(ofSize: 7.5, weight: .medium)
            detail.textColor = Theme.textGhost
            detail.lineBreakMode = .byTruncatingTail
            detail.frame = NSRect(x: 8, y: 30, width: metricW - 28, height: 8)
            mcard.addSubview(detail)

            let icon = NSImageView(frame: NSRect(x: metricW - 18, y: 7, width: 10, height: 10))
            icon.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: item.label)
            icon.contentTintColor = item.color.withAlphaComponent(0.62)
            mcard.addSubview(icon)

            let btn = NSButton(frame: mcard.bounds)
            btn.isBordered = false
            btn.isTransparent = true
            btn.target = self
            btn.action = #selector(showMetricDetail(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(item.id)
            mcard.addSubview(btn)
        }

        return y + h
    }

    private func addSECFundamentals(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let h: CGFloat = 1040
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("SEC FUNDAMENTALS")
        title.frame = NSRect(x: 12, y: 12, width: 170, height: 14)
        card.addSubview(title)

        let badge = NSTextField(labelWithString: quote.kind == .stock ? "FILED XBRL COMPANY FACTS" : "PUBLIC FILINGS NOT AVAILABLE")
        badge.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        badge.textColor = quote.kind == .stock ? Theme.brandCyan.withAlphaComponent(0.68) : Theme.textGhost
        badge.alignment = .right
        badge.frame = NSRect(x: cw - 220, y: 13, width: 206, height: 10)
        card.addSubview(badge)

        let container = NSView(frame: NSRect(x: 10, y: 34, width: cw - 20, height: h - 44))
        card.addSubview(container)
        secFundamentalsContainer = container
        renderFundamentalsLoading()
        return y + h
    }

    private func fundamentals() -> [ResearchMetric] {
        guard let w = widget else { return [] }
        var items: [ResearchMetric] = []
        let baseline = quote.chartBaseline ?? quote.baselinePrice
        let absMove = baseline.map { quote.currentPrice - $0 }
        let priceSeries = quote.chartSeries.filter { $0.isFinite && $0 > 0 }
        let returnSeries = metricReturnSeries(from: priceSeries, baseline: baseline)
        let moveBars = metricMoveBars(from: priceSeries)
        let accent = w.intensityColor(for: quote.chartChange)

        items.append(metric(id: "last_price",
                            label: "Last Price",
                            value: "$" + w.formatPrice(quote.currentPrice),
                            detail: "\(priceSeries.count) price samples",
                            color: Theme.textPrimary,
                            lineData: priceSeries,
                            barData: moveBars,
                            thesis: "Live price path from the available intraday sample set, with bars showing sample-to-sample movement."))
        items.append(metric(id: "session_move",
                            label: "Session Move",
                            value: String(format: "%@%.2f%%", quote.chartChange >= 0 ? "+" : "", quote.chartChange),
                            detail: baseline.map { "vs $" + w.formatPrice($0) } ?? "vs recent base",
                            color: accent,
                            lineData: returnSeries,
                            barData: moveBars,
                            thesis: "Percent move is anchored to the active baseline, using premarket or after-hours price when available."))
        if let absMove {
            items.append(metric(id: "dollar_move",
                                label: "Dollar Move",
                                value: w.formatSignedCurrency(absMove),
                                detail: "absolute session delta",
                                color: w.intensityColor(for: absMove),
                                lineData: priceSeries.map { $0 - (baseline ?? $0) },
                                barData: moveBars,
                                thesis: "Dollar movement converts the percent change into actual price distance from baseline."))
        }
        if let baseline {
            items.append(metric(id: "baseline",
                                label: "Baseline",
                                value: "$" + w.formatPrice(baseline),
                                detail: quote.kind == .stock ? "prev close anchor" : "range anchor",
                                color: Theme.textSecondary,
                                lineData: priceSeries,
                                barData: [baseline, quote.currentPrice],
                                thesis: "Baseline is the anchor used for session math and chart coloring."))
        }
        if let previous = quote.previousClose {
            items.append(metric(id: "previous_close",
                                label: "Prev Close",
                                value: "$" + w.formatPrice(previous),
                                detail: "regular session close",
                                color: Theme.textSecondary,
                                lineData: priceSeries,
                                barData: [previous, quote.currentPrice],
                                thesis: "Previous close drives regular-session comparison and extended-hours percent math."))
        }
        if let open = quote.openPrice {
            items.append(metric(id: "open",
                                label: "Open",
                                value: "$" + w.formatPrice(open),
                                detail: "session open print",
                                color: Theme.textSecondary,
                                lineData: priceSeries,
                                barData: [open, quote.currentPrice],
                                thesis: "Open shows where the regular session started relative to current trading."))
        }
        if let low = quote.dayLow, let high = quote.dayHigh {
            let pos = rangePosition(value: quote.currentPrice, low: low, high: high) ?? 0
            items.append(metric(id: "day_range",
                                label: "Day Range",
                                value: "\(w.formatPrice(low)) - \(w.formatPrice(high))",
                                detail: String(format: "%.0f%% through range", pos * 100),
                                color: Theme.brandAmber,
                                lineData: priceSeries,
                                barData: [low, quote.currentPrice, high],
                                thesis: "Day range shows whether current price is pressing highs, fading toward lows, or sitting mid-range."))
            if let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
                items.append(metric(id: "day_position",
                                    label: "Day Position",
                                    value: String(format: "%.0f%% of range", pos * 100),
                                    detail: pos > 0.66 ? "near high" : (pos < 0.33 ? "near low" : "middle"),
                                    color: Theme.brandAmber,
                                    lineData: metricRangePositionSeries(from: priceSeries, low: low, high: high),
                                    barData: [pos * 100, (1 - pos) * 100],
                                    thesis: "Day position turns the low-high range into a quick strength gauge."))
            }
        }
        if let volume = quote.volume {
            items.append(metric(id: "volume",
                                label: "Volume",
                                value: StockTickerWidget.compactNumber(volume),
                                detail: "latest feed volume",
                                color: Theme.brandCyan,
                                lineData: metricActivitySeries(from: priceSeries, scale: volume),
                                barData: metricActivityBars(from: priceSeries, scale: volume),
                                thesis: "Volume is shown as the latest reported feed value; chart bars use available sample movement to visualize relative activity."))
        }
        if let marketCap = quote.marketCap {
            items.append(metric(id: "market_cap",
                                label: "Market Cap",
                                value: StockTickerWidget.compactNumber(marketCap),
                                detail: "equity value",
                                color: Theme.brandCyan,
                                lineData: priceSeries.map { marketCap * ($0 / max(quote.currentPrice, 0.000001)) },
                                barData: [marketCap * 0.985, marketCap, marketCap * 1.015],
                                thesis: "Market cap is scaled by the current price path to show how valuation moves with price."))
        }
        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh {
            let pos = rangePosition(value: quote.currentPrice, low: low, high: high) ?? 0
            items.append(metric(id: "range_52w",
                                label: "52W Range",
                                value: "\(w.formatPrice(low)) - \(w.formatPrice(high))",
                                detail: String(format: "%.0f%% through year", pos * 100),
                                color: Theme.brandCyan,
                                lineData: priceSeries,
                                barData: [low, quote.currentPrice, high],
                                thesis: "The 52-week range frames current price against the broader yearly tape."))
            if let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
                items.append(metric(id: "position_52w",
                                    label: "52W Position",
                                    value: String(format: "%.0f%% of range", pos * 100),
                                    detail: pos > 0.66 ? "upper yearly band" : (pos < 0.33 ? "lower yearly band" : "middle yearly band"),
                                    color: Theme.brandCyan,
                                    lineData: metricRangePositionSeries(from: priceSeries, low: low, high: high),
                                    barData: [pos * 100, (1 - pos) * 100],
                                    thesis: "52-week position gives fast context for whether the ticker is extended or depressed versus its yearly range."))
            }
        }
        if let pe = quote.peRatio {
            items.append(metric(id: "pe",
                                label: "P/E",
                                value: String(format: "%.1f", pe),
                                detail: pe > 35 ? "premium multiple" : (pe < 15 ? "low multiple" : "mid multiple"),
                                color: Theme.brandAmber,
                                lineData: priceSeries.map { pe * ($0 / max(quote.currentPrice, 0.000001)) },
                                barData: [max(pe * 0.8, 0), pe, pe * 1.2],
                                thesis: "P/E is a valuation shorthand. The chart scales it by price movement because earnings are not refreshed intraday."))
        }
        let chartRange = quote.chartSeries.filter { $0.isFinite && $0 > 0 }
        if let low = chartRange.min(), let high = chartRange.max(), high > low {
            items.append(metric(id: "chart_low",
                                label: "Chart Low",
                                value: "$" + w.formatPrice(low),
                                detail: "visible sample low",
                                color: Theme.textSecondary,
                                lineData: chartRange,
                                barData: [low, quote.currentPrice, high],
                                thesis: "Chart low is the lowest visible price point in the loaded sample window."))
            items.append(metric(id: "chart_high",
                                label: "Chart High",
                                value: "$" + w.formatPrice(high),
                                detail: "visible sample high",
                                color: Theme.textSecondary,
                                lineData: chartRange,
                                barData: [low, quote.currentPrice, high],
                                thesis: "Chart high is the highest visible price point in the loaded sample window."))
        }
        if let ext = quote.extendedHours {
            items.append(metric(id: "extended_hours",
                                label: ext.label,
                                value: "$\(w.formatPrice(ext.price))  \(ext.change >= 0 ? "+" : "")\(String(format: "%.2f", ext.change))%",
                                detail: "extended-hours print",
                                color: w.intensityColor(for: ext.change),
                                lineData: priceSeries,
                                barData: [quote.price, ext.price],
                                thesis: "Extended-hours values can diverge from regular session quotes because liquidity is thinner."))
        }
        if let qty = w.config.holdings[quote.symbol], qty > 0 {
            let value = quote.currentPrice * qty
            let pl = quote.currentValueChange(for: qty)
            let snapshot = w.portfolioSnapshot()
            let weight = snapshot?.positions.first(where: { $0.quote.symbol == quote.symbol && $0.quote.kind == quote.kind }).map { snapshot?.weight(of: $0) ?? 0 }
            items.append(metric(id: "shares",
                                label: "Shares",
                                value: String(format: "%.4g", qty),
                                detail: "position size",
                                color: Theme.brandAmber,
                                lineData: Array(repeating: qty, count: max(priceSeries.count, 2)),
                                barData: [qty],
                                thesis: "Share count is the local holding quantity stored in Barista."))
            items.append(metric(id: "holding_value",
                                label: "Holding Value",
                                value: w.formatCurrency(value),
                                detail: "current exposure",
                                color: Theme.brandAmber,
                                lineData: priceSeries.map { $0 * qty },
                                barData: [max(value - abs(pl), 0), value],
                                thesis: "Holding value tracks the current market value of your stored position."))
            items.append(metric(id: "holding_pl",
                                label: "Holding P/L",
                                value: w.formatSignedCurrency(pl),
                                detail: "daily move on shares",
                                color: w.intensityColor(for: pl),
                                lineData: priceSeries.map { price in
                                    guard let baseline else { return 0 }
                                    return (price - baseline) * qty
                                },
                                barData: moveBars.map { $0 * qty },
                                thesis: "Holding P/L applies the quote movement to your stored share count."))
            if let weight {
                items.append(metric(id: "portfolio_weight",
                                    label: "Portfolio Wt.",
                                    value: String(format: "%.1f%%", weight),
                                    detail: "of tracked holdings",
                                    color: Theme.brandCyan,
                                    lineData: [max(weight - 1, 0), weight, min(weight + 1, 100)],
                                    barData: [weight, max(100 - weight, 0)],
                                    thesis: "Portfolio weight shows how much this ticker contributes to the local Barista portfolio snapshot."))
            }
        }
        if let alert = w.config.priceAlerts[quote.symbol] {
            items.append(metric(id: "alert",
                                label: "Alert",
                                value: "$" + w.formatPrice(alert),
                                detail: alert > quote.currentPrice ? "above current" : "below current",
                                color: Theme.brandCyan,
                                lineData: priceSeries,
                                barData: [quote.currentPrice, alert],
                                thesis: "Alert target is the threshold Barista is watching for this symbol."))
        }
        items.append(metric(id: "samples",
                            label: "Samples",
                            value: "\(max(quote.chartSeries.count, quote.sparkline.count)) pts",
                            detail: quote.kind == .stock ? "intraday feed" : "7d feed",
                            color: Theme.textSecondary,
                            lineData: priceSeries,
                            barData: moveBars,
                            thesis: "Sample count tells you how much chart data Barista currently has in memory for the symbol."))
        items.append(metric(id: "asset_type",
                            label: "Asset Type",
                            value: quote.kind == .stock ? "Equity" : "Crypto",
                            detail: quote.kind == .stock ? "Yahoo market feed" : "CoinGecko market feed",
                            color: Theme.textSecondary,
                            lineData: priceSeries,
                            barData: [Double(max(quote.chartSeries.count, 1))],
                            thesis: "Asset type controls which data source and market session rules are used."))
        items.append(metric(id: "data_freshness",
                            label: "Data",
                            value: w.freshnessDescription(),
                            detail: w.lastFetchFailed ? "last fetch failed" : "feed health",
                            color: w.freshnessColor(),
                            lineData: priceSeries,
                            barData: moveBars,
                            thesis: "Freshness shows whether the displayed quote is current, cached, or loading."))
        return items
    }

    private func metric(id: String, label: String, value: String, detail: String, color: NSColor, lineData: [Double], barData: [Double], thesis: String) -> ResearchMetric {
        let cleanLine = lineData.filter { $0.isFinite }
        let cleanBars = barData.filter { $0.isFinite }
        let fallback = quote.chartSeries.filter { $0.isFinite && $0 > 0 }
        return ResearchMetric(
            id: id,
            label: label,
            value: value,
            detail: detail,
            color: color,
            lineData: cleanLine.count >= 2 ? cleanLine : (fallback.count >= 2 ? fallback : [quote.currentPrice, quote.currentPrice]),
            barData: cleanBars.isEmpty ? metricMoveBars(from: fallback) : cleanBars,
            thesis: thesis
        )
    }

    private func metricReturnSeries(from prices: [Double], baseline: Double?) -> [Double] {
        guard let base = baseline ?? prices.first, base > 0 else { return [] }
        return prices.map { (($0 - base) / base) * 100 }
    }

    private func metricMoveBars(from prices: [Double]) -> [Double] {
        guard prices.count >= 2 else { return [0] }
        return prices.indices.dropFirst().map { prices[$0] - prices[$0 - 1] }
    }

    private func metricRangePositionSeries(from prices: [Double], low: Double, high: Double) -> [Double] {
        guard high > low else { return [] }
        return prices.map { min(max(($0 - low) / (high - low), 0), 1) * 100 }
    }

    private func metricActivitySeries(from prices: [Double], scale: Double) -> [Double] {
        let bars = metricActivityBars(from: prices, scale: scale)
        guard !bars.isEmpty else { return [scale, scale] }
        var running: [Double] = []
        var total = 0.0
        let denominator = max(Double(bars.count), 1)
        for bar in bars {
            total += max(bar, 0)
            running.append(total / denominator)
        }
        return running
    }

    private func metricActivityBars(from prices: [Double], scale: Double) -> [Double] {
        let moves = metricMoveBars(from: prices).map { abs($0) }
        guard let maxMove = moves.max(), maxMove > 0 else { return [scale] }
        return moves.map { max(scale * 0.08, scale * (0.15 + 0.85 * ($0 / maxMove))) }
    }

    private func addResearchReadout(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        guard let w = widget else { return y }
        let rows = researchReadout()
        let h: CGFloat = 44 + CGFloat(rows.count) * 30
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("RESEARCH READOUT")
        title.frame = NSRect(x: 12, y: 10, width: 150, height: 14)
        card.addSubview(title)

        let score = terminalScore()
        let scoreColor = w.intensityColor(for: score - 50)
        let scoreLabel = NSTextField(labelWithString: String(format: "%.0f/100", score))
        scoreLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        scoreLabel.textColor = scoreColor
        scoreLabel.alignment = .right
        scoreLabel.frame = NSRect(x: cw - 76, y: 10, width: 64, height: 13)
        card.addSubview(scoreLabel)

        for (i, row) in rows.enumerated() {
            let rowY = 34 + CGFloat(i) * 30
            let dot = NSView(frame: NSRect(x: 14, y: rowY + 6, width: 7, height: 7))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = row.color.withAlphaComponent(0.82).cgColor
            card.addSubview(dot)

            let label = NSTextField(labelWithString: row.label.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 28, y: rowY, width: 92, height: 9)
            card.addSubview(label)

            let value = NSTextField(labelWithString: row.value)
            value.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            value.textColor = Theme.textSecondary
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 28, y: rowY + 11, width: cw - 40, height: 13)
            card.addSubview(value)
        }

        return y + h
    }

    private func researchReadout() -> [(label: String, value: String, color: NSColor)] {
        guard let w = widget else { return [] }
        var rows: [(String, String, NSColor)] = []
        let move = quote.chartChange
        let moveColor = w.intensityColor(for: move)
        rows.append(("Tape", move >= 0 ? "Positive session momentum with current quote above baseline." : "Negative session momentum with current quote below baseline.", moveColor))

        if let low = quote.dayLow, let high = quote.dayHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            let text = pos > 0.66 ? "Trading in the upper third of the day range." : (pos < 0.33 ? "Trading in the lower third of the day range." : "Trading near the middle of the day range.")
            rows.append(("Range", text, Theme.brandAmber))
        } else if let low = quote.chartSeries.min(), let high = quote.chartSeries.max(), let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            let text = pos > 0.66 ? "Current price sits high in the visible sample window." : (pos < 0.33 ? "Current price sits low in the visible sample window." : "Current price is balanced inside the visible window.")
            rows.append(("Range", text, Theme.brandAmber))
        }

        if let volume = quote.volume {
            rows.append(("Liquidity", "Latest reported volume: \(StockTickerWidget.compactNumber(volume)).", Theme.brandCyan))
        } else {
            rows.append(("Liquidity", quote.kind == .crypto ? "Crypto feed is live; volume field may vary by venue." : "Volume not loaded for this quote yet.", Theme.brandCyan))
        }

        if let pe = quote.peRatio {
            let text = pe > 35 ? "Multiple screens expensive unless growth supports it." : (pe < 15 ? "Multiple screens low versus many large-cap equities." : "Multiple sits in a more normal middle band.")
            rows.append(("Valuation", text, Theme.brandAmber))
        } else if let cap = quote.marketCap {
            rows.append(("Valuation", "Market cap currently screens at \(StockTickerWidget.compactNumber(cap)).", Theme.brandCyan))
        }

        if let qty = w.config.holdings[quote.symbol], qty > 0 {
            let pl = quote.currentValueChange(for: qty)
            rows.append(("Portfolio", String(format: "%.4g shares, %@ today.", qty, w.formatSignedCurrency(pl)), w.intensityColor(for: pl)))
        } else if let alert = w.config.priceAlerts[quote.symbol] {
            rows.append(("Alert", "Watching for \(quote.currentPrice < alert ? "upside" : "downside") trigger at $\(w.formatPrice(alert)).", Theme.brandCyan))
        }

        return Array(rows.prefix(5))
    }

    private func terminalScore() -> Double {
        var score = 50.0
        score += max(min(quote.chartChange * 4, 22), -22)
        if let low = quote.dayLow, let high = quote.dayHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            score += (pos - 0.5) * 24
        }
        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            score += (pos - 0.5) * 12
        }
        return min(max(score, 0), 100)
    }

    private func headerChips() -> [(text: String, color: NSColor)] {
        guard let w = widget else { return [] }
        var chips: [(String, NSColor)] = []
        chips.append((quote.chartChange >= 0 ? "Momentum up" : "Momentum down", w.intensityColor(for: quote.chartChange)))
        if let low = quote.dayLow, let high = quote.dayHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            chips.append((String(format: "Day range %.0f%%", pos * 100), Theme.brandAmber))
        } else if let low = quote.chartSeries.min(), let high = quote.chartSeries.max(), high > low, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            chips.append((String(format: "Chart range %.0f%%", pos * 100), Theme.brandAmber))
        }
        if let qty = w.config.holdings[quote.symbol], qty > 0 {
            chips.append((String(format: "Holding %.4g sh", qty), Theme.brandCyan))
        } else if let marketCap = quote.marketCap {
            chips.append(("Mkt cap " + StockTickerWidget.compactNumber(marketCap), Theme.brandCyan))
        } else if let volume = quote.volume {
            chips.append(("Vol " + StockTickerWidget.compactNumber(volume), Theme.brandCyan))
        } else {
            chips.append((quote.kind == .stock ? "Equity watch" : "Crypto watch", Theme.brandCyan))
        }
        return Array(chips.prefix(3))
    }

    private func chartStats() -> [(String, String, NSColor?)] {
        guard let w = widget else { return [] }
        let series = quote.chartSeries.filter { $0.isFinite && $0 > 0 }
        let low = series.min() ?? quote.currentPrice
        let high = series.max() ?? quote.currentPrice
        let baseline = quote.chartBaseline ?? low
        let latest = quote.currentPrice
        let sample = max(series.count, quote.sparkline.count)
        return [
            ("Low", "$" + w.formatPrice(low), Theme.textSecondary),
            ("High", "$" + w.formatPrice(high), Theme.textSecondary),
            ("Base", "$" + w.formatPrice(baseline), Theme.textSecondary),
            ("Now", "$" + w.formatPrice(latest), w.intensityColor(for: quote.chartChange)),
            ("Pts", "\(sample)", Theme.textSecondary)
        ]
    }

    private func snapshotSummary() -> [(label: String, value: String, detail: String, color: NSColor)] {
        guard let w = widget else { return [] }
        let baseline = quote.chartBaseline ?? quote.baselinePrice ?? quote.price
        let move = quote.currentPrice - baseline
        let moveDetail = baseline > 0 ? "vs $" + w.formatPrice(baseline) : "vs baseline"
        let moveValue = String(format: "%@%.2f%%", quote.chartChange >= 0 ? "+" : "", quote.chartChange)

        let rangeValue: String
        let rangeDetail: String
        if let low = quote.dayLow, let high = quote.dayHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            rangeValue = String(format: "%.0f%%", pos * 100)
            rangeDetail = "$\(w.formatPrice(low)) - $\(w.formatPrice(high))"
        } else if let low = quote.chartSeries.min(), let high = quote.chartSeries.max(), let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            rangeValue = String(format: "%.0f%%", pos * 100)
            rangeDetail = "inside visible chart"
        } else {
            rangeValue = "--"
            rangeDetail = "range loading"
        }

        let exposureValue: String
        let exposureDetail: String
        let exposureColor: NSColor
        if let qty = w.config.holdings[quote.symbol], qty > 0 {
            let value = quote.currentPrice * qty
            let pl = quote.currentValueChange(for: qty)
            exposureValue = w.formatCurrency(value)
            exposureDetail = "\(w.formatSignedCurrency(pl)) today"
            exposureColor = w.intensityColor(for: pl)
        } else if let alert = w.config.priceAlerts[quote.symbol] {
            exposureValue = "$" + w.formatPrice(alert)
            exposureDetail = "price alert"
            exposureColor = Theme.brandCyan
        } else if let volume = quote.volume {
            exposureValue = StockTickerWidget.compactNumber(volume)
            exposureDetail = "volume"
            exposureColor = Theme.brandCyan
        } else {
            exposureValue = quote.kind == .stock ? "Equity" : "Crypto"
            exposureDetail = quote.kind == .stock ? "watchlist" : "24/7 market"
            exposureColor = Theme.brandCyan
        }

        return [
            ("Move", moveValue, "\(w.formatSignedCurrency(move)) \(moveDetail)", w.intensityColor(for: quote.chartChange)),
            ("Range", rangeValue, rangeDetail, Theme.brandAmber),
            ("Position", exposureValue, exposureDetail, exposureColor)
        ]
    }

    private func rangePosition(value: Double, low: Double, high: Double) -> Double? {
        guard high > low, value.isFinite, low.isFinite, high.isFinite else { return nil }
        return min(max((value - low) / (high - low), 0), 1)
    }

    private func companyIntelligenceCells() -> [(label: String, value: String, detail: String, color: NSColor)] {
        guard let w = widget else { return [] }
        let session = quote.extendedHours?.label ?? (quote.kind == .stock ? quote.marketStatus.label : "24/7")
        let dataDepth = "\(max(quote.chartSeries.count, quote.sparkline.count)) samples"
        let valuation: String
        let valuationDetail: String
        if let pe = quote.peRatio {
            valuation = String(format: "%.1fx", pe)
            valuationDetail = "P/E multiple"
        } else if let cap = quote.marketCap {
            valuation = StockTickerWidget.compactNumber(cap)
            valuationDetail = "market cap"
        } else {
            valuation = quote.kind == .stock ? "Equity" : "Crypto"
            valuationDetail = "asset class"
        }

        return [
            ("Session", session, w.freshnessDescription(), quote.extendedHours == nil ? Theme.textSecondary : Theme.brandAmber),
            ("Coverage", dataDepth, quote.kind == .stock ? "price + quote metadata" : "price + market feed", Theme.brandCyan),
            ("Valuation", valuation, valuationDetail, Theme.brandAmber),
            ("Signal", String(format: "%.0f/100", terminalScore()), "Barista score", w.intensityColor(for: terminalScore() - 50))
        ]
    }

    private func intelligenceRows() -> [(label: String, value: String, color: NSColor)] {
        guard let w = widget else { return [] }
        var rows: [(String, String, NSColor)] = []
        if quote.chartChange >= 0 {
            rows.append(("Bull Case", "Price is holding above the active baseline and momentum is confirming the move.", w.intensityColor(for: quote.chartChange)))
        } else {
            rows.append(("Bear Case", "Price is below the active baseline; wait for stabilization or improving tape.", w.intensityColor(for: quote.chartChange)))
        }

        if let pe = quote.peRatio {
            let text = pe > 35 ? "Premium multiple: future growth has to do more of the work." : (pe < 15 ? "Low multiple: valuation may be discounting weak growth or cyclicality." : "Middle-band multiple: compare growth and margins before leaning in.")
            rows.append(("Valuation", text, Theme.brandAmber))
        } else if let cap = quote.marketCap {
            rows.append(("Scale", "Market cap screens at \(StockTickerWidget.compactNumber(cap)); compare position size against liquidity.", Theme.brandCyan))
        }

        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            let text = pos > 0.75 ? "Near the upper yearly band; upside needs fresh catalysts." : (pos < 0.25 ? "Near the lower yearly band; downside may already price in stress." : "Inside the yearly range; watch for range expansion.")
            rows.append(("Setup", text, Theme.purple))
        } else if let volume = quote.volume {
            rows.append(("Liquidity", "Latest volume is \(StockTickerWidget.compactNumber(volume)); use this with spread and session status.", Theme.brandCyan))
        }

        if let qty = w.config.holdings[quote.symbol], qty > 0 {
            rows.append(("Portfolio", String(format: "Tracked holding: %.4g shares with live P/L wired into this terminal.", qty), Theme.brandCyan))
        }

        return Array(rows.prefix(4))
    }

    private func financialRows() -> [(metric: String, value: String, context: String, source: String, color: NSColor)] {
        guard let w = widget else { return [] }
        var rows: [(String, String, String, String, NSColor)] = []
        rows.append(("Price", "$" + w.formatPrice(quote.currentPrice), String(format: "%@%.2f%% session", quote.chartChange >= 0 ? "+" : "", quote.chartChange), "Yahoo chart", w.intensityColor(for: quote.chartChange)))
        if let marketCap = quote.marketCap {
            rows.append(("Market Cap", StockTickerWidget.compactNumber(marketCap), "equity value", "quote meta", Theme.brandCyan))
        }
        if let pe = quote.peRatio {
            rows.append(("P/E", String(format: "%.1fx", pe), pe > 35 ? "premium" : (pe < 15 ? "low" : "middle"), "quote meta", Theme.brandAmber))
            if let marketCap = quote.marketCap, pe > 0 {
                rows.append(("Implied Earnings", StockTickerWidget.compactNumber(marketCap / pe), "market cap / P/E", "derived", Theme.brandAmber))
                rows.append(("Earnings Yield", String(format: "%.2f%%", 100 / pe), "inverse P/E", "derived", Theme.brandAmber))
            }
        }
        if let volume = quote.volume {
            rows.append(("Volume", StockTickerWidget.compactNumber(volume), "latest reported volume", "quote feed", Theme.brandCyan))
            rows.append(("Dollar Volume", StockTickerWidget.compactNumber(volume * quote.currentPrice), "volume x price", "derived", Theme.brandCyan))
        }
        if let low = quote.dayLow, let high = quote.dayHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            rows.append(("Day KPI", String(format: "%.0f%%", pos * 100), "$\(w.formatPrice(low)) - $\(w.formatPrice(high))", "chart feed", Theme.brandAmber))
        }
        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            rows.append(("52W KPI", String(format: "%.0f%%", pos * 100), "$\(w.formatPrice(low)) - $\(w.formatPrice(high))", "quote meta", Theme.brandCyan))
        }
        rows.append(("Data Depth", "\(max(quote.chartSeries.count, quote.sparkline.count))", quote.kind == .stock ? "intraday samples" : "7d samples", "Barista cache", Theme.textSecondary))
        return Array(rows.prefix(9))
    }

    private func scenarioTargets() -> [(name: String, target: Double, driver: String, color: NSColor)] {
        let current = max(quote.currentPrice, 0.000001)
        let low = quote.fiftyTwoWeekLow ?? quote.dayLow ?? quote.chartSeries.min() ?? current * 0.9
        let high = quote.fiftyTwoWeekHigh ?? quote.dayHigh ?? quote.chartSeries.max() ?? current * 1.1
        let mid = (low + high) / 2
        let momentum = min(max(quote.chartChange / 100, -0.08), 0.08)
        let base = max(0.000001, mid * (1 + momentum))
        let bear = min(current * 0.92, max(low, current * (1 - max(abs(momentum), 0.05))))
        let bull = max(current * 1.08, min(high, current * (1 + max(abs(momentum), 0.06))))
        return [
            ("Bear", bear, "range support", Theme.red),
            ("Base", base, "range midpoint", Theme.brandAmber),
            ("Bull", bull, "range breakout", Theme.green)
        ]
    }

    private func ownershipRows() -> [(label: String, value: String, color: NSColor)] {
        guard let w = widget else { return [] }
        if let qty = w.config.holdings[quote.symbol], qty > 0 {
            let value = qty * quote.currentPrice
            let pl = quote.currentValueChange(for: qty)
            let weight = w.portfolioSnapshot()?.positions.first(where: { $0.quote.symbol == quote.symbol && $0.quote.kind == quote.kind }).map { w.portfolioSnapshot()?.weight(of: $0) ?? 0 } ?? 0
            return [
                ("Shares", String(format: "%.4g", qty), Theme.brandCyan),
                ("Value", w.formatCurrency(value), Theme.brandAmber),
                ("Today", w.formatSignedCurrency(pl), w.intensityColor(for: pl)),
                ("Weight", String(format: "%.1f%%", weight), Theme.brandCyan)
            ]
        }
        let cap = quote.marketCap.map(StockTickerWidget.compactNumber) ?? "Not loaded"
        return [
            ("Local Position", "No Barista holding", Theme.textSecondary),
            ("Market Cap", cap, Theme.brandCyan),
            ("Ownership", "Open holders source", Theme.textSecondary),
            ("Alerts", widget?.config.priceAlerts[quote.symbol].map { "$" + w.formatPrice($0) } ?? "None set", Theme.brandAmber)
        ]
    }

    private func flowRows() -> [(label: String, value: String, color: NSColor)] {
        guard let w = widget else { return [] }
        let volume = quote.volume.map(StockTickerWidget.compactNumber) ?? "N/A"
        let dollarVolume = quote.volume.map { StockTickerWidget.compactNumber($0 * quote.currentPrice) } ?? "N/A"
        let session = quote.extendedHours?.label ?? (quote.kind == .stock ? quote.marketStatus.label : "24/7")
        return [
            ("Session", session, quote.extendedHours == nil ? Theme.textSecondary : Theme.brandAmber),
            ("Volume", volume, Theme.brandCyan),
            ("Dollar Vol", dollarVolume, Theme.brandCyan),
            ("Momentum", String(format: "%@%.2f%%", quote.chartChange >= 0 ? "+" : "", quote.chartChange), w.intensityColor(for: quote.chartChange))
        ]
    }

    private func filingRows() -> [(label: String, value: String, color: NSColor)] {
        if quote.kind == .crypto {
            return [
                ("Profile", "CoinGecko market page is linked from actions.", Theme.brandCyan),
                ("Events", "Crypto assets trade continuously; no earnings calendar.", Theme.textSecondary),
                ("Source", "Price and market data from the configured crypto feed.", Theme.brandAmber)
            ]
        }
        return [
            ("Financials", "Open income statement, balance sheet and cash flow source pages.", Theme.brandCyan),
            ("Events", "Open earnings and corporate event calendar.", Theme.brandAmber),
            ("Filings", "SEC search link keeps the official filing trail one click away.", Theme.textSecondary)
        ]
    }

    private func dataAuditRows() -> [(label: String, value: String, color: NSColor)] {
        let quoteSource = quote.kind == .stock ? "Yahoo chart endpoint with extended-hours fields where available." : "CoinGecko market endpoint with 7-day sample series."
        return [
            ("Quote", quoteSource, Theme.brandCyan),
            ("Charts", "Rendered from Barista's in-memory sample set; hover shows sample-level values.", Theme.green),
            ("Metrics", "Terminal metrics are live quote fields plus clearly marked derived ratios.", Theme.brandAmber),
            ("News", quote.kind == .stock ? "Yahoo Finance RSS headlines load inside the popup." : "External crypto research opens in browser.", Theme.purple)
        ]
    }

    private func terminalHealthBars() -> [Double] {
        let momentum = min(max((quote.chartChange + 8) / 16, 0.05), 1)
        let rangeScore: Double
        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            rangeScore = pos
        } else if let low = quote.dayLow, let high = quote.dayHigh, let pos = rangePosition(value: quote.currentPrice, low: low, high: high) {
            rangeScore = pos
        } else {
            rangeScore = 0.5
        }
        let dataScore = min(Double(max(quote.chartSeries.count, quote.sparkline.count)) / 48, 1)
        let valuationScore: Double
        if let pe = quote.peRatio {
            valuationScore = pe <= 0 ? 0.4 : min(max((45 - pe) / 45, 0.1), 1)
        } else {
            valuationScore = quote.marketCap == nil ? 0.45 : 0.68
        }
        return [momentum, rangeScore, dataScore, valuationScore]
    }

    private func addMiniStatCard(to parent: NSView, frame: NSRect, label: String, value: String, detail: String, color: NSColor) {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = color.withAlphaComponent(0.055).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = color.withAlphaComponent(0.14).cgColor
        parent.addSubview(card)

        let labelView = NSTextField(labelWithString: label.uppercased())
        labelView.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        labelView.textColor = Theme.textGhost
        labelView.frame = NSRect(x: 8, y: 6, width: frame.width - 16, height: 9)
        card.addSubview(labelView)

        let valueView = NSTextField(labelWithString: value)
        valueView.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
        valueView.textColor = color
        valueView.lineBreakMode = .byTruncatingTail
        valueView.frame = NSRect(x: 8, y: 18, width: frame.width - 16, height: 15)
        card.addSubview(valueView)

        let detailView = NSTextField(labelWithString: detail)
        detailView.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        detailView.textColor = Theme.textFaint
        detailView.lineBreakMode = .byTruncatingTail
        detailView.frame = NSRect(x: 8, y: 34, width: frame.width - 16, height: 9)
        card.addSubview(detailView)
    }

    private func addTableHeader(to card: NSView, y: CGFloat, cw: CGFloat, columns: [String]) {
        let widths: [CGFloat] = [118, 116, cw - 392, 110]
        var x: CGFloat = 12
        for (i, column) in columns.enumerated() {
            let label = NSTextField(labelWithString: column.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: x, y: y, width: widths[i], height: 9)
            card.addSubview(label)
            x += widths[i] + 8
        }
    }

    private func addFinancialRow(to card: NSView, y: CGFloat, cw: CGFloat, row: (metric: String, value: String, context: String, source: String, color: NSColor)) {
        let bg = NSView(frame: NSRect(x: 10, y: y - 4, width: cw - 20, height: 24))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        card.addSubview(bg)

        let metric = NSTextField(labelWithString: row.metric)
        metric.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        metric.textColor = Theme.textSecondary
        metric.lineBreakMode = .byTruncatingTail
        metric.frame = NSRect(x: 18, y: y + 2, width: 112, height: 12)
        card.addSubview(metric)

        let value = NSTextField(labelWithString: row.value)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        value.textColor = row.color
        value.lineBreakMode = .byTruncatingTail
        value.frame = NSRect(x: 138, y: y + 2, width: 108, height: 12)
        card.addSubview(value)

        let context = NSTextField(labelWithString: row.context)
        context.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        context.textColor = Theme.textFaint
        context.lineBreakMode = .byTruncatingTail
        context.frame = NSRect(x: 254, y: y + 2, width: cw - 392, height: 12)
        card.addSubview(context)

        let source = NSTextField(labelWithString: row.source)
        source.font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        source.textColor = Theme.textGhost
        source.alignment = .right
        source.lineBreakMode = .byTruncatingTail
        source.frame = NSRect(x: cw - 124, y: y + 2, width: 110, height: 12)
        card.addSubview(source)
    }

    private func addSimpleKV(to parent: NSView, y: CGFloat, x: CGFloat, width: CGFloat, label: String, value: String, color: NSColor) {
        let labelView = NSTextField(labelWithString: label.uppercased())
        labelView.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        labelView.textColor = Theme.textGhost
        labelView.frame = NSRect(x: x, y: y, width: 86, height: 9)
        parent.addSubview(labelView)

        let valueView = NSTextField(labelWithString: value)
        valueView.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        valueView.textColor = color
        valueView.alignment = .right
        valueView.lineBreakMode = .byTruncatingTail
        valueView.frame = NSRect(x: x + 92, y: y - 1, width: width - 92, height: 13)
        parent.addSubview(valueView)
    }

    private func addTerminalButton(to parent: NSView, title: String, id: String, frame: NSRect, color: NSColor) {
        let button = NSButton(frame: frame)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = color.withAlphaComponent(0.18).cgColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: color
        ])
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.target = self
        button.action = #selector(openTerminalLink(_:))
        parent.addSubview(button)
    }

    private func fetchFundamentals() {
        guard quote.kind == .stock else {
            renderFundamentalsUnavailable("SEC fundamentals are available for public-company filings, not crypto assets.")
            return
        }
        StockFundamentalsService.shared.fetch(symbol: quote.symbol) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fundamentals):
                self.renderFundamentals(fundamentals)
            case .failure:
                self.renderFundamentalsUnavailable("Could not load SEC Company Facts for \(self.quote.symbol). Links below still open official sources.")
            }
        }
    }

    private func renderFundamentalsLoading() {
        guard let container = secFundamentalsContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: quote.kind == .stock ? "Loading filed fundamentals from SEC Company Facts..." : "No SEC company fundamentals for crypto assets.")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.textFaint
        label.alignment = .center
        label.frame = container.bounds
        container.addSubview(label)
    }

    private func renderFundamentalsUnavailable(_ message: String) {
        guard let container = secFundamentalsContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.textFaint
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.frame = NSRect(x: 24, y: container.bounds.midY - 30, width: container.bounds.width - 48, height: 60)
        container.addSubview(label)
    }

    private func renderFundamentals(_ fundamentals: StockFundamentals) {
        guard let container = secFundamentalsContainer, let w = widget else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        fundamentalLookup = fundamentals.annualMetrics

        let cw = container.frame.width
        let header = NSTextField(labelWithString: "\(fundamentals.companyName)  |  CIK \(fundamentals.cik)  |  FY \(fundamentals.latestFiscalYear.map(String.init) ?? "N/A")  |  Latest Q \(fundamentals.latestQuarterLabel ?? "N/A")")
        header.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        header.textColor = Theme.textSecondary
        header.lineBreakMode = .byTruncatingTail
        header.frame = NSRect(x: 4, y: 0, width: cw - 8, height: 14)
        container.addSubview(header)

        let chartW = (cw - 20) / 3
        addFundamentalChartCard(to: container,
                                title: "Income Statement",
                                frame: NSRect(x: 0, y: 24, width: chartW, height: 136),
                                metrics: compactMetrics(fundamentals, ["revenue", "gross_profit", "operating_income", "net_income"]),
                                mode: .bars)
        addFundamentalChartCard(to: container,
                                title: "Cash Flow",
                                frame: NSRect(x: chartW + 10, y: 24, width: chartW, height: 136),
                                metrics: compactMetrics(fundamentals, ["operating_cash_flow", "capex", "free_cash_flow"]),
                                mode: .lines)
        addFundamentalChartCard(to: container,
                                title: "Balance Sheet",
                                frame: NSRect(x: (chartW + 10) * 2, y: 24, width: chartW, height: 136),
                                metrics: compactMetrics(fundamentals, ["assets", "liabilities", "equity", "cash", "debt"]),
                                mode: .stacked)

        addFundamentalChartCard(to: container,
                                title: "Quarterly Revenue / Net Income",
                                frame: NSRect(x: 0, y: 174, width: chartW, height: 126),
                                metrics: compactQuarterlyMetrics(fundamentals, ["revenue", "net_income"]),
                                mode: .lines)
        addFundamentalChartCard(to: container,
                                title: "Quarterly FCF / Cash Flow",
                                frame: NSRect(x: chartW + 10, y: 174, width: chartW, height: 126),
                                metrics: compactQuarterlyMetrics(fundamentals, ["operating_cash_flow", "free_cash_flow"]),
                                mode: .lines)
        addFundamentalChartCard(to: container,
                                title: "Quarterly Balance Sheet",
                                frame: NSRect(x: (chartW + 10) * 2, y: 174, width: chartW, height: 126),
                                metrics: compactQuarterlyMetrics(fundamentals, ["cash", "debt", "equity"]),
                                mode: .stacked)

        let ratioTitle = NSTextField(labelWithString: "FILED RATIOS")
        ratioTitle.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        ratioTitle.textColor = Theme.textGhost
        ratioTitle.frame = NSRect(x: 0, y: 318, width: 120, height: 10)
        container.addSubview(ratioTitle)

        let ratios = Array(fundamentals.ratios.prefix(12))
        let ratioGap: CGFloat = 8
        let ratioCols = 4
        let ratioW = (cw - ratioGap * CGFloat(ratioCols - 1)) / CGFloat(ratioCols)
        for (i, ratio) in ratios.enumerated() {
            let col = i % ratioCols
            let row = i / ratioCols
            let x = CGFloat(col) * (ratioW + ratioGap)
            let y = 338 + CGFloat(row) * 52
            let color = colorForFundamentalRatio(ratio)
            addMiniStatCard(to: container,
                            frame: NSRect(x: x, y: y, width: ratioW, height: 44),
                            label: ratio.label,
                            value: ratio.display,
                            detail: ratio.detail,
                            color: color)
        }

        let valuationTitle = NSTextField(labelWithString: "VALUATION BRIDGE")
        valuationTitle.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        valuationTitle.textColor = Theme.textGhost
        valuationTitle.frame = NSRect(x: 0, y: 506, width: 150, height: 10)
        container.addSubview(valuationTitle)

        let valuationRows = Array(valuationBridgeRows(fundamentals, widget: w).prefix(4))
        for (i, row) in valuationRows.enumerated() {
            let x = CGFloat(i) * (ratioW + ratioGap)
            addMiniStatCard(to: container,
                            frame: NSRect(x: x, y: 526, width: ratioW, height: 46),
                            label: row.label,
                            value: row.value,
                            detail: row.detail,
                            color: row.color)
        }

        let pulseTitle = NSTextField(labelWithString: "LATEST QUARTER PULSE")
        pulseTitle.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        pulseTitle.textColor = Theme.textGhost
        pulseTitle.frame = NSRect(x: 0, y: 590, width: 170, height: 10)
        container.addSubview(pulseTitle)

        let pulseRows = Array(quarterlyPulseRows(fundamentals, widget: w).prefix(4))
        for (i, row) in pulseRows.enumerated() {
            let x = CGFloat(i) * (ratioW + ratioGap)
            addMiniStatCard(to: container,
                            frame: NSRect(x: x, y: 610, width: ratioW, height: 46),
                            label: row.label,
                            value: row.value,
                            detail: row.detail,
                            color: row.color)
        }

        let metricsTitle = NSTextField(labelWithString: "STATEMENT METRICS")
        metricsTitle.font = NSFont.systemFont(ofSize: 8, weight: .bold)
        metricsTitle.textColor = Theme.textGhost
        metricsTitle.frame = NSRect(x: 0, y: 666, width: 160, height: 10)
        container.addSubview(metricsTitle)

        let source = NSTextField(labelWithString: "Click any filed metric for annual line + bar graphs")
        source.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        source.textColor = Theme.textGhost
        source.alignment = .right
        source.frame = NSRect(x: cw - 318, y: 665, width: 318, height: 11)
        container.addSubview(source)

        let metricIDs = ["revenue", "cost_of_revenue", "gross_profit", "r_and_d", "sga", "operating_income", "net_income", "operating_cash_flow", "free_cash_flow", "capex", "assets", "current_assets", "liabilities", "current_liabilities", "equity", "cash", "debt", "eps_diluted", "shares_diluted", "dividends_paid"]
        let metricCols = 2
        let metricGap: CGFloat = 8
        let metricW = (cw - metricGap) / CGFloat(metricCols)
        for (visibleIndex, metric) in metricIDs.compactMap({ fundamentals.metric($0) }).prefix(18).enumerated() {
            let col = visibleIndex % metricCols
            let row = visibleIndex / metricCols
            let x = CGFloat(col) * (metricW + metricGap)
            let y = 686 + CGFloat(row) * 32
            addFundamentalMetricRow(to: container, metric: metric, frame: NSRect(x: x, y: y, width: metricW, height: 28), widget: w)
        }
    }

    private func compactMetrics(_ fundamentals: StockFundamentals, _ ids: [String]) -> [FundamentalMetricSeries] {
        ids.compactMap { fundamentals.metric($0) }
    }

    private func compactQuarterlyMetrics(_ fundamentals: StockFundamentals, _ ids: [String]) -> [FundamentalMetricSeries] {
        ids.compactMap { fundamentals.quarterlyMetric($0) }
    }

    private func valuationBridgeRows(_ fundamentals: StockFundamentals, widget: StockTickerWidget) -> [(label: String, value: String, detail: String, color: NSColor)] {
        func latest(_ id: String) -> Double? { fundamentals.metric(id)?.latest?.value }
        var rows: [(String, String, String, NSColor)] = []
        guard let marketCap = quote.marketCap, marketCap > 0 else {
            return [("Market Cap", "Not loaded", "quote metadata pending", Theme.textSecondary)]
        }
        if let revenue = latest("revenue"), revenue != 0 {
            rows.append(("P/S", formatMultiple(marketCap / revenue), "market cap / sales", Theme.brandAmber))
            let debt = latest("debt") ?? 0
            let cash = latest("cash") ?? 0
            let enterpriseValue = marketCap + debt - cash
            rows.append(("EV/Sales", formatMultiple(enterpriseValue / revenue), "cap + debt - cash / sales", Theme.brandAmber))
        }
        if let fcf = latest("free_cash_flow"), fcf != 0 {
            rows.append(("P/FCF", fcf > 0 ? formatMultiple(marketCap / fcf) : "N/M", "market cap / FCF", fcf > 0 ? Theme.brandAmber : Theme.red))
            rows.append(("FCF Yield", formatPercent(fcf / marketCap), "free cash flow / cap", fcf >= 0 ? Theme.green : Theme.red))
        }
        if let equity = latest("equity"), equity != 0 {
            rows.append(("P/B", formatMultiple(marketCap / equity), "market cap / book", Theme.brandCyan))
        }
        if let cash = latest("cash"), let debt = latest("debt") {
            let netCash = cash - debt
            rows.append((netCash >= 0 ? "Net Cash" : "Net Debt",
                         StockTickerWidget.compactNumber(abs(netCash)),
                         netCash >= 0 ? "cash minus debt" : "debt minus cash",
                         netCash >= 0 ? Theme.green : Theme.brandAmber))
        }
        if let shares = latest("shares_diluted"), shares > 0, let revenue = latest("revenue") {
            rows.append(("Sales/Share", "$" + widget.formatPrice(revenue / shares), "revenue / diluted shares", Theme.brandCyan))
        }
        if let shares = latest("shares_diluted"), shares > 0, let fcf = latest("free_cash_flow") {
            rows.append(("FCF/Share", "$" + widget.formatPrice(fcf / shares), "FCF / diluted shares", fcf >= 0 ? Theme.green : Theme.red))
        }
        return rows
    }

    private func quarterlyPulseRows(_ fundamentals: StockFundamentals, widget: StockTickerWidget) -> [(label: String, value: String, detail: String, color: NSColor)] {
        let ids = ["revenue", "net_income", "free_cash_flow", "cash", "debt", "operating_cash_flow"]
        return ids.compactMap { id in
            guard let metric = fundamentals.quarterlyMetric(id), let latest = metric.latest else { return nil }
            let detail = periodChangeDetail(metric)
            let baseColor = colorForFundamentalStatement(metric.statement)
            let color = (id == "net_income" || id == "free_cash_flow" || id == "operating_cash_flow") && latest.value < 0 ? Theme.red : baseColor
            return (metric.label, formatFundamentalValue(latest.value, unit: metric.unit, widget: widget), detail, color)
        }
    }

    private func periodChangeDetail(_ metric: FundamentalMetricSeries) -> String {
        let points = metric.points
        guard let latest = points.last else { return "quarterly filing" }
        if points.count >= 2, let previous = points.dropLast().last, previous.value != 0 {
            return "\(latest.label)  QoQ \(formatSignedPercent((latest.value - previous.value) / abs(previous.value)))"
        }
        return latest.label
    }

    private func formatMultiple(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        if abs(value) >= 100 { return String(format: "%.0fx", value) }
        return String(format: "%.2fx", value)
    }

    private func formatPercent(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return String(format: "%.1f%%", value * 100)
    }

    private func formatSignedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return String(format: "%@%.1f%%", value >= 0 ? "+" : "", value * 100)
    }

    private func addFundamentalChartCard(to parent: NSView, title: String, frame: NSRect, metrics: [FundamentalMetricSeries], mode: FundamentalChartView.Mode) {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor
        parent.addSubview(card)

        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        label.textColor = Theme.textGhost
        label.frame = NSRect(x: 9, y: 8, width: frame.width - 18, height: 9)
        card.addSubview(label)

        let chart = FundamentalChartView(frame: NSRect(x: 8, y: 24, width: frame.width - 16, height: 82),
                                         metrics: metrics,
                                         mode: mode)
        card.addSubview(chart)

        let legend = NSTextField(labelWithString: metrics.prefix(3).map(\.label).joined(separator: " / "))
        legend.font = NSFont.systemFont(ofSize: 7.5, weight: .medium)
        legend.textColor = Theme.textFaint
        legend.lineBreakMode = .byTruncatingTail
        legend.frame = NSRect(x: 9, y: 114, width: frame.width - 18, height: 10)
        card.addSubview(legend)
    }

    private func addFundamentalMetricRow(to parent: NSView, metric: FundamentalMetricSeries, frame: NSRect, widget: StockTickerWidget) {
        let row = NSView(frame: frame)
        row.wantsLayer = true
        row.layer?.cornerRadius = 7
        row.layer?.backgroundColor = colorForFundamentalStatement(metric.statement).withAlphaComponent(0.055).cgColor
        row.layer?.borderWidth = 0.5
        row.layer?.borderColor = colorForFundamentalStatement(metric.statement).withAlphaComponent(0.14).cgColor
        parent.addSubview(row)

        let label = NSTextField(labelWithString: metric.label)
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = Theme.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 8, y: 5, width: frame.width * 0.42, height: 12)
        row.addSubview(label)

        let value = NSTextField(labelWithString: formatFundamentalValue(metric.latest?.value, unit: metric.unit, widget: widget))
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        value.textColor = colorForFundamentalStatement(metric.statement)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        value.frame = NSRect(x: frame.width * 0.43, y: 5, width: frame.width * 0.27, height: 12)
        row.addSubview(value)

        let trend = FundamentalTinyChartView(frame: NSRect(x: frame.width - 62, y: 5, width: 46, height: 16),
                                             metric: metric,
                                             color: colorForFundamentalStatement(metric.statement))
        row.addSubview(trend)

        let button = NSButton(frame: row.bounds)
        button.isBordered = false
        button.isTransparent = true
        button.identifier = NSUserInterfaceItemIdentifier("fund:\(metric.id)")
        button.target = self
        button.action = #selector(showFundamentalDetail(_:))
        row.addSubview(button)
    }

    private func colorForFundamentalStatement(_ statement: String) -> NSColor {
        switch statement {
        case "Income": return Theme.green
        case "Cash Flow": return Theme.brandCyan
        case "Balance Sheet": return Theme.brandAmber
        case "Per Share": return Theme.purple
        default: return Theme.textSecondary
        }
    }

    private func colorForFundamentalRatio(_ ratio: FundamentalRatio) -> NSColor {
        if ratio.id.contains("debt") { return ratio.value > 1 ? Theme.brandAmber : Theme.brandCyan }
        if ratio.id.contains("margin") || ratio.id == "roe" || ratio.id == "roa" || ratio.id.contains("cagr") {
            return ratio.value >= 0 ? Theme.green : Theme.red
        }
        return Theme.brandCyan
    }

    private func formatFundamentalValue(_ value: Double?, unit: String, widget: StockTickerWidget) -> String {
        guard let value else { return "--" }
        if unit == "USD/shares" { return "$" + widget.formatPrice(value) }
        if unit == "shares" { return StockTickerWidget.compactNumber(value) }
        if abs(value) >= 1_000 { return (value < 0 ? "-" : "") + StockTickerWidget.compactNumber(abs(value)) }
        return String(format: "%.2f", value)
    }

    private func addNews(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let h: CGFloat = 188
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("HEADLINES")
        title.frame = NSRect(x: 12, y: 10, width: 110, height: 14)
        card.addSubview(title)

        let container = NSView(frame: NSRect(x: 10, y: 30, width: cw - 20, height: h - 40))
        card.addSubview(container)
        newsContainer = container
        renderNewsLoading()
        return y + h
    }

    private func addDataAudit(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let h: CGFloat = 126
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 10)
        doc.addSubview(card)

        let title = sectionLabel("DATA AUDIT")
        title.frame = NSRect(x: 12, y: 12, width: 120, height: 14)
        card.addSubview(title)

        let rows = dataAuditRows()
        for (i, row) in rows.enumerated() {
            let rowY = 36 + CGFloat(i) * 20
            let dot = NSView(frame: NSRect(x: 14, y: rowY + 5, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = row.color.withAlphaComponent(0.86).cgColor
            card.addSubview(dot)

            let label = NSTextField(labelWithString: row.label.uppercased())
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = Theme.textGhost
            label.frame = NSRect(x: 28, y: rowY, width: 92, height: 9)
            card.addSubview(label)

            let value = NSTextField(labelWithString: row.value)
            value.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            value.textColor = Theme.textSecondary
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: 120, y: rowY - 1, width: cw - 134, height: 12)
            card.addSubview(value)
        }

        return y + h
    }

    private func addActions(to doc: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat) -> CGFloat {
        let h: CGFloat = 34
        let card = makeCard(x: pad, y: y, w: cw, h: h, radius: 9)
        doc.addSubview(card)

        let open = NSButton(frame: NSRect(x: 10, y: 6, width: 118, height: 22))
        open.isBordered = false
        open.wantsLayer = true
        open.layer?.cornerRadius = 6
        open.layer?.backgroundColor = Theme.brandCyan.withAlphaComponent(0.08).cgColor
        open.attributedTitle = NSAttributedString(string: "Open Yahoo", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Theme.brandCyan
        ])
        open.target = self
        open.action = #selector(openYahoo)
        card.addSubview(open)

        let refresh = NSButton(frame: NSRect(x: cw - 102, y: 6, width: 92, height: 22))
        refresh.isBordered = false
        refresh.wantsLayer = true
        refresh.layer?.cornerRadius = 6
        refresh.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.08).cgColor
        refresh.attributedTitle = NSAttributedString(string: "Refresh", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Theme.brandAmber
        ])
        refresh.target = self
        refresh.action = #selector(refreshQuote)
        card.addSubview(refresh)

        return y + h
    }

    private func renderNewsLoading() {
        guard let newsContainer else { return }
        newsContainer.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: quote.kind == .stock ? "Loading headlines..." : "Crypto headlines open on Yahoo Finance.")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = Theme.textFaint
        label.alignment = .center
        label.frame = newsContainer.bounds
        newsContainer.addSubview(label)
    }

    private func renderNews(_ items: [(title: String, link: String)]) {
        guard let newsContainer else { return }
        newsItems = items
        newsContainer.subviews.forEach { $0.removeFromSuperview() }

        if items.isEmpty {
            let label = NSTextField(labelWithString: "No fresh headlines loaded.")
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = Theme.textFaint
            label.alignment = .center
            label.frame = newsContainer.bounds
            newsContainer.addSubview(label)
            return
        }

        for (i, item) in items.prefix(5).enumerated() {
            let y = CGFloat(i) * 29
            let row = NSButton(frame: NSRect(x: 0, y: y, width: newsContainer.frame.width, height: 27))
            row.isBordered = false
            row.alignment = .left
            row.lineBreakMode = .byTruncatingTail
            row.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: Theme.textSecondary
            ])
            row.identifier = NSUserInterfaceItemIdentifier("news:\(i)")
            row.target = self
            row.action = #selector(openNews(_:))
            newsContainer.addSubview(row)
        }
    }

    private func fetchNews() {
        guard quote.kind == .stock else {
            renderNews([])
            return
        }
        let safe = quote.symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? quote.symbol
        guard let url = URL(string: "https://feeds.finance.yahoo.com/rss/2.0/headline?s=\(safe)&region=US&lang=en-US") else {
            renderNews([])
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            let items = data.flatMap { self.parseNews(data: $0) } ?? []
            DispatchQueue.main.async { self.renderNews(items) }
        }.resume()
    }

    private func parseNews(data: Data) -> [(title: String, link: String)] {
        parsedNews = []
        currentElement = ""
        currentTitle = ""
        currentLink = ""
        parsingItem = false
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Array(parsedNews.prefix(5))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            parsingItem = true
            currentTitle = ""
            currentLink = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard parsingItem else { return }
        if currentElement == "title" { currentTitle += string }
        if currentElement == "link" { currentLink += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let link = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { parsedNews.append((title, link)) }
            parsingItem = false
        }
        currentElement = ""
    }

    @objc private func showMetricDetail(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let metric = metricLookup[id],
              let w = widget else { return }
        metricPopover?.close()
        let vc = MetricDrilldownPopoverController(widget: w, quote: quote, metric: metric)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 410)
        popover.contentViewController = vc
        metricPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func showFundamentalDetail(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("fund:"),
              let w = widget else { return }
        let id = String(raw.dropFirst("fund:".count))
        guard let metric = fundamentalLookup[id] else { return }
        fundamentalPopover?.close()
        let vc = FundamentalMetricPopoverController(widget: w, quote: quote, metric: metric)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 430)
        popover.contentViewController = vc
        fundamentalPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func openYahoo() {
        widget?.openInBrowser(symbol: quote.symbol, kind: quote.kind)
    }

    @objc private func refreshQuote() {
        refreshLiveData(forceChart: true)
    }

    private func refreshLiveData(forceChart: Bool) {
        widget?.refreshNow()
        fetchPriceHistory(range: chartRange, force: forceChart)
    }

    @objc private func openNews(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let idx = Int(id.dropFirst("news:".count)),
              idx < newsItems.count,
              let url = URL(string: newsItems[idx].link) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTerminalLink(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let url = terminalURL(for: id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func terminalURL(for id: String) -> URL? {
        if quote.kind == .crypto {
            let coinId = symbolToCoinID[quote.symbol] ?? quote.symbol.lowercased()
            if id == "fiscal" { return URL(string: "https://fiscal.ai/") }
            return URL(string: "https://www.coingecko.com/en/coins/\(coinId)")
        }

        let safePath = quote.symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? quote.symbol
        let safeQuery = quote.symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? quote.symbol
        switch id {
        case "profile":
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)/profile")
        case "financials":
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)/financials")
        case "analysis":
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)/analysis")
        case "holders":
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)/holders")
        case "calendar":
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)/calendar")
        case "news":
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)/news")
        case "sec":
            return URL(string: "https://www.sec.gov/edgar/search/#/q=\(safeQuery)&dateRange=all")
        case "fiscal":
            return URL(string: "https://fiscal.ai/")
        default:
            return URL(string: "https://finance.yahoo.com/quote/\(safePath)")
        }
    }

    @objc private func chartRangeClicked(_ sender: NSButton) {
        let ranges = StockChartRange.allCases
        guard sender.tag >= 0, sender.tag < ranges.count else { return }
        chartRange = ranges[sender.tag]
        chartRangeButtons.forEach { range, button in
            styleChartRangeButton(button, range: range)
        }
        fetchPriceHistory(range: chartRange, force: true)
    }

    private func fetchPriceHistory(range: StockChartRange, force: Bool = false) {
        guard quote.kind == .stock else { return }
        StockPriceHistoryService.shared.fetch(symbol: quote.symbol, range: range, force: force) { [weak self] result in
            guard let self else { return }
            guard self.chartRange == range else { return }
            switch result {
            case .success(let history):
                self.terminalChartView?.update(history: history)
            case .failure:
                self.terminalChartView?.update(history: nil)
            }
        }
    }

    private func makeCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat) -> NSView {
        let card = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        card.wantsLayer = true
        card.layer?.cornerRadius = radius
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor
        return card
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        label.textColor = Theme.textFaint
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.kern, value: 1.4, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 9, weight: .bold), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: Theme.textFaint, range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
        return label
    }

    private func smallMono(_ text: String, color: NSColor, align: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        label.textColor = color
        label.alignment = align
        return label
    }
}

private class FundamentalMetricPopoverController: NSViewController {
    private weak var widget: StockTickerWidget?
    private let quote: MarketQuote
    private let metric: FundamentalMetricSeries
    private let popoverW: CGFloat = 430
    private let popoverH: CGFloat = 430

    init(widget: StockTickerWidget, quote: MarketQuote, metric: FundamentalMetricSeries) {
        self.widget = widget
        self.quote = quote
        self.metric = metric
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = buildView()
    }

    private func buildView() -> NSView {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: popoverW, height: popoverH))
        root.wantsLayer = true
        let pad: CGFloat = 16
        let cw = popoverW - pad * 2

        let header = NSView(frame: NSRect(x: pad, y: 14, width: cw, height: 76))
        header.wantsLayer = true
        header.layer?.cornerRadius = 10
        header.layer?.backgroundColor = color.withAlphaComponent(0.07).cgColor
        header.layer?.borderWidth = 0.5
        header.layer?.borderColor = color.withAlphaComponent(0.18).cgColor
        root.addSubview(header)

        let symbol = NSTextField(labelWithString: quote.symbol)
        symbol.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        symbol.textColor = Theme.textFaint
        symbol.frame = NSRect(x: 12, y: 12, width: 90, height: 15)
        header.addSubview(symbol)

        let label = NSTextField(labelWithString: metric.label)
        label.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 31, width: 210, height: 22)
        header.addSubview(label)

        let value = NSTextField(labelWithString: formatted(metric.latest?.value))
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        value.textColor = color
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        value.frame = NSRect(x: cw - 162, y: 20, width: 150, height: 22)
        header.addSubview(value)

        let source = NSTextField(labelWithString: "\(metric.sourceConcept)  |  \(metric.latest?.form ?? "") \(metric.latest?.filedDate ?? "")")
        source.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        source.textColor = Theme.textFaint
        source.alignment = .right
        source.lineBreakMode = .byTruncatingTail
        source.frame = NSRect(x: cw - 250, y: 46, width: 238, height: 11)
        header.addSubview(source)

        addChartCard(to: root, y: 102, pad: pad, cw: cw, title: "ANNUAL LINE", mode: .lines)
        addChartCard(to: root, y: 236, pad: pad, cw: cw, title: "ANNUAL BARS", mode: .bars)

        let audit = NSView(frame: NSRect(x: pad, y: 370, width: cw, height: 46))
        audit.wantsLayer = true
        audit.layer?.cornerRadius = 9
        audit.layer?.backgroundColor = Theme.cardBg.cgColor
        audit.layer?.borderWidth = 0.5
        audit.layer?.borderColor = Theme.cardBorder.cgColor
        root.addSubview(audit)

        let text = NSTextField(labelWithString: "Filed annual XBRL facts from SEC Company Facts. Values are grouped by fiscal year and latest filing date.")
        text.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        text.textColor = Theme.textMuted
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 3
        text.frame = NSRect(x: 10, y: 8, width: cw - 20, height: 32)
        audit.addSubview(text)

        return root
    }

    private func addChartCard(to root: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat, title: String, mode: FundamentalChartView.Mode) {
        let card = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 122))
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor
        root.addSubview(card)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        titleLabel.textColor = Theme.textFaint
        titleLabel.frame = NSRect(x: 10, y: 8, width: 120, height: 11)
        card.addSubview(titleLabel)

        let chart = FundamentalChartView(frame: NSRect(x: 10, y: 26, width: cw - 20, height: 86),
                                         metrics: [metric],
                                         mode: mode)
        card.addSubview(chart)
    }

    private var color: NSColor {
        switch metric.statement {
        case "Income": return Theme.green
        case "Cash Flow": return Theme.brandCyan
        case "Balance Sheet": return Theme.brandAmber
        case "Per Share": return Theme.purple
        default: return Theme.textSecondary
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "--" }
        if metric.unit == "USD/shares" { return "$" + (widget?.formatPrice(value) ?? String(format: "%.2f", value)) }
        if metric.unit == "shares" { return StockTickerWidget.compactNumber(value) }
        return (value < 0 ? "-" : "") + StockTickerWidget.compactNumber(abs(value))
    }
}

private class MetricDrilldownPopoverController: NSViewController {
    private weak var widget: StockTickerWidget?
    private let quote: MarketQuote
    private let metric: ResearchMetric
    private let popoverW: CGFloat = 390
    private let popoverH: CGFloat = 410

    init(widget: StockTickerWidget, quote: MarketQuote, metric: ResearchMetric) {
        self.widget = widget
        self.quote = quote
        self.metric = metric
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = buildView()
    }

    private func buildView() -> NSView {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: popoverW, height: popoverH))
        root.wantsLayer = true

        let pad: CGFloat = 16
        let cw = popoverW - pad * 2
        let header = NSView(frame: NSRect(x: pad, y: 14, width: cw, height: 70))
        header.wantsLayer = true
        header.layer?.cornerRadius = 10
        header.layer?.backgroundColor = metric.color.withAlphaComponent(0.07).cgColor
        header.layer?.borderWidth = 0.5
        header.layer?.borderColor = metric.color.withAlphaComponent(0.18).cgColor
        root.addSubview(header)

        let symbol = NSTextField(labelWithString: quote.symbol)
        symbol.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        symbol.textColor = Theme.textFaint
        symbol.frame = NSRect(x: 12, y: 12, width: 80, height: 15)
        header.addSubview(symbol)

        let label = NSTextField(labelWithString: metric.label)
        label.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 30, width: 190, height: 22)
        header.addSubview(label)

        let value = NSTextField(labelWithString: metric.value)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        value.textColor = metric.color
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        value.frame = NSRect(x: cw - 156, y: 18, width: 144, height: 22)
        header.addSubview(value)

        let detail = NSTextField(labelWithString: metric.detail)
        detail.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        detail.textColor = Theme.textFaint
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: cw - 180, y: 43, width: 168, height: 12)
        header.addSubview(detail)

        addChartCard(to: root, y: 94, pad: pad, cw: cw, title: "LINE VIEW", mode: .line)
        addChartCard(to: root, y: 224, pad: pad, cw: cw, title: "BAR VIEW", mode: .bar)

        let thesis = NSView(frame: NSRect(x: pad, y: 350, width: cw, height: 46))
        thesis.wantsLayer = true
        thesis.layer?.cornerRadius = 9
        thesis.layer?.backgroundColor = Theme.cardBg.cgColor
        thesis.layer?.borderWidth = 0.5
        thesis.layer?.borderColor = Theme.cardBorder.cgColor
        root.addSubview(thesis)

        let text = NSTextField(labelWithString: metric.thesis)
        text.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        text.textColor = Theme.textMuted
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 3
        text.frame = NSRect(x: 10, y: 8, width: cw - 20, height: 32)
        thesis.addSubview(text)

        return root
    }

    private func addChartCard(to root: NSView, y: CGFloat, pad: CGFloat, cw: CGFloat, title: String, mode: MetricGraphView.Mode) {
        let card = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 118))
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor
        root.addSubview(card)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        titleLabel.textColor = Theme.textFaint
        titleLabel.frame = NSRect(x: 10, y: 8, width: 120, height: 11)
        card.addSubview(titleLabel)

        let graph = MetricGraphView(frame: NSRect(x: 10, y: 26, width: cw - 20, height: 82),
                                    metric: metric,
                                    mode: mode)
        card.addSubview(graph)
    }
}

private class MetricGraphView: NSView {
    enum Mode { case line, bar }

    private let metric: ResearchMetric
    private let mode: Mode

    init(frame: NSRect, metric: ResearchMetric, mode: Mode) {
        self.metric = metric
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let data = (mode == .line ? metric.lineData : metric.barData).filter { $0.isFinite }
        guard !data.isEmpty else { return }

        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.12).setFill()
        bg.fill()

        let plot = bounds.insetBy(dx: 18, dy: 16)
        drawGrid(plot: plot)

        var low = data.min() ?? 0
        var high = data.max() ?? 1
        if mode == .bar {
            low = min(low, 0)
            high = max(high, 0)
        }
        if high == low {
            high += max(abs(high) * 0.1, 1)
            low -= max(abs(low) * 0.1, 1)
        }
        let pad = max((high - low) * 0.08, 0.000001)
        high += pad
        low -= pad
        let range = max(high - low, 0.000001)

        drawScaleLabels(low: low, high: high, plot: plot)

        switch mode {
        case .line:
            drawLine(data: data, plot: plot, low: low, range: range)
        case .bar:
            drawBars(data: data, plot: plot, low: low, high: high, range: range)
        }
    }

    private func drawGrid(plot: NSRect) {
        Theme.divider.withAlphaComponent(0.55).setStroke()
        for i in 0...2 {
            let y = plot.minY + CGFloat(i) / 2 * plot.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 0.6
            path.stroke()
        }
    }

    private func drawLine(data: [Double], plot: NSRect, low: Double, range: Double) {
        guard data.count >= 2 else { return }
        let points = data.enumerated().map { idx, value -> NSPoint in
            let x = plot.minX + CGFloat(idx) / CGFloat(data.count - 1) * plot.width
            let y = plot.minY + CGFloat((value - low) / range) * plot.height
            return NSPoint(x: x, y: y)
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: points[0].x, y: plot.minY))
        points.forEach { fill.line(to: $0) }
        fill.line(to: NSPoint(x: points.last?.x ?? plot.maxX, y: plot.minY))
        fill.close()
        metric.color.withAlphaComponent(0.12).setFill()
        fill.fill()

        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        metric.color.setStroke()
        path.stroke()

        if let last = points.last {
            metric.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)).fill()
        }
    }

    private func drawBars(data: [Double], plot: NSRect, low: Double, high: Double, range: Double) {
        let zeroY = plot.minY + CGFloat((0 - low) / range) * plot.height
        let clampedZeroY = min(max(zeroY, plot.minY), plot.maxY)
        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: plot.minX, y: clampedZeroY))
        zero.line(to: NSPoint(x: plot.maxX, y: clampedZeroY))
        zero.lineWidth = 0.8
        Theme.textGhost.withAlphaComponent(0.45).setStroke()
        zero.stroke()

        let gap: CGFloat = 2
        let barW = max(3, (plot.width - gap * CGFloat(max(data.count - 1, 0))) / CGFloat(data.count))
        for (i, value) in data.enumerated() {
            let x = plot.minX + CGFloat(i) * (barW + gap)
            let y = plot.minY + CGFloat((value - low) / range) * plot.height
            let rectY = min(y, clampedZeroY)
            let rectH = max(abs(y - clampedZeroY), 2)
            let rect = NSRect(x: x, y: rectY, width: barW, height: rectH)
            let path = NSBezierPath(roundedRect: rect, xRadius: min(3, barW / 2), yRadius: min(3, barW / 2))
            let color = value >= 0 ? metric.color : Theme.red
            color.withAlphaComponent(i == data.count - 1 ? 0.92 : 0.42).setFill()
            path.fill()
        }
    }

    private func drawScaleLabels(low: Double, high: Double, plot: NSRect) {
        drawText(compactValue(high),
                 in: NSRect(x: plot.maxX - 70, y: plot.maxY - 11, width: 66, height: 10),
                 align: .right)
        drawText(compactValue(low),
                 in: NSRect(x: plot.maxX - 70, y: plot.minY + 1, width: 66, height: 10),
                 align: .right)
    }

    private func drawText(_ text: String, in rect: NSRect, align: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .regular),
            .foregroundColor: Theme.textGhost,
            .paragraphStyle: paragraph
        ])
    }

    private func compactValue(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 1e12 { return String(format: "%.1fT", value / 1e12) }
        if absValue >= 1e9 { return String(format: "%.1fB", value / 1e9) }
        if absValue >= 1e6 { return String(format: "%.1fM", value / 1e6) }
        if absValue >= 1e3 { return String(format: "%.1fK", value / 1e3) }
        if absValue >= 100 { return String(format: "%.0f", value) }
        if absValue >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

private class TerminalStockChartView: NSView {
    private weak var widget: StockTickerWidget?
    private let quote: MarketQuote
    private var history: StockPriceHistory?
    private var fallbackPoints: [StockPricePoint]
    private var hoverIndex: Int?
    private var tracking: NSTrackingArea?

    init(widget: StockTickerWidget, quote: MarketQuote, history: StockPriceHistory?, frame: NSRect) {
        self.widget = widget
        self.quote = quote
        self.history = history
        let now = Date()
        let series = quote.chartSeries.filter { $0.isFinite && $0 > 0 }
        self.fallbackPoints = series.enumerated().map { index, close in
            StockPricePoint(date: now.addingTimeInterval(Double(index - max(series.count - 1, 0)) * 300),
                            open: nil,
                            high: nil,
                            low: nil,
                            close: close,
                            volume: nil)
        }
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    func update(history: StockPriceHistory?) {
        self.history = history
        hoverIndex = nil
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let points = chartPoints
        guard points.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let plot = pricePlotRect
        guard plot.contains(point) else {
            hoverIndex = nil
            needsDisplay = true
            return
        }
        let progress = min(max((point.x - plot.minX) / plot.width, 0), 1)
        hoverIndex = min(max(Int(round(progress * CGFloat(points.count - 1))), 0), points.count - 1)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let points = chartPoints
        guard points.count > 1, let widget else { return }

        let change = history?.percentChange ?? quote.chartChange
        let accent = widget.intensityColor(for: change)
        let pricePlot = pricePlotRect
        let volumePlot = volumePlotRect
        let boundsPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.08).setFill()
        boundsPath.fill()

        var domainValues = points.map(\.close)
        domainValues.append(contentsOf: movingAverage(values: points.map(\.close), window: 20).compactMap { $0 })
        domainValues.append(contentsOf: movingAverage(values: points.map(\.close), window: 50).compactMap { $0 })
        guard var low = domainValues.min(), var high = domainValues.max() else { return }
        let actualLow = low
        let actualHigh = high
        if high == low {
            high *= 1.01
            low *= 0.99
        }
        let rawRange = max(high - low, 0.000001)
        let padding = rawRange * 0.08
        high += padding
        low = max(0, low - padding)
        let range = max(high - low, 0.000001)

        drawSessionBands(in: pricePlot)
        drawVolume(points: points, plot: volumePlot, color: accent)

        let mapped = points.enumerated().map { index, point -> NSPoint in
            let x = pricePlot.minX + CGFloat(index) / CGFloat(points.count - 1) * pricePlot.width
            let y = pricePlot.minY + CGFloat((point.close - low) / range) * pricePlot.height
            return NSPoint(x: x, y: y)
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: mapped[0].x, y: pricePlot.minY))
        mapped.forEach { fill.line(to: $0) }
        fill.line(to: NSPoint(x: mapped[mapped.count - 1].x, y: pricePlot.minY))
        fill.close()
        accent.withAlphaComponent(0.12).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.move(to: mapped[0])
        mapped.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 2.2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        accent.setStroke()
        line.stroke()

        drawMovingAverage(points: points, mappedCount: mapped.count, window: 20, low: low, range: range, plot: pricePlot, color: Theme.brandAmber)
        drawMovingAverage(points: points, mappedCount: mapped.count, window: 50, low: low, range: range, plot: pricePlot, color: Theme.brandCyan)
        drawDot(at: mapped[mapped.count - 1], radius: 3.4, color: accent)
        drawAxisLabels(high: actualHigh, low: actualLow, plot: pricePlot, widget: widget)
        drawHeaderLabels(history: history, change: change, color: accent, widget: widget)
        drawRangeLabels(points: points, plot: volumePlot)

        if let hoverIndex {
            drawHover(index: hoverIndex,
                      point: mapped[hoverIndex],
                      value: points[hoverIndex],
                      pricePlot: pricePlot,
                      volumePlot: volumePlot,
                      widget: widget,
                      color: accent)
        }
    }

    private var chartPoints: [StockPricePoint] {
        let points = history?.points ?? fallbackPoints
        return points.filter { $0.close.isFinite && $0.close > 0 }
    }

    private var pricePlotRect: NSRect {
        NSRect(x: bounds.minX + 18, y: bounds.minY + 56, width: bounds.width - 36, height: bounds.height - 82)
    }

    private var volumePlotRect: NSRect {
        NSRect(x: bounds.minX + 18, y: bounds.minY + 20, width: bounds.width - 36, height: 28)
    }

    private func drawSessionBands(in plot: NSRect) {
        let upper = NSBezierPath(roundedRect: NSRect(x: plot.minX, y: plot.maxY - 1, width: plot.width, height: 1), xRadius: 0.5, yRadius: 0.5)
        Theme.cardBorder.withAlphaComponent(0.45).setFill()
        upper.fill()

        let lower = NSBezierPath(roundedRect: NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1), xRadius: 0.5, yRadius: 0.5)
        Theme.cardBorder.withAlphaComponent(0.32).setFill()
        lower.fill()
    }

    private func drawVolume(points: [StockPricePoint], plot: NSRect, color: NSColor) {
        let volumes = points.compactMap(\.volume)
        guard let maxVolume = volumes.max(), maxVolume > 0 else {
            drawText("Volume unavailable",
                     in: NSRect(x: plot.minX, y: plot.minY + 9, width: 120, height: 10),
                     color: Theme.textGhost,
                     font: NSFont.systemFont(ofSize: 8, weight: .medium),
                     align: .left)
            return
        }
        let gap: CGFloat = points.count > 140 ? 0 : 0.7
        let barW = max(0.8, (plot.width - gap * CGFloat(max(points.count - 1, 0))) / CGFloat(points.count))
        for (index, point) in points.enumerated() {
            guard let volume = point.volume else { continue }
            let x = plot.minX + CGFloat(index) * (barW + gap)
            let h = max(1.5, plot.height * CGFloat(volume / maxVolume))
            let rect = NSRect(x: x, y: plot.minY, width: barW, height: h)
            let barColor: NSColor
            if let open = point.open {
                barColor = point.close >= open ? Theme.green : Theme.red
            } else {
                barColor = color
            }
            barColor.withAlphaComponent(index == points.count - 1 ? 0.46 : 0.20).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(2, barW / 2), yRadius: min(2, barW / 2)).fill()
        }
    }

    private func movingAverage(values: [Double], window: Int) -> [Double?] {
        guard values.count >= window else { return Array(repeating: nil, count: values.count) }
        var result = Array<Double?>(repeating: nil, count: values.count)
        var running = 0.0
        for index in values.indices {
            running += values[index]
            if index >= window { running -= values[index - window] }
            if index >= window - 1 { result[index] = running / Double(window) }
        }
        return result
    }

    private func drawMovingAverage(points: [StockPricePoint], mappedCount: Int, window: Int, low: Double, range: Double, plot: NSRect, color: NSColor) {
        let values = points.map(\.close)
        let ma = movingAverage(values: values, window: window)
        let mapped = ma.enumerated().compactMap { index, value -> NSPoint? in
            guard let value else { return nil }
            let x = plot.minX + CGFloat(index) / CGFloat(max(mappedCount - 1, 1)) * plot.width
            let y = plot.minY + CGFloat((value - low) / range) * plot.height
            return NSPoint(x: x, y: y)
        }
        guard mapped.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: mapped[0])
        mapped.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = window == 20 ? 1.15 : 0.95
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.withAlphaComponent(window == 20 ? 0.78 : 0.58).setStroke()
        path.stroke()
    }

    private func drawAxisLabels(high: Double, low: Double, plot: NSRect, widget: StockTickerWidget) {
        drawText("$" + widget.formatPrice(high),
                 in: NSRect(x: plot.maxX - 82, y: plot.maxY - 12, width: 80, height: 10),
                 color: Theme.textGhost,
                 font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                 align: .right)
        drawText("$" + widget.formatPrice(low),
                 in: NSRect(x: plot.maxX - 82, y: plot.minY + 2, width: 80, height: 10),
                 color: Theme.textGhost,
                 font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                 align: .right)
        if let baseline = quote.chartBaseline {
            drawText("Base $" + widget.formatPrice(baseline),
                     in: NSRect(x: plot.minX, y: plot.minY + 2, width: 116, height: 10),
                     color: Theme.textGhost,
                     font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                     align: .left)
        }
    }

    private func drawHeaderLabels(history: StockPriceHistory?, change: Double, color: NSColor, widget: StockTickerWidget) {
        let latest = history?.latest?.close ?? quote.currentPrice
        drawText("$\(widget.formatPrice(latest))  \(change >= 0 ? "+" : "")\(String(format: "%.2f", change))%",
                 in: NSRect(x: bounds.minX + 14, y: bounds.maxY - 20, width: 190, height: 13),
                 color: color,
                 font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                 align: .left)
        let source = history.map { "\($0.range.rawValue) \(Int($0.points.count)) bars" } ?? "\(quote.chartSeries.count) live samples"
        drawText(source,
                 in: NSRect(x: bounds.maxX - 150, y: bounds.maxY - 20, width: 136, height: 12),
                 color: Theme.textGhost,
                 font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                 align: .right)
    }

    private func drawRangeLabels(points: [StockPricePoint], plot: NSRect) {
        guard let first = points.first, let last = points.last else { return }
        drawText(dateLabel(first.date),
                 in: NSRect(x: plot.minX, y: bounds.minY + 6, width: 120, height: 10),
                 color: Theme.textGhost,
                 font: NSFont.systemFont(ofSize: 8, weight: .medium),
                 align: .left)
        drawText(dateLabel(last.date),
                 in: NSRect(x: plot.maxX - 120, y: bounds.minY + 6, width: 120, height: 10),
                 color: Theme.textGhost,
                 font: NSFont.systemFont(ofSize: 8, weight: .medium),
                 align: .right)
    }

    private func drawHover(index: Int, point: NSPoint, value: StockPricePoint, pricePlot: NSRect, volumePlot: NSRect, widget: StockTickerWidget, color: NSColor) {
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: point.x, y: volumePlot.minY))
        cross.line(to: NSPoint(x: point.x, y: pricePlot.maxY))
        cross.lineWidth = 1
        Theme.textMuted.withAlphaComponent(0.38).setStroke()
        cross.stroke()

        drawDot(at: point, radius: 4.2, color: color)

        let reference = chartPoints.first?.close ?? quote.chartBaseline ?? quote.price
        let change = reference > 0 ? (value.close - reference) / reference * 100 : quote.chartChange
        let priceText = "$\(widget.formatPrice(value.close))  \(change >= 0 ? "+" : "")\(String(format: "%.2f", change))%"
        let sampleText = "\(dateLabel(value.date))  Vol \(value.volume.map(StockTickerWidget.compactNumber) ?? "--")"
        let ohlText: String
        if let open = value.open, let high = value.high, let low = value.low {
            ohlText = "O \(widget.formatPrice(open))  H \(widget.formatPrice(high))  L \(widget.formatPrice(low))"
        } else {
            ohlText = "Hovering sample \(index + 1) of \(chartPoints.count)"
        }
        let tipW: CGFloat = 208
        let tipH: CGFloat = 62
        var tx = point.x + 10
        if tx + tipW > bounds.maxX - 8 { tx = point.x - tipW - 10 }
        let ty = min(max(point.y + 10, bounds.minY + 8), bounds.maxY - tipH - 8)
        let rect = NSRect(x: tx, y: ty, width: tipW, height: tipH)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        Theme.cardBorderHover.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        drawText(priceText,
                 in: NSRect(x: rect.minX + 9, y: rect.minY + 22, width: tipW - 18, height: 13),
                 color: color,
                 font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                 align: .left)
        drawText(sampleText,
                 in: NSRect(x: rect.minX + 9, y: rect.minY + 24, width: tipW - 18, height: 11),
                 color: Theme.textFaint,
                 font: NSFont.systemFont(ofSize: 9, weight: .medium),
                 align: .left)
        drawText(ohlText,
                 in: NSRect(x: rect.minX + 9, y: rect.minY + 9, width: tipW - 18, height: 11),
                 color: Theme.textGhost,
                 font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                 align: .left)
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = history?.range == .oneDay || history?.range == .fiveDay ? "MMM d h:mm a" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func drawDot(at point: NSPoint, radius: CGFloat, color: NSColor) {
        let outer = NSBezierPath(ovalIn: NSRect(x: point.x - radius - 1.5, y: point.y - radius - 1.5, width: (radius + 1.5) * 2, height: (radius + 1.5) * 2))
        color.withAlphaComponent(0.16).setFill()
        outer.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        color.setFill()
        dot.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, font: NSFont, align: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

private class FundamentalChartView: NSView {
    enum Mode { case bars, lines, stacked }

    private let metrics: [FundamentalMetricSeries]
    private let mode: Mode
    private let palette: [NSColor] = [Theme.green, Theme.brandCyan, Theme.brandAmber, Theme.purple, Theme.textSecondary]

    init(frame: NSRect, metrics: [FundamentalMetricSeries], mode: Mode) {
        self.metrics = metrics.filter { !$0.points.isEmpty }
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.12).setFill()
        bg.fill()
        guard !metrics.isEmpty else { return }

        let plot = bounds.insetBy(dx: 18, dy: 17)
        let limit = metrics.contains(where: { $0.points.contains { $0.fiscalPeriod.hasPrefix("Q") } }) ? 8 : 6
        let labels = Array(Set(metrics.flatMap { $0.points.map(\.label) })).sorted().suffix(limit)
        guard labels.count >= 1 else { return }

        drawGrid(plot: plot)
        switch mode {
        case .bars:
            drawGroupedBars(labels: Array(labels), plot: plot)
        case .lines:
            drawLines(labels: Array(labels), plot: plot)
        case .stacked:
            drawStackedBars(labels: Array(labels), plot: plot)
        }
        drawAxisLabels(labels: Array(labels), plot: plot)
    }

    private func value(for metric: FundamentalMetricSeries, label: String) -> Double? {
        metric.points.first(where: { $0.label == label })?.value
    }

    private func domainValues(labels: [String], stacked: Bool = false) -> [Double] {
        if stacked {
            return labels.map { label in
                metrics.compactMap { value(for: $0, label: label) }.map(abs).reduce(0, +)
            }
        }
        return metrics.flatMap { metric in labels.compactMap { value(for: metric, label: $0) } }
    }

    private func range(values: [Double]) -> (low: Double, high: Double) {
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        low = min(low, 0)
        if high == low {
            high += max(abs(high) * 0.1, 1)
            low -= max(abs(low) * 0.1, 1)
        }
        let pad = max((high - low) * 0.08, 1)
        return (low - pad, high + pad)
    }

    private func yFor(_ value: Double, plot: NSRect, low: Double, high: Double) -> CGFloat {
        plot.minY + CGFloat((value - low) / max(high - low, 0.000001)) * plot.height
    }

    private func drawGrid(plot: NSRect) {
        Theme.divider.withAlphaComponent(0.6).setStroke()
        for i in 0...2 {
            let y = plot.minY + CGFloat(i) / 2 * plot.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 0.6
            path.stroke()
        }
    }

    private func drawGroupedBars(labels: [String], plot: NSRect) {
        let values = domainValues(labels: labels)
        let r = range(values: values)
        let groupW = plot.width / CGFloat(max(labels.count, 1))
        let barW = max(2, (groupW - 7) / CGFloat(max(metrics.count, 1)))
        let zeroY = min(max(yFor(0, plot: plot, low: r.low, high: r.high), plot.minY), plot.maxY)
        for (labelIndex, label) in labels.enumerated() {
            let groupX = plot.minX + CGFloat(labelIndex) * groupW + 3
            for (metricIndex, metric) in metrics.enumerated() {
                guard let value = value(for: metric, label: label) else { continue }
                let y = yFor(value, plot: plot, low: r.low, high: r.high)
                let rect = NSRect(x: groupX + CGFloat(metricIndex) * barW, y: min(y, zeroY), width: max(barW - 1, 2), height: max(abs(y - zeroY), 2))
                palette[metricIndex % palette.count].withAlphaComponent(metricIndex == 0 ? 0.82 : 0.55).setFill()
                NSBezierPath(roundedRect: rect, xRadius: min(3, rect.width / 2), yRadius: 3).fill()
            }
        }
    }

    private func drawStackedBars(labels: [String], plot: NSRect) {
        let values = domainValues(labels: labels, stacked: true)
        let r = range(values: values)
        let groupW = plot.width / CGFloat(max(labels.count, 1))
        let barW = max(8, groupW * 0.44)
        for (labelIndex, label) in labels.enumerated() {
            var base: Double = 0
            let x = plot.minX + CGFloat(labelIndex) * groupW + (groupW - barW) / 2
            for (metricIndex, metric) in metrics.enumerated() {
                guard let raw = value(for: metric, label: label) else { continue }
                let value = abs(raw)
                let y0 = yFor(base, plot: plot, low: r.low, high: r.high)
                let y1 = yFor(base + value, plot: plot, low: r.low, high: r.high)
                let rect = NSRect(x: x, y: min(y0, y1), width: barW, height: max(abs(y1 - y0), 2))
                palette[metricIndex % palette.count].withAlphaComponent(0.62).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                base += value
            }
        }
    }

    private func drawLines(labels: [String], plot: NSRect) {
        let values = domainValues(labels: labels)
        let r = range(values: values)
        for (metricIndex, metric) in metrics.enumerated() {
            let points = labels.enumerated().compactMap { index, label -> NSPoint? in
                guard let value = value(for: metric, label: label) else { return nil }
                let x = labels.count == 1 ? plot.midX : plot.minX + CGFloat(index) / CGFloat(labels.count - 1) * plot.width
                let y = yFor(value, plot: plot, low: r.low, high: r.high)
                return NSPoint(x: x, y: y)
            }
            guard points.count >= 2 else { continue }
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 1.8
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            palette[metricIndex % palette.count].withAlphaComponent(metricIndex == 0 ? 0.92 : 0.65).setStroke()
            path.stroke()
        }
    }

    private func drawAxisLabels(labels: [String], plot: NSRect) {
        guard !labels.isEmpty else { return }
        for (index, label) in labels.enumerated() {
            let x = labels.count == 1 ? plot.midX - 20 : plot.minX + CGFloat(index) / CGFloat(max(labels.count - 1, 1)) * plot.width - 20
            let text = compactAxisLabel(label)
            (text as NSString).draw(in: NSRect(x: x, y: bounds.minY + 4, width: 40, height: 10), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular),
                .foregroundColor: Theme.textGhost
            ])
        }
    }

    private func compactAxisLabel(_ label: String) -> String {
        if label.contains("Q") {
            let parts = label.split(separator: " ")
            if parts.count == 2 { return "'\(String(parts[0].suffix(2)))\(parts[1])" }
        }
        return "'\(String(label.suffix(2)))"
    }
}

private class FundamentalTinyChartView: NSView {
    private let metric: FundamentalMetricSeries
    private let color: NSColor

    init(frame: NSRect, metric: FundamentalMetricSeries, color: NSColor) {
        self.metric = metric
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let values = metric.points.suffix(6).map(\.value)
        guard values.count >= 2 else { return }
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        if high == low {
            high += 1
            low -= 1
        }
        let range = max(high - low, 0.000001)
        let points = values.enumerated().map { index, value -> NSPoint in
            let x = bounds.minX + CGFloat(index) / CGFloat(values.count - 1) * bounds.width
            let y = bounds.minY + CGFloat((value - low) / range) * bounds.height
            return NSPoint(x: x, y: y)
        }
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 1.4
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        color.withAlphaComponent(0.86).setStroke()
        path.stroke()
    }
}

private class TerminalFlowBarsView: NSView {
    private let values: [Double]
    private let colors: [NSColor]

    init(frame: NSRect, values: [Double], colors: [NSColor]) {
        self.values = values.map { min(max($0, 0), 1) }
        self.colors = colors
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !values.isEmpty else { return }
        let gap: CGFloat = 6
        let barW = (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
        for (i, value) in values.enumerated() {
            let x = bounds.minX + CGFloat(i) * (barW + gap)
            let frame = NSRect(x: x, y: bounds.minY, width: barW, height: bounds.height)
            let track = NSBezierPath(roundedRect: frame, xRadius: min(5, bounds.height / 2), yRadius: min(5, bounds.height / 2))
            Theme.trackBg.withAlphaComponent(0.9).setFill()
            track.fill()

            let fillWidth = max(4, frame.width * CGFloat(value))
            let fill = NSBezierPath(roundedRect: NSRect(x: frame.minX, y: frame.minY, width: fillWidth, height: frame.height),
                                    xRadius: min(5, bounds.height / 2),
                                    yRadius: min(5, bounds.height / 2))
            let color = colors.indices.contains(i) ? colors[i].withAlphaComponent(0.72) : Theme.textMuted
            color.setFill()
            fill.fill()
        }
    }
}

private class StockRangeTrackView: NSView {
    private let low: Double
    private let high: Double
    private let current: Double
    private let tint: NSColor

    init(frame: NSRect, low: Double, high: Double, current: Double, tint: NSColor) {
        self.low = low
        self.high = high
        self.current = current
        self.tint = tint
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSRect(x: 0, y: bounds.midY - 3, width: bounds.width, height: 6)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        Theme.trackBg.withAlphaComponent(0.9).setFill()
        trackPath.fill()

        let pct = high > low ? min(max((current - low) / (high - low), 0), 1) : 0.5
        let fill = NSRect(x: 0, y: track.minY, width: max(4, track.width * CGFloat(pct)), height: track.height)
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3)
        tint.withAlphaComponent(0.34).setFill()
        fillPath.fill()

        let markerX = track.minX + track.width * CGFloat(pct)
        let marker = NSBezierPath(roundedRect: NSRect(x: markerX - 2, y: bounds.midY - 7, width: 4, height: 14), xRadius: 2, yRadius: 2)
        tint.setFill()
        marker.fill()
    }
}
