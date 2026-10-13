import XCTest
import Cocoa
@testable import Barista

@MainActor
final class TerminalChartHoverTests: XCTestCase {
    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func history(count: Int = 5, range: StockChartRange = .oneDay) -> StockPriceHistory {
        let start = Date(timeIntervalSince1970: 1_791_897_600)
        return StockPriceHistory(symbol: "TEST", range: range, currency: "USD", instrumentType: "EQUITY",
                                 companyName: nil, exchangeTimezone: "America/New_York", previousClose: 140,
                                 fetchedAt: start, points: (0..<count).map { index in
            StockPricePoint(date: start.addingTimeInterval(Double(index) * 60), open: 141.1,
                            high: 141.7, low: 141.4, close: 141.4 + Double(index) * 0.1, volume: 740)
        })
    }

    private func withChart(_ body: (TerminalStockChartView, StockTickerWidget, StockDetailPopoverController) throws -> Void) throws {
        _ = NSApplication.shared
        let quote = MarketQuote(symbol: "TEST", price: 141.4, change: 1, kind: .stock, sparkline: [140, 141, 141.4])
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: ["TEST"], coins: []),
                                       notificationsEnabled: false, initialQuotes: [quote])
        let detail = StockDetailPopoverController(widget: widget, quote: quote, fetchesRemoteData: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = detail.view
        defer { window.contentView = nil; window.close() }
        let chart = try XCTUnwrap(allViews(detail.view).compactMap { $0 as? TerminalStockChartView }.first)
        chart.update(history: history())
        try body(chart, widget, detail)
    }

    private func move(to fraction: CGFloat, in chart: TerminalStockChartView) throws {
        let local = NSPoint(x: 18 + fraction * (chart.bounds.width - 36), y: 100)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: chart.convert(local, to: nil),
                                                   modifierFlags: [], timestamp: 0, windowNumber: chart.window!.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        chart.mouseMoved(with: event)
    }

    func testTooltipRowsHaveSeparateSpaceForPriceTimestampAndOHLC() {
        let layout = TerminalChartHoverLayout(point: NSPoint(x: 220, y: 140),
                                             bounds: NSRect(x: 0, y: 0, width: 564, height: 236))
        XCTAssertGreaterThanOrEqual(layout.price.minY - layout.sample.maxY, 3)
        XCTAssertGreaterThanOrEqual(layout.sample.minY - layout.details.maxY, 3)
        for (rect, font) in [(layout.price, NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)),
                             (layout.sample, NSFont.systemFont(ofSize: 9, weight: .medium)),
                             (layout.details, NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular))] {
            XCTAssertTrue(layout.box.contains(rect))
            XCTAssertGreaterThanOrEqual(rect.height, NSAttributedString(string: "Oct 13 $141.40", attributes: [.font: font]).size().height)
        }
    }

    func testTooltipStaysInsideNarrowChartsAtBothEdgesAndTheMiddle() {
        for width: CGFloat in [564, 264, 180] {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 236)
            for x in [CGFloat(18), width / 2, width - 18] {
                let layout = TerminalChartHoverLayout(point: NSPoint(x: x, y: 210), bounds: bounds)
                XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(layout.box), "Tooltip escaped at width \(width), x \(x)")
            }
        }
    }

    func testHistoryRefreshKeepsInspectionUnderAStationaryPointer() throws {
        try withChart { chart, _, _ in
            try move(to: 0.5, in: chart)
            XCTAssertEqual(chart.hoverIndex, 2)
            chart.update(history: history())
            XCTAssertEqual(chart.hoverIndex, 2, "The five-second history refresh must not hide the readout")
            chart.update(history: history(count: 9))
            XCTAssertEqual(chart.hoverIndex, 4, "New bars must keep inspection aligned with the pointer")
            chart.update(history: history(count: 3))
            XCTAssertEqual(chart.hoverIndex, 1)
        }
    }

    func testQuoteOnlyRefreshRepositionsInspectionWhenFallbackSeriesGrows() throws {
        try withChart { chart, _, _ in
            chart.update(history: nil)
            try move(to: 0.5, in: chart)
            XCTAssertEqual(chart.hoverIndex, 1)
            chart.update(quote: MarketQuote(symbol: "TEST", price: 145, change: 1, kind: .stock,
                                            sparkline: [140, 141, 142, 143, 145]))
            XCTAssertEqual(chart.hoverIndex, 2)
        }
    }

    func testExitAndRangeChangesClearInspectionAndRefreshDoesNotResurrectIt() throws {
        try withChart { chart, _, _ in
            try move(to: 0.5, in: chart)
            let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                                          timestamp: 0, windowNumber: chart.window!.windowNumber,
                                                          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            chart.mouseExited(with: exit)
            chart.update(history: history())
            XCTAssertNil(chart.hoverIndex)
            try move(to: 0.5, in: chart)
            chart.update(history: history(range: .oneYear))
            XCTAssertNil(chart.hoverIndex)
            chart.update(history: history(range: .oneYear))
            XCTAssertNil(chart.hoverIndex)
        }
    }

    func testFallbackToLoadedHistoryPreservesHoverAndCanRenderPreview() throws {
        try withChart { chart, _, _ in
            chart.update(history: nil)
            try move(to: 0.5, in: chart)
            chart.update(history: history())
            XCTAssertEqual(chart.hoverIndex, 2)
            if let directory = ProcessInfo.processInfo.environment["BARISTA_UI_PREVIEW_DIR"] {
                let bitmap = try XCTUnwrap(chart.bitmapImageRepForCachingDisplay(in: chart.bounds))
                chart.cacheDisplay(in: chart.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("stock-chart-hover.png"))
            }
        }
    }
}
