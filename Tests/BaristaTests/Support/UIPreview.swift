import XCTest
import Cocoa

/// Optional bitmap previews of real views, written only when
/// `BARISTA_UI_PREVIEW_DIR` is set (`./test.sh --previews`).
///
/// Views are drawn over the window's own background so light text on the dark
/// theme is readable in the saved image.
enum UIPreview {
    static var directory: String? { ProcessInfo.processInfo.environment["BARISTA_UI_PREVIEW_DIR"] }

    static func save(_ view: NSView, named name: String,
                     background: NSColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1)) throws {
        guard let directory else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let flattened = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        flattened.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: flattened))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let area = NSRect(origin: .zero, size: view.bounds.size)
        (background.usingColorSpace(.deviceRGB) ?? background).setFill()
        area.fill()
        bitmap.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(flattened.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
