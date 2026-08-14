import Cocoa

// MARK: - Stock Ticker Main Popover

class MarketPopoverController: NSObject, NSTextFieldDelegate {
    weak var widget: StockTickerWidget?
    private var scrollView: NSScrollView!
    private var docView: FlippedView!
    private let popoverW: CGFloat = 420
    private var detailPopover: NSPopover?

    init(widget: StockTickerWidget) {
        self.widget = widget
        super.init()
    }

    func buildView() -> NSView {
        guard let w = widget else { return NSView() }

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: popoverW, height: 560))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        docView = FlippedView(frame: NSRect(x: 0, y: 0, width: popoverW, height: 800))
        docView.wantsLayer = true
        scrollView.documentView = docView

        rebuildContent()

        w.onDataRefresh = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // The detail popover is anchored to a button inside this content.
                // Rebuilding removes that button and closes the popover, so defer
                // the live refresh until the detail popover is dismissed.
                if self.detailPopover?.isShown == true { return }
                self.rebuildContent()
            }
        }

        return scrollView
    }

    private func rebuildContent() {
        guard let w = widget else { return }

        let savedScrollY = scrollView.contentView.bounds.origin.y
        docView.subviews.forEach { $0.removeFromSuperview() }

        let pad: CGFloat = 16
        let cw = popoverW - pad * 2
        var y: CGFloat = 14

        let sorted = w.sortedQuotes()
        let stocks = sorted.filter { $0.kind == .stock }
        let crypto = sorted.filter { $0.kind == .crypto }

        // Indices
        if w.config.showIndices && !w.indexQuotes.isEmpty {
            y += 2
            addIndicesBar(y: &y, pad: pad, cw: cw)
        }

        // Portfolio. Once a second portfolio exists the card stays put even when the
        // active one is empty, otherwise the tabs would vanish with no way back.
        let snapshot = w.portfolioSnapshot()
        if snapshot != nil || w.config.portfolios.count > 1 {
            y += 2
            addPortfolioSummary(snapshot, y: &y, pad: pad, cw: cw)
            if let snapshot {
                addHistoryCard(snapshot, y: &y, pad: pad, cw: cw)
                addAllocationCard(snapshot, y: &y, pad: pad, cw: cw)
            }
        }

        y += 6

        // Stocks
        if !stocks.isEmpty {
            addSectionHeader("STOCKS", count: stocks.count, y: &y, pad: pad, cw: cw)
            for q in stocks { addQuoteRow(q, y: &y, pad: pad, cw: cw) }
            let avg = stocks.map(\.currentChange).reduce(0, +) / Double(stocks.count)
            addAvgLine(avg, label: "Stock Avg", y: &y, pad: pad, cw: cw)
            y += 6
        }

        // Crypto
        if !crypto.isEmpty {
            addSectionHeader("CRYPTO", count: crypto.count, y: &y, pad: pad, cw: cw)
            for q in crypto { addQuoteRow(q, y: &y, pad: pad, cw: cw) }
            let avg = crypto.map(\.change).reduce(0, +) / Double(crypto.count)
            addAvgLine(avg, label: "Crypto Avg", y: &y, pad: pad, cw: cw)
            y += 6
        }

        // Overall avg
        if !stocks.isEmpty && !crypto.isEmpty {
            let all = sorted.map(\.currentChange)
            addAvgLine(all.reduce(0, +) / Double(all.count), label: "Overall", y: &y, pad: pad, cw: cw)
            y += 4
        }

        // Failed symbols
        for sym in w.failedSymbols {
            addFailedRow(sym, y: &y, pad: pad, cw: cw)
        }

        // Pending symbols
        let loadedStockSyms = Set(stocks.map(\.symbol))
        let pendingStocks = w.config.symbols.filter { !loadedStockSyms.contains($0) && !w.failedSymbols.contains($0) }
        for sym in pendingStocks { addPendingRow(sym, kind: .stock, y: &y, pad: pad, cw: cw) }

        let loadedCryptoSyms = Set(crypto.map(\.symbol))
        let pendingCrypto = w.config.coins.filter {
            let sym = coinSymbols[$0] ?? String($0.prefix(4)).uppercased()
            return !loadedCryptoSyms.contains(sym)
        }
        for coinId in pendingCrypto {
            let sym = coinSymbols[coinId] ?? String(coinId.prefix(4)).uppercased()
            addPendingRow(sym, kind: .crypto, y: &y, pad: pad, cw: cw)
        }

        addDivider(y: &y, pad: pad, cw: cw)
        addAddField(y: &y, pad: pad, cw: cw)
        addDivider(y: &y, pad: pad, cw: cw)
        addSettings(y: &y, pad: pad, cw: cw)
        y += 6
        addFooter(y: &y, pad: pad, cw: cw)
        y += 14
        docView.frame.size.height = y

        DispatchQueue.main.async {
            let maxY = max(0, y - self.scrollView.contentView.bounds.height)
            let clampedY = min(savedScrollY, maxY)
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    // MARK: - Indices Bar

    private func addIndicesBar(y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }
        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: 46))
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor
        docView.addSubview(card)

        let indices: [(String, String)] = [("S&P 500", "SPY"), ("NASDAQ", "QQQ"), ("DOW", "DIA")]
        let colW = cw / 3
        for (i, (name, sym)) in indices.enumerated() {
            guard let q = w.indexQuotes.first(where: { $0.symbol == sym }) else { continue }
            let x = 12 + CGFloat(i) * colW
            let nl = NSTextField(labelWithString: name)
            nl.font = NSFont.systemFont(ofSize: 9, weight: .medium); nl.textColor = Theme.textFaint
            nl.frame = NSRect(x: x, y: 9, width: colW - 10, height: 12)
            card.addSubview(nl)
            let session = (q.extendedHours?.label).map { " \($0)" } ?? ""
            let vl = NSTextField(labelWithString: "\(q.currentIsUp ? "\u{25B2}" : "\u{25BC}")\(String(format: "%.2f%%", abs(q.currentChange)))\(session)")
            vl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            vl.textColor = w.intensityColor(for: q.currentChange)
            vl.frame = NSRect(x: x, y: 24, width: colW - 10, height: 14)
            card.addSubview(vl)
        }
        y += 52
    }

    // MARK: - Portfolio

    /// The portfolio card. `pv` is nil when the active portfolio is still empty,
    /// which only reaches here when other portfolios exist - the tab strip has to
    /// stay reachable so you can switch back.
    private func addPortfolioSummary(_ pv: PortfolioSnapshot?, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }

        let tabRowH: CGFloat = 28
        let showsTotalReturn = pv?.totalPL != nil
        let bodyH: CGFloat = pv == nil ? 44 : (showsTotalReturn ? 88 : 74)
        let cardH = bodyH + tabRowH

        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: cardH))
        card.wantsLayer = true; card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.06).cgColor
        card.layer?.borderWidth = 0.5; card.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.15).cgColor
        docView.addSubview(card)

        addPortfolioTabs(to: card, cardW: cw + 8, atY: bodyH)

        guard let pv else {
            let empty = NSTextField(labelWithString: "No holdings yet")
            empty.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            empty.textColor = Theme.textMuted
            empty.frame = NSRect(x: 10, y: 22, width: cw / 2, height: 16)
            card.addSubview(empty)

            let hint = NSTextField(labelWithString: "Use +sh on a symbol below to add a position")
            hint.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            hint.textColor = Theme.textGhost
            hint.lineBreakMode = .byTruncatingTail
            hint.frame = NSRect(x: 10, y: 8, width: cw - 20, height: 11)
            card.addSubview(hint)

            addCashButton(to: card, cash: w.config.cash, atY: 21, cw: cw)
            y += cardH + 6
            return
        }

        // With a total-return line present the upper rows lift to make room for it.
        let lift: CGFloat = showsTotalReturn ? 14 : 0

        let vl = NSTextField(labelWithString: w.formatCurrency(pv.total))
        vl.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold); vl.textColor = Theme.textPrimary
        vl.frame = NSRect(x: 10, y: 50 + lift, width: cw / 2, height: 18)
        card.addSubview(vl)

        let pl = NSTextField(labelWithString: String(format: "%@ (%@%.1f%%)",
                                                     w.formatSignedCurrency(pv.dailyPL),
                                                     pv.dailyPercent >= 0 ? "+" : "",
                                                     pv.dailyPercent))
        pl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pl.textColor = w.intensityColor(for: pv.dailyPercent)
        pl.alignment = .right; pl.frame = NSRect(x: cw / 2, y: 52 + lift, width: cw / 2 - 4, height: 16)
        card.addSubview(pl)

        let positionText = "\(pv.positions.count) position\(pv.positions.count == 1 ? "" : "s")  \(pv.winners) up / \(pv.losers) down"
        let positionLabel = NSTextField(labelWithString: positionText)
        positionLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        positionLabel.textColor = Theme.textMuted
        positionLabel.frame = NSRect(x: 10, y: 34 + lift, width: cw - 116, height: 12)
        card.addSubview(positionLabel)

        addCashButton(to: card, cash: pv.cash, atY: 31 + lift, cw: cw)

        // Total return since purchase, across the positions that have a cost recorded.
        if let totalPL = pv.totalPL, let totalCost = pv.totalCost {
            let pct = pv.totalPercent ?? 0
            let costLabel = NSTextField(labelWithString: "Cost \(w.formatCurrency(totalCost))")
            costLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            costLabel.textColor = Theme.textMuted
            costLabel.frame = NSRect(x: 10, y: 32, width: cw / 2, height: 13)
            card.addSubview(costLabel)

            let suffix = pv.hasPartialCostBasis ? "  (\(pv.costedPositions.count) of \(pv.positions.count))" : ""
            let gain = NSTextField(labelWithString: String(format: "%@ (%@%.1f%%)%@",
                                                           w.formatSignedCurrency(totalPL),
                                                           pct >= 0 ? "+" : "",
                                                           pct, suffix))
            gain.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            gain.textColor = w.intensityColor(for: pct)
            gain.alignment = .right
            gain.lineBreakMode = .byTruncatingTail
            gain.frame = NSRect(x: cw / 2 - 40, y: 32, width: cw / 2 + 36, height: 13)
            card.addSubview(gain)
        }

        var insightParts: [String] = []
        if let top = pv.topExposure {
            insightParts.append(String(format: "Top %@ %.0f%%", top.quote.symbol, pv.weight(of: top)))
        }
        if let best = pv.bestPosition, abs(best.dailyPL) >= 0.01 {
            insightParts.append("Best \(best.quote.symbol) \(w.formatSignedCurrency(best.dailyPL))")
        }
        let bestSymbol = pv.bestPosition?.quote.symbol
        if let worst = pv.worstPosition,
           abs(worst.dailyPL) >= 0.01,
           bestSymbol.map({ worst.quote.symbol != $0 }) ?? true {
            insightParts.append("Worst \(worst.quote.symbol) \(w.formatSignedCurrency(worst.dailyPL))")
        }
        if !pv.missingSymbols.isEmpty {
            insightParts.append("Missing \(pv.missingSymbols.joined(separator: ","))")
        }

        let insight = NSTextField(labelWithString: insightParts.joined(separator: "   "))
        insight.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        insight.textColor = Theme.textGhost
        insight.lineBreakMode = .byTruncatingTail
        insight.frame = NSRect(x: 10, y: 18, width: cw - 20, height: 11)
        card.addSubview(insight)

        let baselineLabel = NSTextField(labelWithString: "Prev close basis \(w.formatCurrency(pv.baselineTotal))")
        baselineLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        baselineLabel.textColor = Theme.textGhost
        baselineLabel.frame = NSRect(x: 10, y: 5, width: cw - 20, height: 10)
        card.addSubview(baselineLabel)

        y += cardH + 6
    }

    // MARK: - Collapsible Card Headers

    /// Header row with a disclosure chevron. The whole row is the hit target,
    /// not just the chevron, and a summary sits on the right when collapsed so a
    /// shut card still tells you something.
    private func addCollapsibleHeader(to card: NSView,
                                      title: String,
                                      cardH: CGFloat,
                                      cw: CGFloat,
                                      collapsed: Bool,
                                      summary: NSAttributedString?,
                                      action: Selector) {
        let rowH: CGFloat = 22
        let rowY = cardH - rowH - 4

        let chevron = NSImageView(frame: NSRect(x: 12, y: rowY + 5, width: 10, height: 10))
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: collapsed ? "Expand" : "Collapse")
        chevron.contentTintColor = Theme.textFaint
        card.addSubview(chevron)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        label.textColor = Theme.textFaint
        label.frame = NSRect(x: 27, y: rowY + 4, width: 110, height: 12)
        card.addSubview(label)

        if collapsed, let summary {
            let s = NSTextField(labelWithAttributedString: summary)
            s.alignment = .right
            s.lineBreakMode = .byTruncatingTail
            s.frame = NSRect(x: cw / 2 - 40, y: rowY + 4, width: cw / 2 + 36, height: 13)
            card.addSubview(s)
        }

        // Transparent button across the row, added last so it sits on top.
        // Kept clear of the right edge when expanded, where the range picker lives.
        let hitWidth = collapsed ? cw + 8 : min(cw + 8, 150)
        let hit = NSButton(frame: NSRect(x: 0, y: rowY, width: hitWidth, height: rowH))
        hit.isBordered = false
        hit.isTransparent = true
        hit.toolTip = collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())"
        hit.target = self
        hit.action = action
        card.addSubview(hit)
    }

    @objc private func historyCollapseToggled() {
        guard let w = widget else { return }
        w.config.historyCollapsed.toggle()
        w.saveConfig()
        rebuildContent()
    }

    @objc private func allocationCollapseToggled() {
        guard let w = widget else { return }
        w.config.allocationCollapsed.toggle()
        w.saveConfig()
        rebuildContent()
    }

    // MARK: - Portfolio History

    /// Value over time for the active portfolio: headline value, range picker,
    /// an interactive chart, and the stats worth knowing at a glance.
    ///
    /// History accrues from first run, so this stays in an explanatory state
    /// until there are two days to compare.
    private func addHistoryCard(_ pv: PortfolioSnapshot, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget, let active = w.config.activePortfolio else { return }

        let history = PortfolioHistoryService.shared
        let range = w.config.historyRange
        let totalSamples = history.sampleCount(for: active.id)

        // 1D is rebuilt live from today's intraday quotes; the other ranges come
        // from the stored daily series.
        let intraday = range.isIntraday ? w.intradayPortfolioSeries() : nil
        let points: [PortfolioHistoryService.Point] = range.isIntraday
            ? (intraday ?? []).map { PortfolioHistoryService.Point(time: $0.date, value: $0.value) }
            : history.points(for: active.id, range: range)
        let hasChart = points.count >= 2

        let collapsed = w.config.historyCollapsed
        let chartH: CGFloat = 104
        let cardH: CGFloat = collapsed ? 30 : (hasChart ? 176 : 74)
        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: cardH))
        card.wantsLayer = true; card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5; card.layer?.borderColor = Theme.cardBorder.cgColor
        docView.addSubview(card)

        // Collapsed summary: the move over the selected range.
        var headerSummary: NSAttributedString?
        if collapsed {
            let collapsedDelta = range.isIntraday
                ? (points.count >= 2 && points[0].value > 0
                    ? (points[points.count - 1].value - points[0].value, (points[points.count - 1].value - points[0].value) / points[0].value * 100)
                    : nil)
                : history.change(for: active.id, range: range)
            if let d = collapsedDelta {
                headerSummary = NSAttributedString(
                    string: String(format: "%@  %@ (%@%.1f%%)", range.label,
                                   w.formatSignedCurrency(d.0),
                                   d.1 >= 0 ? "+" : "", d.1),
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                                 .foregroundColor: w.intensityColor(for: d.1)])
            } else {
                headerSummary = NSAttributedString(string: "no data yet", attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: Theme.textGhost])
            }
        }

        addCollapsibleHeader(to: card, title: "HISTORY", cardH: cardH, cw: cw,
                             collapsed: collapsed, summary: headerSummary,
                             action: #selector(historyCollapseToggled))

        guard !collapsed else {
            y += cardH + 6
            return
        }

        addHistoryRangePicker(to: card, cardH: cardH, cw: cw, selected: range)

        guard hasChart else {
            let message: String
            if range.isIntraday {
                message = "No intraday data yet - it fills in as quotes arrive during the session."
            } else if totalSamples == 0 {
                message = "Tracking starts now - the chart appears once there are two days of history."
            } else {
                message = "One day recorded so far. The chart appears tomorrow."
            }
            let note = NSTextField(labelWithString: message)
            note.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
            note.textColor = Theme.textGhost
            note.lineBreakMode = .byWordWrapping
            note.frame = NSRect(x: 12, y: 14, width: cw - 20, height: 26)
            card.addSubview(note)
            y += cardH + 6
            return
        }

        let values = points.map(\.value)
        let delta: (absolute: Double, percent: Double)?
        if range.isIntraday {
            if let first = values.first, let last = values.last, first > 0 {
                delta = (last - first, (last - first) / first * 100)
            } else {
                delta = nil
            }
        } else {
            delta = history.change(for: active.id, range: range)
        }
        let pct = delta?.percent ?? 0
        let tint = w.intensityColor(for: pct)

        // Headline: where the portfolio stands now, and the move over the range.
        let latest = NSTextField(labelWithString: PortfolioChartView.money(values.last ?? 0))
        latest.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        latest.textColor = Theme.textPrimary
        latest.frame = NSRect(x: 12, y: cardH - 40, width: cw / 2, height: 19)
        card.addSubview(latest)

        if let delta {
            let arrow = delta.absolute >= 0 ? "\u{25B2}" : "\u{25BC}"
            let changeLabel = NSTextField(labelWithString: String(format: "%@ %@  (%@%.1f%%)",
                                                                 arrow,
                                                                 w.formatSignedCurrency(delta.absolute),
                                                                 delta.percent >= 0 ? "+" : "",
                                                                 delta.percent))
            changeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            changeLabel.textColor = tint
            changeLabel.alignment = .right
            changeLabel.frame = NSRect(x: cw / 2 - 40, y: cardH - 38, width: cw / 2 + 36, height: 16)
            card.addSubview(changeLabel)
        }

        // The chart itself.
        let chart = PortfolioChartView(frame: NSRect(x: 10, y: 30, width: cw - 12, height: chartH))
        chart.accent = tint
        chart.axisStyle = range.isIntraday ? .time : .date
        chart.samples = points.map { PortfolioChartView.Sample(date: $0.time, value: $0.value) }

        // Benchmark, when enough points line up to be honest about it. Intraday
        // reads the index's own minute bars; longer ranges use daily closes.
        if w.config.compareToBenchmark {
            let rebased = range.isIntraday
                ? w.intradayBenchmarkSeries(matching: points.map(\.time),
                                            startingAt: values.first ?? 0)
                : BenchmarkSeries.shared.rebased(to: points.map(\.time),
                                                 startingAt: values.first ?? 0)
            if let rebased {
                chart.benchmark = rebased.map { PortfolioChartView.Sample(date: $0.date, value: $0.value) }
            }
        }
        card.addSubview(chart)

        addHistoryFooter(to: card, cw: cw, portfolioID: active.id, range: range,
                         points: points, chart: chart, widget: w,
                         intradayCount: range.isIntraday ? points.count : nil)

        y += cardH + 6
    }

    /// 1W / 1M / 3M / 6M / ALL.
    private func addHistoryRangePicker(to card: NSView, cardH: CGFloat, cw: CGFloat,
                                       selected: PortfolioHistoryService.Range) {
        let ranges = PortfolioHistoryService.Range.allCases
        let segW: CGFloat = 32
        let gap: CGFloat = 2
        let trackW = segW * CGFloat(ranges.count) + gap * CGFloat(ranges.count + 1)
        let track = NSView(frame: NSRect(x: cw - 4 - trackW, y: cardH - 22, width: trackW, height: 18))
        track.wantsLayer = true; track.layer?.cornerRadius = 6
        track.layer?.backgroundColor = Theme.sunkenBg.cgColor
        card.addSubview(track)

        for (i, r) in ranges.enumerated() {
            let x = gap + CGFloat(i) * (segW + gap)
            let isActive = r == selected
            if isActive {
                let pill = NSView(frame: NSRect(x: x, y: 2, width: segW, height: 14))
                pill.wantsLayer = true; pill.layer?.cornerRadius = 4
                pill.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.2).cgColor
                track.addSubview(pill)
            }
            let btn = NSButton(frame: NSRect(x: x, y: 1, width: segW, height: 16))
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: r.label, attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Theme.brandAmber : Theme.textMuted
            ])
            btn.target = self; btn.action = #selector(historyRangeChanged(_:))
            btn.tag = i
            track.addSubview(btn)
        }
    }

    /// Best and worst day in the range, plus the benchmark toggle.
    private func addHistoryFooter(to card: NSView, cw: CGFloat, portfolioID: String,
                                  range: PortfolioHistoryService.Range,
                                  points: [PortfolioHistoryService.Point],
                                  chart: PortfolioChartView,
                                  widget w: StockTickerWidget,
                                  intradayCount: Int?) {
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"

        var parts: [(String, NSColor)] = []
        if let intradayCount {
            // Day-over-day extremes mean nothing inside a single session.
            let tf = DateFormatter(); tf.dateFormat = "h:mm a"
            if let first = points.first?.time, let last = points.last?.time {
                parts.append(("\(tf.string(from: first)) - \(tf.string(from: last))", Theme.textGhost))
            }
            parts.append(("\(intradayCount) samples", Theme.textGhost))
        } else if let moves = PortfolioHistoryService.shared.extremeMoves(for: portfolioID, range: range) {
            parts.append((String(format: "Best %@ %+.1f%%", fmt.string(from: moves.best.day), moves.best.pct),
                          Theme.green.withAlphaComponent(0.8)))
            parts.append((String(format: "Worst %@ %+.1f%%", fmt.string(from: moves.worst.day), moves.worst.pct),
                          Theme.red.withAlphaComponent(0.8)))
        }
        if intradayCount == nil { parts.append(("\(points.count) days", Theme.textGhost)) }

        let line = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 {
                line.append(NSAttributedString(string: "   ", attributes: [
                    .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: Theme.textGhost]))
            }
            line.append(NSAttributedString(string: part.0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: part.1]))
        }
        let stats = NSTextField(labelWithAttributedString: line)
        stats.lineBreakMode = .byTruncatingTail
        stats.frame = NSRect(x: 12, y: 9, width: cw - 108, height: 12)
        card.addSubview(stats)

        // Benchmark toggle. Disabled with an explanation when the data isn't usable.
        let on = w.config.compareToBenchmark
        let available = chart.benchmark != nil
        let btn = NSButton(frame: NSRect(x: cw - 94, y: 6, width: 90, height: 17))
        btn.isBordered = false; btn.wantsLayer = true
        btn.layer?.cornerRadius = 5
        btn.layer?.backgroundColor = (on && available ? Theme.brandCyan.withAlphaComponent(0.14)
                                                      : NSColor.clear).cgColor
        btn.layer?.borderWidth = 0.5
        btn.layer?.borderColor = (on && available ? Theme.brandCyan.withAlphaComponent(0.3)
                                                  : Theme.cardBorder).cgColor
        let title = on && !available ? "SPY unavailable" : "vs SPY"
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: on && available ? Theme.brandCyan
                            : (on ? Theme.textGhost : Theme.textMuted)
        ])
        btn.toolTip = available || !on
            ? "Overlay SPY, rebased to this portfolio's starting value"
            : "Not enough overlapping SPY data for this range yet"
        btn.target = self; btn.action = #selector(benchmarkToggled)
        card.addSubview(btn)
    }

    @objc private func historyRangeChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        let ranges = PortfolioHistoryService.Range.allCases
        guard ranges.indices.contains(sender.tag) else { return }
        w.config.historyRange = ranges[sender.tag]
        w.saveConfig()
        rebuildContent()
    }

    @objc private func benchmarkToggled() {
        guard let w = widget else { return }
        w.config.compareToBenchmark.toggle()
        w.saveConfig()
        if w.config.compareToBenchmark {
            BenchmarkSeries.shared.refreshIfNeeded { [weak self] in self?.rebuildContent() }
        }
        rebuildContent()
    }


    // MARK: - Allocation

    /// Weight of each position in the portfolio, largest first, with a flag when
    /// any single name dominates. Everything here comes off the existing snapshot.
    private func addAllocationCard(_ pv: PortfolioSnapshot, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let ranked = pv.positions.sorted { $0.value > $1.value }
        let cashSlice = pv.cash > 0
        let rowCount = ranked.count + (cashSlice ? 1 : 0)
        guard rowCount >= 2 else { return }   // a single slice is always 100%

        let collapsed = widget?.config.allocationCollapsed ?? false
        let concentrated = ranked.first.map { pv.weight(of: $0) > Self.concentrationLimit } ?? false
        let rowH: CGFloat = 15
        let cardH = collapsed ? 30 : (30 + CGFloat(rowCount) * rowH + (concentrated ? 15 : 0) + 8)

        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: cardH))
        card.wantsLayer = true; card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5; card.layer?.borderColor = Theme.cardBorder.cgColor
        docView.addSubview(card)

        // Collapsed summary: the largest slice, flagged if it's oversized.
        var headerSummary: NSAttributedString?
        if collapsed, let top = ranked.first {
            let weight = pv.weight(of: top)
            headerSummary = NSAttributedString(
                string: String(format: "%@ %.0f%% top of %d", top.quote.symbol, weight, rowCount),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                             .foregroundColor: concentrated ? Theme.red.withAlphaComponent(0.8)
                                                            : Theme.textMuted])
        }

        addCollapsibleHeader(to: card, title: "ALLOCATION", cardH: cardH, cw: cw,
                             collapsed: collapsed, summary: headerSummary,
                             action: #selector(allocationCollapseToggled))

        guard !collapsed else {
            y += cardH + 6
            return
        }

        let barX: CGFloat = 68
        let pctX = cw - 74
        let barW = pctX - 8 - barX

        // Slices are drawn relative to the largest one so small positions stay visible.
        let maxWeight = max(
            ranked.first.map { pv.weight(of: $0) } ?? 0,
            cashSlice && pv.total > 0 ? pv.cash / pv.total * 100 : 0
        )

        func addRow(label: String, weight: Double, color: NSColor, index: Int) {
            let rowY = cardH - 30 - CGFloat(index + 1) * rowH + 3

            let name = NSTextField(labelWithString: label)
            name.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
            name.textColor = Theme.textSecondary
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 12, y: rowY, width: 52, height: 11)
            card.addSubview(name)

            let track = NSView(frame: NSRect(x: barX, y: rowY + 2, width: barW, height: 6))
            track.wantsLayer = true; track.layer?.cornerRadius = 3
            track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            card.addSubview(track)

            let frac = maxWeight > 0 ? min(max(weight / maxWeight, 0), 1) : 0
            let fillW = max(frac * barW, weight > 0 ? 3 : 0)
            let fill = NSView(frame: NSRect(x: barX, y: rowY + 2, width: fillW, height: 6))
            fill.wantsLayer = true; fill.layer?.cornerRadius = 3
            fill.layer?.backgroundColor = color.cgColor
            card.addSubview(fill)

            let pct = NSTextField(labelWithString: String(format: "%.0f%%", weight))
            pct.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            pct.textColor = Theme.textMuted
            pct.alignment = .right
            pct.frame = NSRect(x: pctX, y: rowY, width: 70, height: 11)
            card.addSubview(pct)
        }

        for (i, position) in ranked.enumerated() {
            let weight = pv.weight(of: position)
            let tooBig = weight > Self.concentrationLimit
            addRow(label: position.quote.symbol,
                   weight: weight,
                   color: tooBig ? Theme.red.withAlphaComponent(0.65)
                                 : Theme.brandAmber.withAlphaComponent(0.55),
                   index: i)
        }

        if cashSlice {
            addRow(label: "Cash",
                   weight: pv.total > 0 ? pv.cash / pv.total * 100 : 0,
                   color: Theme.brandCyan.withAlphaComponent(0.45),
                   index: ranked.count)
        }

        if concentrated, let top = ranked.first {
            let warn = NSTextField(labelWithString: String(format: "%@ is %.0f%% of this portfolio",
                                                           top.quote.symbol, pv.weight(of: top)))
            warn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            warn.textColor = Theme.red.withAlphaComponent(0.75)
            warn.lineBreakMode = .byTruncatingTail
            warn.frame = NSRect(x: 12, y: 7, width: cw - 20, height: 11)
            card.addSubview(warn)
        }

        y += cardH + 6
    }

    /// A single position above this share of the portfolio gets flagged.
    private static let concentrationLimit: Double = 40

    /// Sets uninvested cash on the active portfolio; also displays the current amount.
    private func addCashButton(to card: NSView, cash: Double, atY cashY: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }
        let cashStr = cash > 0 ? "Cash \(w.formatCurrency(cash))" : "+ cash"
        let cashBtn = NSButton(frame: NSRect(x: cw - 94, y: cashY, width: 90, height: 16))
        cashBtn.isBordered = false; cashBtn.wantsLayer = true
        cashBtn.layer?.cornerRadius = 5
        cashBtn.layer?.backgroundColor = (cash > 0 ? Theme.brandAmber.withAlphaComponent(0.12) : NSColor.clear).cgColor
        cashBtn.attributedTitle = NSAttributedString(string: cashStr, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: cash > 0 ? Theme.brandAmber : Theme.textGhost
        ])
        cashBtn.target = self; cashBtn.action = #selector(cashClicked(_:))
        card.addSubview(cashBtn)
    }

    // MARK: - Portfolio Tabs

    /// Segmented strip of portfolio names plus an add button, styled like the
    /// Display/Sort segments in Settings. Clicking the active tab opens rename/delete.
    private func addPortfolioTabs(to card: NSView, cardW: CGFloat, atY tabY: CGFloat) {
        guard let w = widget else { return }
        let portfolios = w.config.portfolios
        guard !portfolios.isEmpty else { return }

        let trackX: CGFloat = 10
        let plusSize: CGFloat = 20
        let plusX = cardW - 12 - plusSize
        let availableW = plusX - 8 - trackX

        // Cap the tab width so one or two portfolios don't stretch into a full-width
        // bar, then shrink the rail to whatever the tabs actually use.
        let gap: CGFloat = 2
        let maxTabW: CGFloat = 110
        let evenW = (availableW - gap * CGFloat(portfolios.count + 1)) / CGFloat(portfolios.count)
        let tabW = min(evenW, maxTabW)
        let trackW = gap + CGFloat(portfolios.count) * (tabW + gap)

        let track = NSView(frame: NSRect(x: trackX, y: tabY, width: trackW, height: 22))
        track.wantsLayer = true; track.layer?.cornerRadius = 8
        track.layer?.backgroundColor = Theme.sunkenBg.cgColor
        card.addSubview(track)

        let clip = NSMutableParagraphStyle()
        clip.lineBreakMode = .byTruncatingTail
        clip.alignment = .center

        for (i, p) in portfolios.enumerated() {
            let x = gap + CGFloat(i) * (tabW + gap)
            let isActive = p.id == w.config.activePortfolioID

            if isActive {
                let pill = NSView(frame: NSRect(x: x, y: 3, width: tabW, height: 16))
                pill.wantsLayer = true; pill.layer?.cornerRadius = 6
                pill.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.2).cgColor
                pill.layer?.borderWidth = 0.5
                pill.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
                track.addSubview(pill)
            }

            let btn = NSButton(frame: NSRect(x: x, y: 2, width: tabW, height: 18))
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: p.name, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Theme.brandAmber : Theme.textMuted,
                .paragraphStyle: clip
            ])
            btn.toolTip = isActive ? "\(p.name) - click again to rename or delete" : "Switch to \(p.name)"
            btn.target = self; btn.action = #selector(portfolioTabClicked(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(p.id)
            track.addSubview(btn)
        }

        let canAdd = w.canAddPortfolio
        let plus = NSButton(frame: NSRect(x: plusX, y: tabY + 1, width: plusSize, height: plusSize))
        plus.isBordered = false; plus.title = ""
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add portfolio")
        plus.contentTintColor = canAdd ? Theme.brandAmber.withAlphaComponent(0.8) : Theme.textGhost
        plus.isEnabled = canAdd
        plus.toolTip = canAdd ? "New portfolio" : "Limit of \(Portfolio.maxCount) portfolios reached"
        plus.target = self; plus.action = #selector(addPortfolioClicked(_:))
        card.addSubview(plus)
    }

    // MARK: - Section Header

    private func addSectionHeader(_ title: String, count: Int, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        let titleW = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)

        let l = NSTextField(labelWithString: title)
        l.font = titleFont
        l.textColor = Theme.textFaint
        l.frame = NSRect(x: pad, y: y, width: titleW + 2, height: 14)
        docView.addSubview(l)

        let pillW: CGFloat = 26
        let pillX = pad + titleW + 8
        let countPill = NSView(frame: NSRect(x: pillX, y: y - 1, width: pillW, height: 16))
        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = 8
        countPill.layer?.backgroundColor = Theme.textGhost.withAlphaComponent(0.12).cgColor
        docView.addSubview(countPill)

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        countLabel.textColor = Theme.textFaint
        countLabel.alignment = .center
        countLabel.frame = NSRect(x: 0, y: 3, width: pillW, height: 10)
        countPill.addSubview(countLabel)

        let ruleX = pillX + pillW + 10
        let rule = NSView(frame: NSRect(x: ruleX, y: y + 6, width: pad + cw - ruleX, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.divider.cgColor
        docView.addSubview(rule)

        y += 20
    }

    // MARK: - Quote Row

    private func addQuoteRow(_ q: MarketQuote, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }
        let hasExt = q.extendedHours != nil
        let hasExtraData = q.openPrice != nil || (w.config.showMarketCap && q.marketCap != nil) || q.fiftyTwoWeekHigh != nil || (w.config.showPERatio && q.peRatio != nil)
        let hasAlert = w.config.priceAlerts[q.symbol] != nil
        let hasHolding = (w.config.holdings[q.symbol] ?? 0) > 0
        let hasCostBasis = hasHolding && (w.config.costBasis[q.symbol] ?? 0) > 0
        let earningsEvent: EarningsCalendarService.Event? = q.kind == .stock
            ? EarningsCalendarService.shared.event(for: q.symbol)
            : nil
        let hasTopMeta = hasAlert || hasHolding
        let chartData = q.chartSeries
        let chartEnabled = w.config.showSparklines && chartData.count >= 2
        var cardH: CGFloat = 64
        if hasTopMeta { cardH += 14 }
        if hasCostBasis { cardH += 11 }
        if earningsEvent != nil { cardH += 13 }
        if hasExt { cardH += 18 }
        if hasExtraData { cardH += 14 }

        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: cardH))
        card.wantsLayer = true; card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Theme.cardBorder.cgColor
        docView.addSubview(card)

        let topY = cardH - 22
        let metaY = topY - 15

        // X button
        let xBtn = NSButton(frame: NSRect(x: cw - 20, y: topY + 1, width: 16, height: 16))
        xBtn.isBordered = false; xBtn.title = ""
        xBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
        xBtn.contentTintColor = Theme.textFaint
        xBtn.target = self; xBtn.action = #selector(removeClicked(_:))
        xBtn.identifier = NSUserInterfaceItemIdentifier("\(q.kind.rawValue):\(q.symbol)")
        card.addSubview(xBtn)

        // Open in browser button
        let webBtn = NSButton(frame: NSRect(x: cw - 42, y: topY + 1, width: 16, height: 16))
        webBtn.isBordered = false; webBtn.title = ""
        webBtn.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open in browser")
        webBtn.contentTintColor = Theme.textFaint
        webBtn.target = self; webBtn.action = #selector(openInBrowserClicked(_:))
        webBtn.identifier = NSUserInterfaceItemIdentifier("web:\(q.kind.rawValue):\(q.symbol)")
        card.addSubview(webBtn)

        // Holdings button
        let holdingQty = w.config.holdings[q.symbol] ?? 0
        let holdingStr = holdingQty > 0 ? String(format: "%.4g sh", holdingQty) : "+sh"
        let holdBtn = NSButton(frame: NSRect(x: cw - 94, y: topY + 2, width: 46, height: 15))
        holdBtn.isBordered = false; holdBtn.wantsLayer = true
        holdBtn.layer?.cornerRadius = 5
        holdBtn.layer?.backgroundColor = (holdingQty > 0 ? Theme.brandAmber.withAlphaComponent(0.12) : NSColor.clear).cgColor
        holdBtn.attributedTitle = NSAttributedString(string: holdingStr, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: holdingQty > 0 ? Theme.brandAmber : Theme.textGhost
        ])
        holdBtn.target = self; holdBtn.action = #selector(holdingsClicked(_:))
        holdBtn.identifier = NSUserInterfaceItemIdentifier("hold:\(q.kind.rawValue):\(q.symbol)")
        card.addSubview(holdBtn)

        // Symbol
        let sym = NSTextField(labelWithString: q.symbol)
        sym.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold); sym.textColor = Theme.textPrimary
        sym.lineBreakMode = .byTruncatingTail
        sym.frame = NSRect(x: 12, y: topY, width: 66, height: 19)
        card.addSubview(sym)

        // Kind badge
        let kind = NSTextField(labelWithString: q.extendedHours?.label.uppercased() ?? (q.kind == .stock ? "STOCK" : "CRYPTO"))
        kind.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        kind.textColor = (q.extendedHours != nil ? Theme.brandAmber : (q.kind == .stock ? Theme.blue : Theme.brandAmber)).withAlphaComponent(0.6)
        kind.frame = NSRect(x: 12, y: metaY, width: 54, height: 10)
        card.addSubview(kind)


        if chartEnabled {
            let img = SparklineRenderer.render(
                data: chartData,
                width: 92,
                style: w.chartStyle(for: q, height: 24, pointRadius: 1.1, showGrid: false)
            )
            let iv = NSImageView(frame: NSRect(x: 84, y: metaY - 4, width: 92, height: 24))
            iv.image = img
            card.addSubview(iv)
        }

        // Price
        let pl = NSTextField(labelWithString: "$" + w.formatPrice(q.currentPrice))
        pl.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold); pl.textColor = Theme.textPrimary
        pl.alignment = .right; pl.frame = NSRect(x: cw - 190, y: topY, width: 88, height: 18)
        card.addSubview(pl)

        // Change
        let cl = NSTextField(labelWithString: String(format: "%@ %@%.2f%%", q.currentIsUp ? "\u{25B2}" : "\u{25BC}", q.currentIsUp ? "+" : "", q.currentChange))
        cl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        cl.textColor = w.intensityColor(for: q.currentChange); cl.alignment = .right
        cl.frame = NSRect(x: cw - 190, y: metaY - 2, width: 88, height: 14)
        card.addSubview(cl)

        var nextLineY = metaY - 16

        // Upcoming earnings, on its own line so it can never collide with the
        // sparkline or the change column. Warms to amber inside a week.
        if let event = earningsEvent {
            let imminent = event.daysAway <= 7
            let tint = imminent ? Theme.brandAmber : Theme.textFaint
            var text = "ERN \(event.shortLabel)"
            if let session = event.sessionLabel { text += " \(session)" }

            let badgeW: CGFloat = 68
            let badge = NSView(frame: NSRect(x: 12, y: nextLineY, width: badgeW, height: 12))
            badge.wantsLayer = true; badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = tint.withAlphaComponent(imminent ? 0.14 : 0.06).cgColor
            badge.layer?.borderWidth = 0.5
            badge.layer?.borderColor = tint.withAlphaComponent(imminent ? 0.35 : 0.14).cgColor
            card.addSubview(badge)

            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            label.textColor = tint.withAlphaComponent(imminent ? 0.95 : 0.6)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 0, y: 1, width: badgeW, height: 10)
            badge.addSubview(label)

            if let forecast = event.epsForecast {
                let est = NSTextField(labelWithString: "est \(forecast)")
                est.font = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .regular)
                est.textColor = Theme.textGhost
                est.frame = NSRect(x: 12 + badgeW + 6, y: nextLineY + 1, width: 90, height: 10)
                card.addSubview(est)
            }

            nextLineY -= 13
        }

        if let alertTarget = w.config.priceAlerts[q.symbol] {
            let alertLabel = NSTextField(labelWithString: "Alert $" + w.formatPrice(alertTarget))
            alertLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
            alertLabel.textColor = Theme.brandCyan.withAlphaComponent(0.76)
            alertLabel.lineBreakMode = .byTruncatingTail
            alertLabel.frame = NSRect(x: 12, y: nextLineY + 1, width: 102, height: 10)
            card.addSubview(alertLabel)
        }

        if let qty = w.config.holdings[q.symbol], qty > 0 {
            let value = q.currentPrice * qty
            let dailyPL = q.currentValueChange(for: qty)
            let holdStr = String(format: "%.1f sh  %@  %@",
                                 qty,
                                 w.formatCurrency(value),
                                 w.formatSignedCurrency(dailyPL))
            let holdLabel = NSTextField(labelWithString: holdStr)
            holdLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
            holdLabel.textColor = Theme.brandAmber.withAlphaComponent(0.74)
            holdLabel.alignment = .right
            holdLabel.lineBreakMode = .byTruncatingTail
            holdLabel.frame = NSRect(x: 124, y: nextLineY, width: cw - 226, height: 11)
            card.addSubview(holdLabel)

            // Total return since purchase, shown only when a cost is on record.
            if let avg = w.config.costBasis[q.symbol], avg > 0 {
                let cost = avg * qty
                let totalPL = value - cost
                let totalPct = cost > 0 ? totalPL / cost * 100 : 0
                let totalStr = String(format: "@%@  %@ (%@%.1f%%)",
                                      w.formatPrice(avg),
                                      w.formatSignedCurrency(totalPL),
                                      totalPct >= 0 ? "+" : "",
                                      totalPct)
                let totalLabel = NSTextField(labelWithString: totalStr)
                totalLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
                totalLabel.textColor = w.intensityColor(for: totalPct).withAlphaComponent(0.85)
                totalLabel.alignment = .right
                totalLabel.lineBreakMode = .byTruncatingTail
                totalLabel.frame = NSRect(x: 124, y: nextLineY - 11, width: cw - 226, height: 11)
                card.addSubview(totalLabel)
                nextLineY -= 11
            }
        }

        // Extended hours
        if hasTopMeta { nextLineY -= 14 }
        if let ext = q.extendedHours {
            let extUp = ext.change >= 0
            let extColor = w.intensityColor(for: ext.change).withAlphaComponent(0.8)
            let labelColor = Theme.brandAmber.withAlphaComponent(0.7)

            let badge = NSTextField(labelWithString: ext.label)
            badge.font = NSFont.systemFont(ofSize: 8, weight: .bold); badge.textColor = labelColor
            badge.frame = NSRect(x: 12, y: nextLineY + 1, width: 26, height: 10)
            card.addSubview(badge)

            let ep = NSTextField(labelWithString: "$" + w.formatPrice(ext.price))
            ep.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium); ep.textColor = extColor
            ep.frame = NSRect(x: 42, y: nextLineY - 1, width: 96, height: 14)
            card.addSubview(ep)

            let arrow = extUp ? "\u{25B2}" : "\u{25BC}"
            let sign = extUp ? "+" : ""
            let ec = NSTextField(labelWithString: String(format: "%@ %@%.2f%%", arrow, sign, ext.change))
            ec.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            ec.textColor = extColor; ec.alignment = .right
            ec.frame = NSRect(x: cw - 190, y: nextLineY - 1, width: 88, height: 14)
            card.addSubview(ec)
            nextLineY -= 16
        }

        // Extra data line
        if hasExtraData {
            var parts: [String] = []
            if let op = q.openPrice { parts.append("O:\(w.formatPrice(op))") }
            if w.config.showMarketCap, let mc = q.marketCap { parts.append("Cap:\(StockTickerWidget.compactNumber(mc))") }
            if let h = q.fiftyTwoWeekHigh, let l = q.fiftyTwoWeekLow {
                parts.append("52W:\(w.formatPrice(l))-\(w.formatPrice(h))")
            }
            if w.config.showPERatio, let pe = q.peRatio {
                parts.append("P/E:\(String(format: "%.1f", pe))")
            }
            let extraStr = parts.joined(separator: "  ")
            let extra = NSTextField(labelWithString: extraStr)
            extra.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
            extra.textColor = Theme.textFaint
            extra.lineBreakMode = .byTruncatingTail
            extra.frame = NSRect(x: 12, y: nextLineY - 1, width: cw - 16, height: 10)
            card.addSubview(extra)
            nextLineY -= 14
        }

        // Day range bar
        if w.config.showDayRange, let h = q.dayHigh, let l = q.dayLow, h > l {
            let rangeY: CGFloat = 6
            let bw = cw - 16
            let bg = NSView(frame: NSRect(x: 12, y: rangeY, width: bw, height: 4))
            bg.wantsLayer = true; bg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor; bg.layer?.cornerRadius = 2
            card.addSubview(bg)
            let pct = min(max((q.currentPrice - l) / (h - l), 0), 1)
            let mx = 12 + CGFloat(pct) * (bw - 6)
            let marker = NSView(frame: NSRect(x: mx, y: 5, width: 6, height: 6))
            marker.wantsLayer = true; marker.layer?.backgroundColor = w.intensityColor(for: q.currentChange).cgColor
            marker.layer?.cornerRadius = 3; marker.layer?.shadowColor = w.intensityColor(for: q.currentChange).cgColor
            marker.layer?.shadowRadius = 3; marker.layer?.shadowOpacity = 0.6; marker.layer?.shadowOffset = .zero
            card.addSubview(marker)

            let ll = NSTextField(labelWithString: "L:\(w.formatPrice(l))")
            ll.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular); ll.textColor = Theme.textFaint
            ll.frame = NSRect(x: 12, y: rangeY + 6, width: 64, height: 10)
            card.addSubview(ll)

            if w.config.showVolume, let v = q.volume {
                let volLabel = NSTextField(labelWithString: "Vol:\(StockTickerWidget.compactNumber(v))")
                volLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular); volLabel.textColor = Theme.textFaint
                volLabel.alignment = .center; volLabel.frame = NSRect(x: cw / 2 - 42, y: rangeY + 6, width: 84, height: 10)
                card.addSubview(volLabel)
            }

            let hl = NSTextField(labelWithString: "H:\(w.formatPrice(h))")
            hl.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular); hl.textColor = Theme.textFaint
            hl.alignment = .right; hl.frame = NSRect(x: cw - 74, y: rangeY + 6, width: 70, height: 10)
            card.addSubview(hl)
        }

        let selectBtn = NSButton(frame: NSRect(x: 0, y: 0, width: cw - 88, height: cardH))
        selectBtn.isBordered = false
        selectBtn.isTransparent = true
        selectBtn.target = self
        selectBtn.action = #selector(showQuoteDetail(_:))
        selectBtn.identifier = NSUserInterfaceItemIdentifier("detail:\(q.kind.rawValue):\(q.symbol)")
        card.addSubview(selectBtn)

        y += cardH + 6
    }

    // MARK: - Failed Row

    private func addFailedRow(_ symbol: String, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: 36))
        card.wantsLayer = true; card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.redBg.cgColor
        card.layer?.borderWidth = 0.5; card.layer?.borderColor = Theme.red.withAlphaComponent(0.2).cgColor
        docView.addSubview(card)

        let warnIcon = NSImageView(frame: NSRect(x: 10, y: 10, width: 14, height: 14))
        warnIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
        warnIcon.contentTintColor = Theme.red.withAlphaComponent(0.7)
        card.addSubview(warnIcon)

        let sym = NSTextField(labelWithString: symbol)
        sym.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold); sym.textColor = Theme.red.withAlphaComponent(0.8)
        sym.frame = NSRect(x: 30, y: 10, width: 60, height: 16)
        card.addSubview(sym)

        let errLabel = NSTextField(labelWithString: "Could not load quote")
        errLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular); errLabel.textColor = Theme.red.withAlphaComponent(0.6)
        errLabel.frame = NSRect(x: 95, y: 11, width: 130, height: 14)
        card.addSubview(errLabel)

        let xBtn = NSButton(frame: NSRect(x: cw - 20, y: 10, width: 16, height: 16))
        xBtn.isBordered = false; xBtn.title = ""
        xBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
        xBtn.contentTintColor = Theme.red.withAlphaComponent(0.5); xBtn.target = self; xBtn.action = #selector(removeClicked(_:))
        xBtn.identifier = NSUserInterfaceItemIdentifier("stock:\(symbol)")
        card.addSubview(xBtn)

        y += 40
    }

    // MARK: - Pending Row

    private func addPendingRow(_ symbol: String, kind: MarketQuote.Kind, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: 36))
        card.wantsLayer = true; card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        docView.addSubview(card)

        let sym = NSTextField(labelWithString: symbol)
        sym.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold); sym.textColor = Theme.textMuted
        sym.frame = NSRect(x: 10, y: 10, width: 60, height: 16)
        card.addSubview(sym)

        let loading = NSTextField(labelWithString: "Loading...")
        loading.font = NSFont.systemFont(ofSize: 11, weight: .regular); loading.textColor = Theme.textFaint
        loading.frame = NSRect(x: 80, y: 10, width: 100, height: 16)
        card.addSubview(loading)

        let xBtn = NSButton(frame: NSRect(x: cw - 20, y: 10, width: 16, height: 16))
        xBtn.isBordered = false; xBtn.title = ""
        xBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")
        xBtn.contentTintColor = Theme.textFaint; xBtn.target = self; xBtn.action = #selector(removeClicked(_:))
        xBtn.identifier = NSUserInterfaceItemIdentifier("\(kind.rawValue):\(symbol)")
        card.addSubview(xBtn)

        y += 40
    }

    // MARK: - Avg Line

    private func addAvgLine(_ avg: Double, label: String, y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }
        let pill = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: 24))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.backgroundColor = w.intensityColor(for: avg).withAlphaComponent(0.06).cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = w.intensityColor(for: avg).withAlphaComponent(0.14).cgColor
        docView.addSubview(pill)

        let name = NSTextField(labelWithString: label)
        name.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        name.textColor = Theme.textFaint
        name.frame = NSRect(x: 10, y: 6, width: 120, height: 12)
        pill.addSubview(name)

        let l = NSTextField(labelWithString: "\(avg >= 0 ? "+" : "")\(String(format: "%.2f%%", avg))")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        l.textColor = w.intensityColor(for: avg)
        l.alignment = .right
        l.frame = NSRect(x: cw - 116, y: 5, width: 112, height: 14)
        pill.addSubview(l)
        y += 30
    }

    // MARK: - Add Symbol Field

    private func addAddField(y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let card = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: 38))
        card.wantsLayer = true; card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5; card.layer?.borderColor = Theme.cardBorder.cgColor
        docView.addSubview(card)

        let icon = NSImageView(frame: NSRect(x: 12, y: 10, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Add")
        icon.contentTintColor = Theme.textFaint
        card.addSubview(icon)

        let field = NSTextField(frame: NSRect(x: 34, y: 6, width: cw - 34, height: 26))
        field.font = NSFont.systemFont(ofSize: 13, weight: .regular); field.textColor = Theme.textPrimary
        field.backgroundColor = .clear; field.drawsBackground = false
        field.isBordered = false; field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: "Add symbol (AAPL, BTC, ETH...)",
            attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .regular), .foregroundColor: Theme.textFaint])
        field.delegate = self
        card.addSubview(field)

        y += 46
    }

    // MARK: - Inline Settings

    private func addSettings(y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }

        let settingsCard = FlippedView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: 0))
        settingsCard.wantsLayer = true; settingsCard.layer?.cornerRadius = 10
        settingsCard.layer?.backgroundColor = Theme.cardBg.cgColor
        settingsCard.layer?.borderWidth = 0.5; settingsCard.layer?.borderColor = Theme.cardBorder.cgColor
        docView.addSubview(settingsCard)

        let inset: CGFloat = 12
        let innerW = cw + 8 - inset * 2
        var iy: CGFloat = 12

        // Header
        let gearIcon = NSImageView(frame: NSRect(x: inset, y: iy, width: 12, height: 12))
        gearIcon.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")
        gearIcon.contentTintColor = Theme.textFaint
        settingsCard.addSubview(gearIcon)

        let hdr = Theme.sectionHeader("SETTINGS")
        hdr.frame = NSRect(x: inset + 18, y: iy - 1, width: innerW - 18, height: 14)
        settingsCard.addSubview(hdr)
        iy += 20

        let hDiv = NSView(frame: NSRect(x: inset, y: iy, width: innerW, height: 1))
        hDiv.wantsLayer = true; hDiv.layer?.backgroundColor = Theme.divider.cgColor
        settingsCard.addSubview(hDiv)
        iy += 8

        // Display Mode
        let modeLabel = NSTextField(labelWithString: "Display")
        modeLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); modeLabel.textColor = Theme.textMuted
        modeLabel.frame = NSRect(x: inset, y: iy, width: 50, height: 14)
        settingsCard.addSubview(modeLabel)
        iy += 16

        let segTrack = NSView(frame: NSRect(x: inset, y: iy, width: innerW, height: 28))
        segTrack.wantsLayer = true; segTrack.layer?.cornerRadius = 8
        segTrack.layer?.backgroundColor = Theme.sunkenBg.cgColor
        settingsCard.addSubview(segTrack)

        let modes: [(String, TickerDisplayMode)] = [("Scroll", .scrolling), ("Focus", .focused), ("Mini", .compact), ("Chart", .sparkline), ("Folio", .portfolio)]
        let segGap: CGFloat = 2
        let segW = (innerW - segGap * CGFloat(modes.count + 1)) / CGFloat(modes.count)
        for (i, (title, mode)) in modes.enumerated() {
            let x = segGap + CGFloat(i) * (segW + segGap)
            let isActive = w.config.displayMode == mode
            let pill = NSView(frame: NSRect(x: x, y: 3, width: segW, height: 22))
            pill.wantsLayer = true; pill.layer?.cornerRadius = 6
            if isActive {
                pill.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.2).cgColor
                pill.layer?.borderWidth = 0.5; pill.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
            }
            segTrack.addSubview(pill)
            let btn = NSButton(frame: NSRect(x: x, y: 3, width: segW, height: 22))
            btn.isBordered = false; btn.wantsLayer = true
            btn.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Theme.brandAmber : Theme.textMuted
            ])
            btn.target = self; btn.action = #selector(displayModeChanged(_:)); btn.tag = i
            segTrack.addSubview(btn)
        }
        iy += 34

        // Sort Mode
        let sortLabel = NSTextField(labelWithString: "Sort")
        sortLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); sortLabel.textColor = Theme.textMuted
        sortLabel.frame = NSRect(x: inset, y: iy, width: 30, height: 14)
        settingsCard.addSubview(sortLabel)
        iy += 16

        let sortTrack = NSView(frame: NSRect(x: inset, y: iy, width: innerW, height: 26))
        sortTrack.wantsLayer = true; sortTrack.layer?.cornerRadius = 7
        sortTrack.layer?.backgroundColor = Theme.sunkenBg.cgColor
        settingsCard.addSubview(sortTrack)

        let sorts: [(String, TickerSortMode)] = [("Manual", .manual), ("A-Z", .alphabetical), ("Best", .changeDesc), ("Worst", .changeAsc), ("Price", .priceDesc)]
        let sortGap: CGFloat = 2
        let sortW = (innerW - sortGap * CGFloat(sorts.count + 1)) / CGFloat(sorts.count)
        for (i, (title, mode)) in sorts.enumerated() {
            let x = sortGap + CGFloat(i) * (sortW + sortGap)
            let isActive = w.config.sortMode == mode
            if isActive {
                let pill = NSView(frame: NSRect(x: x, y: 3, width: sortW, height: 20))
                pill.wantsLayer = true; pill.layer?.cornerRadius = 5
                pill.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.2).cgColor
                pill.layer?.borderWidth = 0.5; pill.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
                sortTrack.addSubview(pill)
            }
            let btn = NSButton(frame: NSRect(x: x, y: 3, width: sortW, height: 20))
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Theme.brandAmber : Theme.textMuted
            ])
            btn.target = self; btn.action = #selector(sortModeChanged(_:)); btn.tag = i
            sortTrack.addSubview(btn)
        }
        iy += 32

        // Toggle pills
        let toggles: [(String, String, Bool, Int)] = [
            ("paintbrush", "Colors", w.config.coloredTicker, 0),
            ("chart.xyaxis.line", "Sparklines", w.config.showSparklines, 1),
            ("chart.bar", "Volume", w.config.showVolume, 2),
            ("list.number", "Indices", w.config.showIndices, 3),
            ("clock.badge.fill", "AH/PM", w.config.showExtendedHours, 4),
            ("building.columns", "Mkt Cap", w.config.showMarketCap, 5),
            ("arrow.up.and.down", "Day Range", w.config.showDayRange, 6),
            ("divide.circle", "P/E", w.config.showPERatio, 7),
        ]
        let pillW = (innerW - 8) / 2
        for (i, (icon, label, isOn, tag)) in toggles.enumerated() {
            let col = i % 2
            let row = i / 2
            let x = inset + CGFloat(col) * (pillW + 8)
            let py = iy + CGFloat(row) * 30

            let pillBg = NSView(frame: NSRect(x: x, y: py, width: pillW, height: 26))
            pillBg.wantsLayer = true; pillBg.layer?.cornerRadius = 7
            pillBg.layer?.backgroundColor = (isOn ? Theme.brandAmber.withAlphaComponent(0.08) : Theme.sunkenBg).cgColor
            pillBg.layer?.borderWidth = 0.5
            pillBg.layer?.borderColor = (isOn ? Theme.brandAmber.withAlphaComponent(0.25) : NSColor.clear).cgColor
            settingsCard.addSubview(pillBg)

            let iconView = NSImageView(frame: NSRect(x: 8, y: 5, width: 14, height: 14))
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)
            iconView.contentTintColor = isOn ? Theme.brandAmber : Theme.textFaint
            pillBg.addSubview(iconView)

            let cb = NSButton(frame: NSRect(x: x, y: py, width: pillW, height: 26))
            cb.isBordered = false; cb.wantsLayer = true
            cb.attributedTitle = NSAttributedString(string: "  \(label)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: isOn ? .medium : .regular),
                .foregroundColor: isOn ? Theme.textPrimary : Theme.textMuted
            ])
            cb.setButtonType(.momentaryLight)
            cb.target = self; cb.action = #selector(toggleChanged(_:)); cb.tag = tag
            settingsCard.addSubview(cb)
        }
        iy += CGFloat((toggles.count + 1) / 2) * 30 + 4

        // Width slider
        let wIcon = NSImageView(frame: NSRect(x: inset, y: iy + 1, width: 12, height: 12))
        wIcon.image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: "Width")
        wIcon.contentTintColor = Theme.textFaint
        settingsCard.addSubview(wIcon)

        let wLabel = NSTextField(labelWithString: "Width")
        wLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); wLabel.textColor = Theme.textMuted
        wLabel.frame = NSRect(x: inset + 16, y: iy, width: 40, height: 14)
        settingsCard.addSubview(wLabel)

        let wValue = NSTextField(labelWithString: "\(Int(w.config.tickerWidth))px")
        wValue.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold); wValue.textColor = Theme.brandAmber
        wValue.alignment = .right
        wValue.frame = NSRect(x: innerW - 30, y: iy, width: 42, height: 14)
        settingsCard.addSubview(wValue)
        iy += 16

        let sliderTrack = NSView(frame: NSRect(x: inset, y: iy + 4, width: innerW, height: 6))
        sliderTrack.wantsLayer = true; sliderTrack.layer?.cornerRadius = 3
        sliderTrack.layer?.backgroundColor = Theme.sunkenBg.cgColor
        settingsCard.addSubview(sliderTrack)

        let slider = NSSlider(value: w.config.tickerWidth, minValue: 80, maxValue: 500, target: self, action: #selector(widthChanged(_:)))
        slider.frame = NSRect(x: inset, y: iy, width: innerW, height: 14)
        slider.isContinuous = true
        settingsCard.addSubview(slider)
        iy += 22

        // Scroll speed slider
        let sIcon = NSImageView(frame: NSRect(x: inset, y: iy + 1, width: 12, height: 12))
        sIcon.image = NSImage(systemSymbolName: "hare", accessibilityDescription: "Speed")
        sIcon.contentTintColor = Theme.textFaint
        settingsCard.addSubview(sIcon)

        let sLabel = NSTextField(labelWithString: "Speed")
        sLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); sLabel.textColor = Theme.textMuted
        sLabel.frame = NSRect(x: inset + 16, y: iy, width: 40, height: 14)
        settingsCard.addSubview(sLabel)

        let sValue = NSTextField(labelWithString: String(format: "%.1fx", w.config.scrollSpeed))
        sValue.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold); sValue.textColor = Theme.brandAmber
        sValue.alignment = .right
        sValue.frame = NSRect(x: innerW - 30, y: iy, width: 42, height: 14)
        settingsCard.addSubview(sValue)
        iy += 16

        let speedSlider = NSSlider(value: w.config.scrollSpeed, minValue: 0.1, maxValue: 2.0, target: self, action: #selector(speedChanged(_:)))
        speedSlider.frame = NSRect(x: inset, y: iy, width: innerW, height: 14)
        speedSlider.isContinuous = true
        settingsCard.addSubview(speedSlider)
        iy += 22

        // Refresh interval
        let rIcon = NSImageView(frame: NSRect(x: inset, y: iy + 1, width: 12, height: 12))
        rIcon.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        rIcon.contentTintColor = Theme.textFaint
        settingsCard.addSubview(rIcon)

        let rLabel = NSTextField(labelWithString: "Refresh")
        rLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); rLabel.textColor = Theme.textMuted
        rLabel.frame = NSRect(x: inset + 16, y: iy, width: 50, height: 14)
        settingsCard.addSubview(rLabel)
        iy += 18

        let rTrack = NSView(frame: NSRect(x: inset, y: iy, width: innerW, height: 26))
        rTrack.wantsLayer = true; rTrack.layer?.cornerRadius = 7
        rTrack.layer?.backgroundColor = Theme.sunkenBg.cgColor
        settingsCard.addSubview(rTrack)

        let intervals: [(String, TimeInterval)] = [("5s", 5), ("10s", 10), ("15s", 15), ("30s", 30)]
        let rGap: CGFloat = 3
        let rW = (innerW - rGap * CGFloat(intervals.count + 1)) / CGFloat(intervals.count)
        for (i, (title, interval)) in intervals.enumerated() {
            let x = rGap + CGFloat(i) * (rW + rGap)
            let isActive = abs(w.config.refreshInterval - interval) < 1
            if isActive {
                let pill = NSView(frame: NSRect(x: x, y: 3, width: rW, height: 20))
                pill.wantsLayer = true; pill.layer?.cornerRadius = 5
                pill.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.2).cgColor
                pill.layer?.borderWidth = 0.5; pill.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
                rTrack.addSubview(pill)
            }
            let btn = NSButton(frame: NSRect(x: x, y: 3, width: rW, height: 20))
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Theme.brandAmber : Theme.textMuted
            ])
            btn.target = self; btn.action = #selector(refreshChanged(_:)); btn.tag = Int(interval)
            rTrack.addSubview(btn)
        }
        iy += 32

        // Color mode
        let cmLabel = NSTextField(labelWithString: "Color")
        cmLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); cmLabel.textColor = Theme.textMuted
        cmLabel.frame = NSRect(x: inset, y: iy, width: 40, height: 14)
        settingsCard.addSubview(cmLabel)
        iy += 16

        let cmTrack = NSView(frame: NSRect(x: inset, y: iy, width: innerW, height: 26))
        cmTrack.wantsLayer = true; cmTrack.layer?.cornerRadius = 7
        cmTrack.layer?.backgroundColor = Theme.sunkenBg.cgColor
        settingsCard.addSubview(cmTrack)

        let colorModes: [(String, TickerColorMode)] = [("Dynamic", .dynamic), ("Fixed", .fixed)]
        let cmGap: CGFloat = 3
        let cmW = (innerW - cmGap * 3) / 2
        for (i, (title, mode)) in colorModes.enumerated() {
            let x = cmGap + CGFloat(i) * (cmW + cmGap)
            let isActive = w.config.colorMode == mode
            if isActive {
                let pill = NSView(frame: NSRect(x: x, y: 3, width: cmW, height: 20))
                pill.wantsLayer = true; pill.layer?.cornerRadius = 5
                pill.layer?.backgroundColor = Theme.brandAmber.withAlphaComponent(0.2).cgColor
                pill.layer?.borderWidth = 0.5; pill.layer?.borderColor = Theme.brandAmber.withAlphaComponent(0.4).cgColor
                cmTrack.addSubview(pill)
            }
            let btn = NSButton(frame: NSRect(x: x, y: 3, width: cmW, height: 20))
            btn.isBordered = false
            btn.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? Theme.brandAmber : Theme.textMuted
            ])
            btn.target = self; btn.action = #selector(colorModeChanged(_:)); btn.tag = i
            cmTrack.addSubview(btn)
        }
        iy += 32

        // Accent color (only shown when fixed color mode)
        if w.config.colorMode == .fixed {
            let acLabel = NSTextField(labelWithString: "Accent")
            acLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); acLabel.textColor = Theme.textMuted
            acLabel.frame = NSRect(x: inset, y: iy, width: 50, height: 14)
            settingsCard.addSubview(acLabel)
            iy += 16

            let presets = TickerAccentPreset.allCases
            let dotSize: CGFloat = 18
            let dotGap: CGFloat = 6
            for (i, preset) in presets.enumerated() {
                let x = inset + CGFloat(i) * (dotSize + dotGap)
                let isActive = w.config.accentColor == preset
                let dotView = NSView(frame: NSRect(x: x, y: iy, width: dotSize, height: dotSize))
                dotView.wantsLayer = true
                dotView.layer?.cornerRadius = dotSize / 2
                dotView.layer?.backgroundColor = preset.color.cgColor
                if isActive {
                    dotView.layer?.borderWidth = 2
                    dotView.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
                    dotView.layer?.shadowColor = preset.color.cgColor
                    dotView.layer?.shadowRadius = 4
                    dotView.layer?.shadowOpacity = 0.8
                    dotView.layer?.shadowOffset = .zero
                }
                settingsCard.addSubview(dotView)

                let btn = NSButton(frame: NSRect(x: x, y: iy, width: dotSize, height: dotSize))
                btn.isBordered = false; btn.title = ""; btn.wantsLayer = true
                btn.target = self; btn.action = #selector(accentChanged(_:)); btn.tag = i
                settingsCard.addSubview(btn)
            }
            iy += dotSize + 8
        }

        // Price alert section
        let alertIcon = NSImageView(frame: NSRect(x: inset, y: iy + 1, width: 12, height: 12))
        alertIcon.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Alert")
        alertIcon.contentTintColor = Theme.textFaint
        settingsCard.addSubview(alertIcon)

        let alertLabel = NSTextField(labelWithString: "Price Alert")
        alertLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium); alertLabel.textColor = Theme.textMuted
        alertLabel.frame = NSRect(x: inset + 16, y: iy, width: 65, height: 14)
        settingsCard.addSubview(alertLabel)

        let alertCount = w.config.priceAlerts.count
        if alertCount > 0 {
            let countLabel = NSTextField(labelWithString: "\(alertCount) active")
            countLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium); countLabel.textColor = Theme.brandCyan.withAlphaComponent(0.7)
            countLabel.alignment = .right
            countLabel.frame = NSRect(x: innerW - 50, y: iy + 1, width: 62, height: 12)
            settingsCard.addSubview(countLabel)
        }
        iy += 18

        let alertCard = NSView(frame: NSRect(x: inset, y: iy, width: innerW, height: 26))
        alertCard.wantsLayer = true; alertCard.layer?.cornerRadius = 7
        alertCard.layer?.backgroundColor = Theme.sunkenBg.cgColor
        settingsCard.addSubview(alertCard)

        let alertField = NSTextField(frame: NSRect(x: 8, y: 2, width: innerW - 16, height: 22))
        alertField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular); alertField.textColor = Theme.textPrimary
        alertField.backgroundColor = .clear; alertField.drawsBackground = false
        alertField.isBordered = false; alertField.focusRingType = .none
        alertField.placeholderAttributedString = NSAttributedString(
            string: "AAPL 250 (symbol + target price)",
            attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Theme.textFaint])
        alertField.delegate = self
        alertField.tag = 999
        alertCard.addSubview(alertField)
        iy += 32

        iy += 8
        settingsCard.frame.size.height = iy
        y += iy + 4
    }

    // MARK: - Footer

    private func addFooter(y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        guard let w = widget else { return }

        let footerH: CGFloat = 30
        let footer = NSView(frame: NSRect(x: pad - 4, y: y, width: cw + 8, height: footerH))
        footer.wantsLayer = true; footer.layer?.cornerRadius = 7
        footer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
        docView.addSubview(footer)

        let clockIcon = NSImageView(frame: NSRect(x: 8, y: 9, width: 12, height: 12))
        clockIcon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Updated")
        clockIcon.contentTintColor = Theme.textGhost
        footer.addSubview(clockIcon)

        let timeLabel = NSTextField(labelWithString: w.freshnessDescription())
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        timeLabel.textColor = w.freshnessColor()
        timeLabel.frame = NSRect(x: 24, y: 9, width: 112, height: 14)
        footer.addSubview(timeLabel)

        let refreshBtn = NSButton(frame: NSRect(x: cw / 2 - 42, y: 6, width: 84, height: 18))
        refreshBtn.isBordered = false
        refreshBtn.wantsLayer = true
        refreshBtn.layer?.cornerRadius = 5
        refreshBtn.layer?.backgroundColor = Theme.brandCyan.withAlphaComponent(0.07).cgColor
        refreshBtn.attributedTitle = NSAttributedString(string: "Refresh now", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: Theme.brandCyan.withAlphaComponent(0.78)
        ])
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshClicked)
        footer.addSubview(refreshBtn)

        let quitBtn = NSButton(frame: NSRect(x: cw - 54, y: 5, width: 54, height: 20))
        quitBtn.isBordered = false
        quitBtn.wantsLayer = true
        quitBtn.layer?.cornerRadius = 6
        quitBtn.layer?.backgroundColor = Theme.red.withAlphaComponent(0.10).cgColor
        quitBtn.layer?.borderWidth = 0.5
        quitBtn.layer?.borderColor = Theme.red.withAlphaComponent(0.22).cgColor
        quitBtn.attributedTitle = NSAttributedString(string: "Quit", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: Theme.red.withAlphaComponent(0.9)
        ])
        quitBtn.target = self
        quitBtn.action = #selector(quitBaristaClicked)
        footer.addSubview(quitBtn)

        let t = w.config.symbols.count + w.config.coins.count
        let countStr = "\(t) symbol\(t == 1 ? "" : "s")"
        let countLabel = NSTextField(labelWithString: countStr)
        countLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular); countLabel.textColor = Theme.textGhost
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: cw - 140, y: 9, width: 78, height: 14)
        footer.addSubview(countLabel)

        y += footerH
    }

    // MARK: - Divider

    private func addDivider(y: inout CGFloat, pad: CGFloat, cw: CGFloat) {
        let d = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 1))
        d.wantsLayer = true; d.layer?.backgroundColor = Theme.divider.cgColor
        docView.addSubview(d)
        y += 6
    }

    // MARK: - Actions

    @objc private func removeClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let w = widget else { return }
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        w.removeQuote(String(parts[1]), kind: String(parts[0]) == "crypto" ? .crypto : .stock)
    }

    @objc private func openInBrowserClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let w = widget else { return }
        let parts = id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return }
        w.openInBrowser(symbol: String(parts[2]), kind: String(parts[1]) == "crypto" ? .crypto : .stock)
    }

    @objc private func refreshClicked() {
        widget?.refreshNow()
        rebuildContent()
    }

    @objc private func quitBaristaClicked() {
        NSApp.terminate(nil)
    }

    @objc private func showQuoteDetail(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let w = widget else { return }
        let parts = id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return }
        let kind: MarketQuote.Kind = String(parts[1]) == "crypto" ? .crypto : .stock
        let symbol = String(parts[2])
        guard let quote = w.sortedQuotes().first(where: { $0.kind == kind && $0.symbol == symbol }) else { return }

        detailPopover?.close()
        let vc = StockDetailPopoverController(widget: w, quote: quote)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 620, height: 760)
        popover.contentViewController = vc
        detailPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func holdingsClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let w = widget else { return }
        let parts = id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return }
        let kind: MarketQuote.Kind = String(parts[1]) == "crypto" ? .crypto : .stock
        let symbol = String(parts[2])

        let alert = NSAlert()
        alert.messageText = "Set Holdings for \(symbol)"
        alert.informativeText = "Shares, and what you paid per share. Leave the cost blank to skip total-return tracking for this position."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let form = HoldingsForm(shares: w.config.holdings[symbol] ?? 0,
                                cost: w.config.costBasis[symbol])
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.shareField

        if alert.runModal() == .alertFirstButtonReturn {
            w.setHolding(symbol: symbol, kind: kind,
                         quantity: form.enteredShares,
                         averageCost: form.enteredCost)
            rebuildContent()
        }
    }

    // MARK: - Portfolio Actions

    @objc private func portfolioTabClicked(_ sender: NSButton) {
        guard let w = widget, let id = sender.identifier?.rawValue else { return }
        if id == w.config.activePortfolioID {
            showPortfolioMenu(from: sender)
        } else {
            w.selectPortfolio(id: id)
            rebuildContent()
        }
    }

    private func showPortfolioMenu(from sender: NSButton) {
        guard let w = widget else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let rename = NSMenuItem(title: "Rename\u{2026}", action: #selector(renamePortfolioClicked), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        let delete = NSMenuItem(title: "Delete", action: #selector(deletePortfolioClicked), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = w.config.portfolios.count > 1
        menu.addItem(delete)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addPortfolioClicked(_ sender: NSButton) {
        guard let w = widget, w.canAddPortfolio else { return }

        let alert = NSAlert()
        alert.messageText = "New Portfolio"
        alert.informativeText = "Name this portfolio. Your watchlist stays shared - only holdings and cash are separate."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "Roth IRA"
        input.font = NSFont.systemFont(ofSize: 13)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            w.addPortfolio(named: input.stringValue)
            rebuildContent()
        }
    }

    @objc private func renamePortfolioClicked() {
        guard let w = widget, let active = w.config.activePortfolio else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Portfolio"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = active.name
        input.font = NSFont.systemFont(ofSize: 13)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            w.renameActivePortfolio(to: input.stringValue)
            rebuildContent()
        }
    }

    @objc private func deletePortfolioClicked() {
        guard let w = widget, let active = w.config.activePortfolio else { return }
        guard w.config.portfolios.count > 1 else { return }

        if !active.isEmpty {
            let confirm = NSAlert()
            confirm.messageText = "Delete \u{201c}\(active.name)\u{201d}?"
            confirm.informativeText = "This portfolio has holdings. Deleting it removes those positions and its cash. Your watchlist is not affected."
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        w.deletePortfolio(id: active.id)
        rebuildContent()
    }

    @objc private func cashClicked(_ sender: NSButton) {
        guard let w = widget else { return }
        let alert = NSAlert()
        alert.messageText = "Set Cash Balance"
        alert.informativeText = "Enter uninvested cash in dollars (0 to remove):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = String(format: "%.2f", w.config.cash)
        input.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let cleaned = input.stringValue.filter { $0.isNumber || $0 == "." || $0 == "-" }
            w.setCash(Double(cleaned) ?? 0)
            rebuildContent()
        }
    }

    @objc private func displayModeChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        let modes: [TickerDisplayMode] = [.scrolling, .focused, .compact, .sparkline, .portfolio]
        guard sender.tag < modes.count else { return }
        w.config.displayMode = modes[sender.tag]
        w.saveConfig(); w.onDisplayUpdate?()
        rebuildContent()
    }

    @objc private func sortModeChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        let modes: [TickerSortMode] = [.manual, .alphabetical, .changeDesc, .changeAsc, .priceDesc]
        guard sender.tag < modes.count else { return }
        w.config.sortMode = modes[sender.tag]
        w.saveConfig(); w.onDisplayUpdate?()
        rebuildContent()
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        switch sender.tag {
        case 0: w.config.coloredTicker.toggle()
        case 1: w.config.showSparklines.toggle()
        case 2: w.config.showVolume.toggle()
        case 3: w.config.showIndices.toggle()
        case 4: w.config.showExtendedHours.toggle()
        case 5: w.config.showMarketCap.toggle()
        case 6: w.config.showDayRange.toggle()
        case 7: w.config.showPERatio.toggle()
        default: break
        }
        w.saveConfig(); w.onDisplayUpdate?()
        rebuildContent()
    }

    @objc private func colorModeChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        let modes: [TickerColorMode] = [.dynamic, .fixed]
        guard sender.tag < modes.count else { return }
        w.config.colorMode = modes[sender.tag]
        w.saveConfig(); w.onDisplayUpdate?()
        rebuildContent()
    }

    @objc private func accentChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        let presets = TickerAccentPreset.allCases
        guard sender.tag < presets.count else { return }
        w.config.accentColor = presets[sender.tag]
        w.saveConfig(); w.onDisplayUpdate?()
        rebuildContent()
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        guard let w = widget else { return }
        w.config.tickerWidth = sender.doubleValue
        w.saveConfig(); w.onDisplayUpdate?()
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        guard let w = widget else { return }
        w.config.scrollSpeed = sender.doubleValue
        w.saveConfig(); w.onDisplayUpdate?()
    }

    @objc private func refreshChanged(_ sender: NSButton) {
        guard let w = widget else { return }
        w.config.refreshInterval = TimeInterval(sender.tag)
        w.saveConfig()
        w.stop(); w.start()
        rebuildContent()
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            guard let field = control as? NSTextField, let w = widget else { return false }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return true }

            if field.tag == 999 {
                let parts = text.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let price = Double(parts[1]) {
                    let symbol = String(parts[0]).uppercased()
                    w.config.priceAlerts[symbol] = price
                    w.saveConfig()
                    field.stringValue = ""
                    rebuildContent()
                }
                return true
            }

            w.addSymbol(text)
            field.stringValue = ""
            return true
        }
        return false
    }

    deinit {
        widget?.onDataRefresh = nil
    }
}
