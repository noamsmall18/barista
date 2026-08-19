import Cocoa

/// Renders sparkline charts as NSImage for use in menu bar status items and dropdowns.
class SparklineRenderer {
    struct Style {
        var lineColor: NSColor = Theme.accent
        var fillColor: NSColor? = Theme.accent.withAlphaComponent(0.15)
        var lineWidth: CGFloat = 1.5
        var height: CGFloat = 16
        var pointRadius: CGFloat = 0  // 0 = no dots
        var baselineValue: Double? = nil
        var positiveColor: NSColor = Theme.green
        var negativeColor: NSColor = Theme.red
        var neutralColor: NSColor = Theme.textMuted
        var baselineColor: NSColor? = nil
        var gridColor: NSColor? = nil
        var showGrid: Bool = false
        var smooth: Bool = true
        var glow: Bool = false
        var endPointColor: NSColor? = nil

        /// Index at which extended-hours bars begin. Everything from here on is
        /// drawn dimmer and dashed, so the 4:00 boundary is visible instead of
        /// an after-hours move reading as part of the trading day.
        var extendedFromIndex: Int? = nil

        init(
            lineColor: NSColor = Theme.accent,
            fillColor: NSColor? = Theme.accent.withAlphaComponent(0.15),
            lineWidth: CGFloat = 1.5,
            height: CGFloat = 16,
            pointRadius: CGFloat = 0,
            baselineValue: Double? = nil,
            positiveColor: NSColor = Theme.green,
            negativeColor: NSColor = Theme.red,
            neutralColor: NSColor = Theme.textMuted,
            baselineColor: NSColor? = nil,
            gridColor: NSColor? = nil,
            showGrid: Bool = false,
            smooth: Bool = true,
            glow: Bool = false,
            endPointColor: NSColor? = nil,
            extendedFromIndex: Int? = nil
        ) {
            self.extendedFromIndex = extendedFromIndex
            self.lineColor = lineColor
            self.fillColor = fillColor
            self.lineWidth = lineWidth
            self.height = height
            self.pointRadius = pointRadius
            self.baselineValue = baselineValue
            self.positiveColor = positiveColor
            self.negativeColor = negativeColor
            self.neutralColor = neutralColor
            self.baselineColor = baselineColor
            self.gridColor = gridColor
            self.showGrid = showGrid
            self.smooth = smooth
            self.glow = glow
            self.endPointColor = endPointColor
        }
    }

    /// Renders a sparkline image from data points.
    static func render(data: [Double], width: CGFloat, style: Style = Style()) -> NSImage {
        let height = style.height
        let image = NSImage(size: NSSize(width: width, height: height))
        let values = data.filter { $0.isFinite }
        guard values.count >= 2, width > 2, height > 2 else { return image }

        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true

        let baseline = style.baselineValue?.isFinite == true ? style.baselineValue : nil
        let extents = values + (baseline.map { [$0] } ?? [])
        var minVal = extents.min() ?? 0
        var maxVal = extents.max() ?? 1
        if maxVal == minVal {
            let spread = max(abs(maxVal) * 0.01, 1)
            minVal -= spread
            maxVal += spread
        }
        let effectiveRange = maxVal - minVal
        let plotRect = NSRect(x: 1.5, y: 2, width: max(1, width - 3), height: max(1, height - 4))
        let stepX = plotRect.width / CGFloat(values.count - 1)

        let last = values.last ?? 0
        let first = values.first ?? last
        let trendReference = baseline ?? first
        let trendDelta = last - trendReference
        let trendColor: NSColor
        if abs(trendDelta) < 0.000001 {
            trendColor = style.neutralColor
        } else {
            trendColor = trendDelta >= 0 ? style.positiveColor : style.negativeColor
        }
        let lineColor = baseline == nil ? style.lineColor : trendColor
        let fillColor = style.fillColor ?? lineColor.withAlphaComponent(0.14)

        func point(at index: Int) -> NSPoint {
            let x = plotRect.minX + CGFloat(index) * stepX
            let normalized = (values[index] - minVal) / effectiveRange
            let y = plotRect.minY + CGFloat(normalized) * plotRect.height
            return NSPoint(x: x, y: y)
        }

        func y(for value: Double) -> CGFloat {
            let normalized = (value - minVal) / effectiveRange
            return plotRect.minY + CGFloat(normalized) * plotRect.height
        }

        if style.showGrid, let gridColor = style.gridColor {
            for fraction in [0.25, 0.5, 0.75] {
                let gy = plotRect.minY + plotRect.height * CGFloat(fraction)
                let grid = NSBezierPath()
                grid.move(to: NSPoint(x: plotRect.minX, y: gy))
                grid.line(to: NSPoint(x: plotRect.maxX, y: gy))
                grid.lineWidth = 0.5
                gridColor.setStroke()
                grid.stroke()
            }
        }

        if let baseline {
            let by = y(for: baseline)
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: plotRect.minX, y: by))
            basePath.line(to: NSPoint(x: plotRect.maxX, y: by))
            basePath.lineWidth = 0.75
            basePath.setLineDash([2.5, 2.5], count: 2, phase: 0)
            (style.baselineColor ?? Theme.textGhost).setStroke()
            basePath.stroke()
        }

        let points = values.indices.map { point(at: $0) }
        let path = style.smooth ? smoothedPath(points: points) : straightPath(points: points)

        if fillColor.alphaComponent > 0 {
            let fillPath = path.copy() as! NSBezierPath
            fillPath.line(to: NSPoint(x: points.last?.x ?? plotRect.maxX, y: plotRect.minY))
            fillPath.line(to: NSPoint(x: points.first?.x ?? plotRect.minX, y: plotRect.minY))
            fillPath.close()
            NSGraphicsContext.saveGraphicsState()
            fillPath.addClip()
            let gradient = NSGradient(
                starting: fillColor,
                ending: fillColor.withAlphaComponent(max(0.01, fillColor.alphaComponent * 0.12))
            )
            gradient?.draw(in: plotRect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }

        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if style.glow {
            let shadow = NSShadow()
            shadow.shadowColor = lineColor.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = .zero
            shadow.set()
        }
        if let brk = style.extendedFromIndex, brk > 0, brk < points.count {
            // Overlap by one point so the two segments meet rather than leaving
            // a gap at the boundary.
            let sessionPoints = Array(points[0..<brk])
            let extendedPoints = Array(points[(brk - 1)...])

            let sessionPath = style.smooth ? smoothedPath(points: sessionPoints)
                                           : straightPath(points: sessionPoints)
            sessionPath.lineWidth = style.lineWidth
            sessionPath.lineCapStyle = .round
            sessionPath.lineJoinStyle = .round
            lineColor.setStroke()
            sessionPath.stroke()

            let extendedPath = style.smooth ? smoothedPath(points: extendedPoints)
                                            : straightPath(points: extendedPoints)
            extendedPath.lineWidth = style.lineWidth
            extendedPath.lineCapStyle = .round
            extendedPath.lineJoinStyle = .round
            extendedPath.setLineDash([2.5, 2.0], count: 2, phase: 0)
            lineColor.withAlphaComponent(0.5).setStroke()
            extendedPath.stroke()
        } else {
            lineColor.setStroke()
            path.stroke()
        }
        NSShadow().set()

        if style.pointRadius > 0 {
            let lastPoint = points[points.count - 1]
            let dotColor = style.endPointColor ?? lineColor
            let haloRect = NSRect(
                x: lastPoint.x - style.pointRadius * 1.75,
                y: lastPoint.y - style.pointRadius * 1.75,
                width: style.pointRadius * 3.5,
                height: style.pointRadius * 3.5
            )
            dotColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            let dotRect = NSRect(
                x: lastPoint.x - style.pointRadius,
                y: lastPoint.y - style.pointRadius,
                width: style.pointRadius * 2,
                height: style.pointRadius * 2
            )
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        image.unlockFocus()
        return image
    }

    private static func straightPath(points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        return path
    }

    private static func smoothedPath(points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])

        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let smoothing: CGFloat = 0.18
            let cp1 = NSPoint(
                x: p1.x + (p2.x - p0.x) * smoothing,
                y: p1.y + (p2.y - p0.y) * smoothing
            )
            let cp2 = NSPoint(
                x: p2.x - (p3.x - p1.x) * smoothing,
                y: p2.y - (p3.y - p1.y) * smoothing
            )
            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }

        return path
    }

    /// Render a bar chart sparkline (vertical bars instead of line).
    static func renderBars(data: [Double], width: CGFloat, style: Style = Style()) -> NSImage {
        let height = style.height
        let image = NSImage(size: NSSize(width: width, height: height))
        guard !data.isEmpty else { return image }

        image.lockFocus()

        let minVal = data.min() ?? 0
        let maxVal = data.max() ?? 1
        let range = maxVal - minVal
        let effectiveRange = range > 0 ? range : 1.0

        let barWidth = max(width / CGFloat(data.count) - 1, 1)
        let gap: CGFloat = 1
        let padding: CGFloat = 1

        for (i, value) in data.enumerated() {
            let normalized = (value - minVal) / effectiveRange
            let barHeight = max(padding + CGFloat(normalized) * (height - padding * 2), 1)
            let x = CGFloat(i) * (barWidth + gap)

            let rect = NSRect(x: x, y: 0, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 3, yRadius: barWidth / 3)

            let isLast = i == data.count - 1
            let color = isLast ? style.lineColor : style.lineColor.withAlphaComponent(0.5)
            color.setFill()
            path.fill()
        }

        image.unlockFocus()
        return image
    }

    /// Render a mini donut/ring chart for percentage values.
    static func renderRing(percentage: Double, size: CGFloat, color: NSColor = Theme.accent, lineWidth: CGFloat = 3) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2

        // Background ring
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bgPath.lineWidth = lineWidth
        color.withAlphaComponent(0.15).setStroke()
        bgPath.stroke()

        // Foreground arc
        let startAngle: CGFloat = 90
        let endAngle = startAngle - CGFloat(percentage / 100.0 * 360.0)
        let fgPath = NSBezierPath()
        fgPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        fgPath.lineWidth = lineWidth
        fgPath.lineCapStyle = .round
        color.setStroke()
        fgPath.stroke()

        image.unlockFocus()
        return image
    }
}
