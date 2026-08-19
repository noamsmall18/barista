import Cocoa

// MARK: - Portfolio Chart

/// Value-over-time chart for a portfolio.
///
/// A drawn view rather than a rendered image, so it can carry a hover readout,
/// high and low markers, and an optional benchmark line. Straight segments with
/// round joins are deliberate: smoothing a 50-point financial series invents
/// peaks between closes that never happened.
final class PortfolioChartView: NSView {

    struct Sample {
        let date: Date
        let value: Double
        /// For benchmark samples, the index's own price before rebasing, so the
        /// hover readout can show what SPY actually cost as well as its move.
        var raw: Double? = nil
    }

    /// The portfolio's own value over the selected range.
    var samples: [Sample] = [] { didSet { rebuildGeometry(); needsDisplay = true } }

    /// Optional comparison line, already rebased to the portfolio's opening value
    /// so the two are compared on percentage growth rather than dollars.
    var benchmark: [Sample]? { didSet { rebuildGeometry(); needsDisplay = true } }
    var benchmarkLabel: String = "SPY"

    var accent: NSColor = Theme.green { didSet { needsDisplay = true } }

    /// Whether the axis and hover readout label points by calendar date or by
    /// clock time. Intraday series span hours, where "Aug 14" on both ends says
    /// nothing.
    enum AxisStyle { case date, time }
    var axisStyle: AxisStyle = .date { didSet { needsDisplay = true } }

    private var axisFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = axisStyle == .time ? "h:mm a" : "MMM d"
        return f
    }

    /// Index under the cursor. Internal rather than private so the hover state
    /// can be rendered without a live mouse.
    var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }

    private var trackingAreaRef: NSTrackingArea?

    // Room for the value labels on the left and the date labels underneath.
    private let insetLeft: CGFloat = 4
    private let insetRight: CGFloat = 4
    private let insetTop: CGFloat = 14
    private let insetBottom: CGFloat = 15

    private var lowest: Double = 0
    private var highest: Double = 1

    override var isFlipped: Bool { false }

    // MARK: - Geometry

    private var plotRect: NSRect {
        NSRect(x: insetLeft,
               y: insetBottom,
               width: max(1, bounds.width - insetLeft - insetRight),
               height: max(1, bounds.height - insetTop - insetBottom))
    }

    private func rebuildGeometry() {
        var values = samples.map(\.value)
        if let benchmark { values += benchmark.map(\.value) }
        guard let lo = values.min(), let hi = values.max() else {
            lowest = 0; highest = 1; return
        }
        // A flat series would otherwise divide by zero; give it a little air.
        if hi - lo < 0.0001 {
            lowest = lo - max(abs(lo) * 0.01, 1)
            highest = hi + max(abs(hi) * 0.01, 1)
        } else {
            let pad = (hi - lo) * 0.12
            lowest = lo - pad
            highest = hi + pad
        }
    }

    private func point(at index: Int, in series: [Sample]) -> NSPoint {
        let r = plotRect
        let denom = max(1, series.count - 1)
        let x = r.minX + r.width * CGFloat(index) / CGFloat(denom)
        let span = max(0.0001, highest - lowest)
        let frac = (series[index].value - lowest) / span
        return NSPoint(x: x, y: r.minY + r.height * CGFloat(frac))
    }

    /// Index of the portfolio sample closest in time to `date`.
    ///
    /// The benchmark usually has fewer points than the portfolio - only days the
    /// index also traded - so spacing it evenly across the width would stretch it
    /// and put it out of step. Mapping onto the portfolio's own index space keeps
    /// the two lines aligned and keeps weekends compressed the same way.
    private func nearestSampleIndex(to date: Date) -> Int {
        guard samples.count > 1 else { return 0 }
        let t = date.timeIntervalSince1970
        var lo = 0, hi = samples.count - 1
        if t <= samples[0].date.timeIntervalSince1970 { return 0 }
        if t >= samples[hi].date.timeIntervalSince1970 { return hi }
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if samples[mid].date.timeIntervalSince1970 <= t { lo = mid } else { hi = mid }
        }
        let dLo = abs(samples[lo].date.timeIntervalSince1970 - t)
        let dHi = abs(samples[hi].date.timeIntervalSince1970 - t)
        return dLo <= dHi ? lo : hi
    }

    private func benchmarkPoint(_ s: Sample) -> NSPoint {
        let r = plotRect
        let x = point(at: nearestSampleIndex(to: s.date), in: samples).x
        let span = max(0.0001, highest - lowest)
        let frac = (s.value - lowest) / span
        return NSPoint(x: x, y: r.minY + r.height * CGFloat(frac))
    }

    private func benchmarkPath() -> NSBezierPath {
        let p = NSBezierPath()
        guard let benchmark, !benchmark.isEmpty else { return p }
        p.lineJoinStyle = .round
        p.lineCapStyle = .round
        for (i, s) in benchmark.enumerated() {
            let pt = benchmarkPoint(s)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        return p
    }

    private func path(for series: [Sample]) -> NSBezierPath {
        let p = NSBezierPath()
        guard !series.isEmpty else { return p }
        p.lineJoinStyle = .round
        p.lineCapStyle = .round
        for i in series.indices {
            let pt = point(at: i, in: series)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        return p
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard samples.count >= 2 else { return }
        let r = plotRect

        // Opening value, so the fill reads as gain or loss over the range.
        let baseValue = samples[0].value
        let baseY = r.minY + r.height * CGFloat((baseValue - lowest) / max(0.0001, highest - lowest))

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: r.minX, y: baseY))
        baseline.line(to: NSPoint(x: r.maxX, y: baseY))
        baseline.setLineDash([2, 3], count: 2, phase: 0)
        baseline.lineWidth = 0.75
        Theme.textGhost.withAlphaComponent(0.35).setStroke()
        baseline.stroke()

        // Fill between the line and the baseline.
        let linePath = path(for: samples)
        if let fill = linePath.copy() as? NSBezierPath {
            fill.line(to: NSPoint(x: r.maxX, y: baseY))
            fill.line(to: NSPoint(x: r.minX, y: baseY))
            fill.close()
            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            let gradient = NSGradient(colors: [accent.withAlphaComponent(0.26),
                                               accent.withAlphaComponent(0.02)])
            gradient?.draw(in: NSRect(x: r.minX, y: min(baseY, r.minY),
                                      width: r.width, height: r.height), angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Benchmark sits under the portfolio line so it never obscures it.
        if let benchmark, benchmark.count >= 2 {
            let bp = benchmarkPath()
            bp.lineWidth = 1
            bp.setLineDash([3, 2], count: 2, phase: 0)
            Theme.textMuted.withAlphaComponent(0.55).setStroke()
            bp.stroke()
        }

        linePath.lineWidth = 1.6
        accent.setStroke()
        linePath.stroke()

        drawExtremes(in: r)

        // End dot, so the latest value is easy to find.
        let endPt = point(at: samples.count - 1, in: samples)
        let dot = NSBezierPath(ovalIn: NSRect(x: endPt.x - 2.5, y: endPt.y - 2.5, width: 5, height: 5))
        accent.setFill()
        dot.fill()

        drawDateAxis(in: r)
        if let hoverIndex { drawHover(at: hoverIndex, in: r) }
    }

    private func drawExtremes(in r: NSRect) {
        guard let hiIdx = samples.indices.max(by: { samples[$0].value < samples[$1].value }),
              let loIdx = samples.indices.min(by: { samples[$0].value < samples[$1].value }),
              hiIdx != loIdx else { return }

        func mark(_ idx: Int, label: String, above: Bool) {
            let pt = point(at: idx, in: samples)
            let ring = NSBezierPath(ovalIn: NSRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4))
            Theme.textMuted.withAlphaComponent(0.7).setFill()
            ring.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                .foregroundColor: Theme.textMuted.withAlphaComponent(0.85)
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            // Keep the label inside the view even at the extreme edges.
            var x = pt.x - size.width / 2
            x = max(r.minX, min(x, r.maxX - size.width))

            // Prefer the requested side, but flip when that would put the label
            // into the date axis or off the top edge.
            var placeAbove = above
            if !placeAbove, pt.y - size.height - 4 < r.minY { placeAbove = true }
            if placeAbove, pt.y + 5 + size.height > bounds.height { placeAbove = false }

            let y = placeAbove ? min(pt.y + 5, bounds.height - size.height)
                               : max(pt.y - size.height - 4, r.minY)
            str.draw(at: NSPoint(x: x, y: y))
        }

        mark(hiIdx, label: Self.compactMoney(samples[hiIdx].value), above: true)
        mark(loIdx, label: Self.compactMoney(samples[loIdx].value), above: false)
    }

    private func drawDateAxis(in r: NSRect) {
        guard let first = samples.first, let last = samples.last else { return }
        let fmt = axisFormatter
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: Theme.textGhost
        ]
        NSAttributedString(string: fmt.string(from: first.date), attributes: attrs)
            .draw(at: NSPoint(x: r.minX, y: 2))
        let endStr = NSAttributedString(string: fmt.string(from: last.date), attributes: attrs)
        endStr.draw(at: NSPoint(x: r.maxX - endStr.size().width, y: 2))
    }

    private func drawHover(at index: Int, in r: NSRect) {
        guard samples.indices.contains(index) else { return }
        let pt = point(at: index, in: samples)

        let crosshair = NSBezierPath()
        crosshair.move(to: NSPoint(x: pt.x, y: r.minY))
        crosshair.line(to: NSPoint(x: pt.x, y: r.maxY))
        crosshair.lineWidth = 0.75
        Theme.textMuted.withAlphaComponent(0.35).setStroke()
        crosshair.stroke()

        let halo = NSBezierPath(ovalIn: NSRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
        accent.withAlphaComponent(0.25).setFill()
        halo.fill()
        let core = NSBezierPath(ovalIn: NSRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5))
        accent.setFill()
        core.fill()

        // Readout: date, value, and change from the start of the range.
        let sample = samples[index]
        let fmt = axisFormatter
        let base = samples[0].value
        let delta = sample.value - base
        let pct = base > 0 ? delta / base * 100 : 0

        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: Theme.textMuted
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: Theme.textPrimary
        ]
        let deltaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: delta >= 0 ? Theme.green : Theme.red
        ]

        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: fmt.string(from: sample.date) + "  ", attributes: dateAttrs))
        line.append(NSAttributedString(string: Self.money(sample.value) + "  ", attributes: valueAttrs))
        line.append(NSAttributedString(string: String(format: "%@%.1f%%", pct >= 0 ? "+" : "", pct),
                                       attributes: deltaAttrs))

        // Second line: where the benchmark stood at the same moment, both its own
        // price and its move over the range, so the two are directly comparable.
        var benchLine: NSAttributedString?
        if let benchmark, let first = benchmark.first, first.value > 0,
           let match = benchmarkSample(nearestTo: sample.date) {
            let bPct = (match.value - first.value) / first.value * 100
            let b = NSMutableAttributedString()
            b.append(NSAttributedString(string: benchmarkLabel + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                .foregroundColor: Theme.brandCyan.withAlphaComponent(0.9)]))
            if let raw = match.raw {
                b.append(NSAttributedString(string: Self.money(raw) + "  ", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium),
                    .foregroundColor: Theme.textMuted]))
            }
            b.append(NSAttributedString(string: String(format: "%@%.1f%%", bPct >= 0 ? "+" : "", bPct),
                                        attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
                .foregroundColor: bPct >= 0 ? Theme.green.withAlphaComponent(0.85)
                                            : Theme.red.withAlphaComponent(0.85)]))
            benchLine = b

            // Mark the benchmark line at the same moment.
            let bp = benchmarkPoint(match)
            let bDot = NSBezierPath(ovalIn: NSRect(x: bp.x - 2, y: bp.y - 2, width: 4, height: 4))
            Theme.brandCyan.withAlphaComponent(0.8).setFill()
            bDot.fill()
        }

        let size = line.size()
        let bSize = benchLine?.size() ?? .zero
        let boxW = max(size.width, bSize.width) + 10
        let boxH = size.height + (benchLine != nil ? bSize.height + 2 : 0) + 2

        var boxX = pt.x - boxW / 2
        boxX = max(0, min(boxX, bounds.width - boxW))
        let boxRect = NSRect(x: boxX, y: bounds.height - boxH - 2, width: boxW, height: boxH)

        let bg = NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4)
        Theme.bg.withAlphaComponent(0.94).setFill()
        bg.fill()
        Theme.cardBorder.setStroke()
        bg.lineWidth = 0.5
        bg.stroke()

        if let benchLine {
            line.draw(at: NSPoint(x: boxRect.minX + 5, y: boxRect.minY + bSize.height + 2))
            benchLine.draw(at: NSPoint(x: boxRect.minX + 5, y: boxRect.minY + 1))
        } else {
            line.draw(at: NSPoint(x: boxRect.minX + 5, y: boxRect.minY + 1))
        }
    }

    /// Benchmark sample closest in time to `date`, since the benchmark only has
    /// points for days the index also traded.
    private func benchmarkSample(nearestTo date: Date) -> Sample? {
        guard let benchmark, !benchmark.isEmpty else { return nil }
        return benchmark.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard samples.count >= 2 else { return }
        let local = convert(event.locationInWindow, from: nil)
        let r = plotRect
        let frac = (local.x - r.minX) / max(1, r.width)
        let idx = Int((frac * CGFloat(samples.count - 1)).rounded())
        let clamped = max(0, min(samples.count - 1, idx))
        if clamped != hoverIndex {
            hoverIndex = clamped
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil {
            hoverIndex = nil
            needsDisplay = true
        }
    }

    // MARK: - Formatting

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = v >= 10_000 ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    static func compactMoney(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "$%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "$%.1fk", v / 1_000) }
        return String(format: "$%.0f", v)
    }
}
