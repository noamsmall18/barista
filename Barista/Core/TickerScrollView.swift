import Cocoa

class TickerScrollView: NSView {
    private var tickerText: String = "Loading..."
    private var attrText: NSAttributedString?
    private var offset: CGFloat = 0
    private var textWidth: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    var speed: CGFloat = 0.3
    /// Pause scrolling briefly after each full cycle for readability
    private var pauseCounter: Int = 0
    private let pauseFrames: Int = 90  // ~1.5 seconds at 60fps
    /// Gap between repeated text
    private let textGap: CGFloat = 60

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        startDisplayLink()
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateText(_ text: String) {
        tickerText = text
        attrText = nil
        let attrs: [NSAttributedString.Key: Any] = [.font: textFont]
        textWidth = (text as NSString).size(withAttributes: attrs).width
    }

    func updateAttributedText(_ text: NSAttributedString) {
        attrText = text
        textWidth = text.size().width
    }

    private func startDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let displayLink = dl else { return }
        self.displayLink = displayLink
        CVDisplayLinkSetOutputHandler(displayLink) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async { self?.tick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(displayLink)
    }

    private func tick() {
        guard textWidth > 0 else { return }

        // If text fits without scrolling, don't scroll
        if textWidth <= bounds.width {
            offset = 0
            needsDisplay = true
            return
        }

        if pauseCounter > 0 {
            pauseCounter -= 1
            return
        }

        offset += speed
        if offset >= textWidth + textGap {
            offset = 0
            pauseCounter = pauseFrames
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let fadeWidth: CGFloat = 20

        let img = NSImage(size: bounds.size, flipped: false) { imgRect in
            let y = (imgRect.height - self.textFont.ascender + self.textFont.descender) / 2

            let gap = self.textGap

            if let attr = self.attrText {
                attr.draw(at: NSPoint(x: -self.offset, y: y))
                if self.textWidth > imgRect.width {
                    attr.draw(at: NSPoint(x: -self.offset + self.textWidth + gap, y: y))
                }
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: self.textFont,
                    .foregroundColor: NSColor.headerTextColor
                ]
                let str = self.tickerText as NSString
                str.draw(at: NSPoint(x: -self.offset, y: y), withAttributes: attrs)
                if self.textWidth > imgRect.width {
                    str.draw(at: NSPoint(x: -self.offset + self.textWidth + gap, y: y), withAttributes: attrs)
                }
            }
            return true
        }

        let maskImage = CGImage.fadeMask(size: bounds.size, fadeWidth: fadeWidth)
        ctx.saveGState()
        if let maskImg = maskImage { ctx.clip(to: bounds, mask: maskImg) }
        img.draw(in: bounds)
        ctx.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }
}

extension CGImage {
    static func fadeMask(size: NSSize, fadeWidth: CGFloat) -> CGImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let left = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(left, start: .zero, end: CGPoint(x: fadeWidth, y: 0), options: [])

        let right = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(right, start: CGPoint(x: CGFloat(w) - fadeWidth, y: 0),
            end: CGPoint(x: CGFloat(w), y: 0), options: [])

        return ctx.makeImage()
    }
}
