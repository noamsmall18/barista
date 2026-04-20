import Cocoa

/// Renders sparkline charts as NSImage for use in menu bar status items and dropdowns.
class SparklineRenderer {
    struct Style {
        var lineColor: NSColor = Theme.accent
        var fillColor: NSColor? = Theme.accent.withAlphaComponent(0.15)
        var lineWidth: CGFloat = 1.5
        var height: CGFloat = 16
        var pointRadius: CGFloat = 0  // 0 = no dots
    }

    /// Renders a sparkline image from data points.
    static func render(data: [Double], width: CGFloat, style: Style = Style()) -> NSImage {
        let height = style.height
        let image = NSImage(size: NSSize(width: width, height: height))
        guard data.count >= 2 else { return image }

        image.lockFocus()

        let minVal = data.min() ?? 0
        let maxVal = data.max() ?? 1
        let range = maxVal - minVal
        let effectiveRange = range > 0 ? range : 1.0

        let stepX = width / CGFloat(data.count - 1)
        let padding: CGFloat = 2  // vertical padding

        func point(at index: Int) -> NSPoint {
            let x = CGFloat(index) * stepX
            let normalized = (data[index] - minVal) / effectiveRange
            let y = padding + CGFloat(normalized) * (height - padding * 2)
            return NSPoint(x: x, y: y)
        }

        // Build path
        let path = NSBezierPath()
        path.move(to: point(at: 0))
        for i in 1..<data.count {
            path.line(to: point(at: i))
        }

        // Fill under curve
        if let fillColor = style.fillColor {
            let fillPath = path.copy() as! NSBezierPath
            fillPath.line(to: NSPoint(x: CGFloat(data.count - 1) * stepX, y: 0))
            fillPath.line(to: NSPoint(x: 0, y: 0))
            fillPath.close()
            fillColor.setFill()
            fillPath.fill()
        }

        // Stroke line
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        style.lineColor.setStroke()
        path.stroke()

        // Last point dot
        if style.pointRadius > 0 {
            let last = point(at: data.count - 1)
            let dotRect = NSRect(
                x: last.x - style.pointRadius,
                y: last.y - style.pointRadius,
                width: style.pointRadius * 2,
                height: style.pointRadius * 2
            )
            style.lineColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        image.unlockFocus()
        return image
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
