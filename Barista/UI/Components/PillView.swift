import Cocoa

class PillView: NSView {
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
    }
}
