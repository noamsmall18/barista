import Cocoa
import QuartzCore

/// Rasterize a quote tape only when its content changes. Core Animation moves
/// the cached layers, eliminating display-link callbacks, main-queue work and
/// new text/mask images on every frame. Quote fetching is independent of this.
final class TickerScrollView: NSView {
    private let tape = CALayer()
    private let firstCopy = CALayer()
    private let secondCopy = CALayer()
    private let fade = CAGradientLayer()
    private let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let textGap: CGFloat = 60
    private var attributedText = NSAttributedString(string: "Loading…")
    private var textWidth: CGFloat = 0
    private var pausedOffset: CGFloat = 0
    private(set) var isAnimating = false
    var speed: CGFloat = 0.3 {
        didSet {
            guard speed != oldValue else { return }
            preserveOffset()
            updateAnimation()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(tape)
        tape.addSublayer(firstCopy)
        tape.addSublayer(secondCopy)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        updateText("Loading…")
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateText(_ text: String) {
        updateAttributedText(NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: NSColor.headerTextColor]))
    }

    func updateAttributedText(_ text: NSAttributedString) {
        guard text != attributedText || textWidth == 0 else { return }
        preserveOffset()
        attributedText = text.copy() as! NSAttributedString
        renderText()
        updateAnimation()
        setAccessibilityLabel(text.string)
    }

    private func preserveOffset() {
        if let presentation = tape.presentation() { pausedOffset = max(0, -presentation.transform.m41) }
        tape.removeAnimation(forKey: "scroll")
        isAnimating = false
    }

    private func renderText() {
        textWidth = ceil(attributedText.size().width)
        guard textWidth > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: textWidth, height: bounds.height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: max(1, Int(ceil(size.width * scale))),
                                            pixelsHigh: max(1, Int(ceil(size.height * scale))),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        let y = (size.height - textFont.ascender + textFont.descender) / 2
        attributedText.draw(at: NSPoint(x: 0, y: y))
        NSGraphicsContext.restoreGraphicsState()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for copy in [firstCopy, secondCopy] {
            copy.contents = bitmap.cgImage
            copy.contentsScale = scale
            copy.frame = NSRect(origin: .zero, size: size)
        }
        secondCopy.frame.origin.x = textWidth + textGap
        tape.transform = CATransform3DIdentity
        tape.frame = NSRect(x: 0, y: 0, width: textWidth * 2 + textGap, height: size.height)
        CATransaction.commit()
    }

    private func updateAnimation() {
        let overflow = textWidth > bounds.width && bounds.width > 0
        let shouldAnimate = overflow && window != nil && !isHiddenOrHasHiddenAncestor
            && speed.isFinite && speed > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cycle = textWidth + textGap
        pausedOffset = overflow ? pausedOffset.truncatingRemainder(dividingBy: max(1, cycle)) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        secondCopy.isHidden = !overflow
        tape.transform = CATransform3DMakeTranslation(-pausedOffset, 0, 0)
        fade.frame = bounds
        let fraction = min(0.5, 20 / max(1, bounds.width))
        fade.locations = [0, NSNumber(value: Double(fraction)), NSNumber(value: Double(1 - fraction)), 1]
        layer?.mask = overflow ? fade : nil
        CATransaction.commit()
        guard shouldAnimate else { isAnimating = false; return }

        // Keep the original speed (points per 60-Hz frame) and 1.5s loop pause.
        let pointsPerSecond = Double(speed * 60)
        let travelTime = Double(cycle) / pointsPerSecond
        let duration = travelTime + 1.5
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -cycle, -cycle]
        animation.keyTimes = [0, NSNumber(value: travelTime / duration), 1]
        animation.calculationMode = .linear
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.beginTime = tape.convertTime(CACurrentMediaTime(), from: nil) - Double(pausedOffset) / pointsPerSecond
        tape.add(animation, forKey: "scroll")
        isAnimating = true
    }

    override func layout() {
        super.layout()
        preserveOffset()
        if firstCopy.frame.height != bounds.height { renderText() }
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        preserveOffset()
        renderText()
        updateAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderText()
    }

    override func viewDidHide() { super.viewDidHide(); preserveOffset(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
