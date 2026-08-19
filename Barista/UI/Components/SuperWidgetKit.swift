import Cocoa

struct SuperWidgetMetric {
    let label: String
    let value: String
    let color: NSColor
}

struct SuperWidgetKit {
    static let panelHeight: CGFloat = 132

    static func addTerminalPanel(
        to container: NSView,
        y: CGFloat,
        pad: CGFloat,
        cw: CGFloat,
        title: String = "TERMINAL READOUT",
        metrics: [SuperWidgetMetric],
        insights: [String],
        actions: [String],
        accent: NSColor
    ) -> CGFloat {
        var y = y
        let card = NSView(frame: NSRect(x: pad, y: y - panelHeight, width: cw, height: panelHeight))
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.cardBg.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = accent.withAlphaComponent(0.20).cgColor
        container.addSubview(card)

        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 9.5, weight: .bold)
        header.textColor = accent
        header.frame = NSRect(x: 10, y: panelHeight - 20, width: cw - 20, height: 12)
        card.addSubview(header)

        let visibleMetrics = Array(metrics.prefix(4))
        if !visibleMetrics.isEmpty {
            let gap: CGFloat = 6
            let metricW = (cw - 20 - gap * CGFloat(visibleMetrics.count - 1)) / CGFloat(visibleMetrics.count)
            for (idx, metric) in visibleMetrics.enumerated() {
                let x = 10 + CGFloat(idx) * (metricW + gap)
                let pill = NSView(frame: NSRect(x: x, y: 72, width: metricW, height: 34))
                pill.wantsLayer = true
                pill.layer?.cornerRadius = 6
                pill.layer?.backgroundColor = metric.color.withAlphaComponent(0.08).cgColor
                pill.layer?.borderWidth = 0.5
                pill.layer?.borderColor = metric.color.withAlphaComponent(0.16).cgColor
                card.addSubview(pill)

                let value = NSTextField(labelWithString: metric.value)
                value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
                value.textColor = metric.color
                value.alignment = .center
                value.lineBreakMode = .byTruncatingTail
                value.frame = NSRect(x: 2, y: 16, width: metricW - 4, height: 13)
                pill.addSubview(value)

                let label = NSTextField(labelWithString: metric.label.uppercased())
                label.font = .systemFont(ofSize: 7.5, weight: .semibold)
                label.textColor = Theme.textFaint
                label.alignment = .center
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: 2, y: 4, width: metricW - 4, height: 10)
                pill.addSubview(label)
            }
        }

        let insightText = Array(insights.prefix(3)).joined(separator: "  |  ")
        let insight = NSTextField(labelWithString: insightText.isEmpty ? "Live context updates here as the widget refreshes." : insightText)
        insight.font = .systemFont(ofSize: 9.5, weight: .medium)
        insight.textColor = Theme.textSecondary
        insight.lineBreakMode = .byTruncatingTail
        insight.frame = NSRect(x: 10, y: 48, width: cw - 20, height: 13)
        card.addSubview(insight)

        let visibleActions = Array(actions.prefix(3))
        if !visibleActions.isEmpty {
            let gap: CGFloat = 6
            let actionW = (cw - 20 - gap * CGFloat(visibleActions.count - 1)) / CGFloat(visibleActions.count)
            for (idx, action) in visibleActions.enumerated() {
                let x = 10 + CGFloat(idx) * (actionW + gap)
                let chip = NSView(frame: NSRect(x: x, y: 13, width: actionW, height: 22))
                chip.wantsLayer = true
                chip.layer?.cornerRadius = 6
                chip.layer?.backgroundColor = Theme.sunkenBg.cgColor
                chip.layer?.borderWidth = 0.5
                chip.layer?.borderColor = Theme.cardBorder.cgColor
                card.addSubview(chip)

                let label = NSTextField(labelWithString: action)
                label.font = .systemFont(ofSize: 8.5, weight: .semibold)
                label.textColor = Theme.textMuted
                label.alignment = .center
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: 4, y: 5, width: actionW - 8, height: 12)
                chip.addSubview(label)
            }
        }

        y -= panelHeight + 8
        return y
    }
}
