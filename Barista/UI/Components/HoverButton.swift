import Cocoa

class HoverButton: NSButton {
    var normalBg: NSColor = .clear
    var hoverBg: NSColor = .clear

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverBg.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = normalBg.cgColor
    }
}
