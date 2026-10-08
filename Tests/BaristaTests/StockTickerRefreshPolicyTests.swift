import XCTest
@testable import Barista

final class StockTickerRefreshPolicyTests: XCTestCase {
    func testLegacyConfigurationDefaultsToStandardRefresh() throws {
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(StockTickerConfig.default)) as? [String: Any])
        encoded.removeValue(forKey: "refreshMode")
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let config = try JSONDecoder().decode(StockTickerConfig.self, from: data)
        XCTAssertEqual(config.refreshMode, .standard)
    }

    func testRefreshModeIsPersistedAndReschedulesTheWidget() {
        let widget = StockTickerWidget(config: StockTickerConfig(symbols: [], coins: []),
                                       notificationsEnabled: false)
        let changed = expectation(description: "refresh mode persisted")
        let observer = NotificationCenter.default.addObserver(
            forName: .baristaWidgetConfigChanged, object: widget, queue: nil
        ) { _ in changed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        widget.setRefreshMode(.ultraFast)

        XCTAssertEqual(widget.config.refreshMode, .ultraFast)
        XCTAssertEqual(widget.stockInterval(during: .open), 2)
        XCTAssertTrue(widget.refreshModeSummary.contains("poll every 2s"))
        wait(for: [changed], timeout: 1)
    }

    func testStreamMappingIsLimitedToSupportedUSDCoins() {
        XCTAssertEqual(StockTickerRefreshPolicy.streamPairs(coins: ["bitcoin", "ethereum"], currency: "USD"),
                       ["BTC/USD", "ETH/USD"])
        XCTAssertEqual(StockTickerRefreshPolicy.streamPairs(coins: ["bitcoin", "not-a-coin"], currency: "usd"),
                       ["BTC/USD"])
        XCTAssertTrue(StockTickerRefreshPolicy.streamPairs(coins: ["bitcoin"], currency: "eur").isEmpty)
    }

    func testKrakenTickerParserAcceptsTickerUpdatesAndRejectsUnknownOrInvalidRows() throws {
        let message = #"{"channel":"ticker","type":"update","data":[{"symbol":"BTC/USD","last":65000.5,"change_pct":2.3,"high":66000,"low":64000,"volume":1234.5,"timestamp":"2026-10-07T14:30:00.000Z"},{"symbol":"UNKNOWN/USD","last":12,"change_pct":1},{"symbol":"ETH/USD","last":"NaN","change_pct":1}]}"#
        let updates = KrakenTickerMessageParser.parse(Data(message.utf8))
        let update = try XCTUnwrap(updates.first)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(update.coinID, "bitcoin")
        XCTAssertEqual(update.symbol, "BTC")
        XCTAssertEqual(update.price, 65000.5)
        XCTAssertEqual(update.changePercent, 2.3)
        XCTAssertEqual(update.timestamp, ISO8601DateFormatter().date(from: "2026-10-07T14:30:00Z"))
    }

    func testKrakenParserIgnoresSubscriptionAcknowledgementsAndMalformedMessages() {
        let acknowledgement = #"{"method":"subscribe","result":{"channel":"ticker","symbol":"BTC/USD","success":true}}"#
        XCTAssertTrue(KrakenTickerMessageParser.parse(Data(acknowledgement.utf8)).isEmpty)
        XCTAssertTrue(KrakenTickerMessageParser.parse(Data("not json".utf8)).isEmpty)
        let invalidBooleanPrice = #"{"channel":"ticker","type":"update","data":[{"symbol":"BTC/USD","last":true,"change_pct":1}]}"#
        XCTAssertTrue(KrakenTickerMessageParser.parse(Data(invalidBooleanPrice.utf8)).isEmpty)
    }

    func testRestFallbackResumesAfterStreamSilenceAndPreservesNewerStreamValues() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = StockTickerRefreshPolicy.recentlyStreamedCoinIDs(
            ["bitcoin", "ethereum"],
            receivedAt: ["bitcoin": now.addingTimeInterval(-10)],
            now: now
        )
        XCTAssertEqual(recent, ["bitcoin"])
        XCTAssertTrue(StockTickerRefreshPolicy.shouldApplyRESTUpdate(
            requestStartedAt: now, lastStreamReceivedAt: now.addingTimeInterval(1)
        ) == false)
        XCTAssertTrue(StockTickerRefreshPolicy.shouldApplyRESTUpdate(
            requestStartedAt: now, lastStreamReceivedAt: now.addingTimeInterval(-1)
        ))
        XCTAssertTrue(StockTickerRefreshPolicy.shouldApplyRESTUpdate(requestStartedAt: now, lastStreamReceivedAt: nil))
    }

    func testCryptoChartUsesItsTwentyFourHourSeriesRegardlessOfEquityMarketHours() {
        let quote = MarketQuote(symbol: "BTC", price: 102, change: 2, kind: .crypto,
                                sparkline: [100, 101, 102])
        XCTAssertEqual(quote.chartSeries, [100, 101, 102])
    }

    func testStreamingSummaryExplainsThePracticalCadence() {
        XCTAssertTrue(StockTickerRefreshPolicy.summary(for: .ultraFast, currency: "USD").contains("crypto streams live"))
        XCTAssertTrue(StockTickerRefreshPolicy.summary(for: .ultraFast, currency: "EUR").contains("crypto polls every 15s"))
    }

    func testReconnectDelayGrowsExponentiallyAndCaps() {
        XCTAssertEqual((1...6).map { KrakenReconnectPolicy.delay(afterFailureCount: $0) }, [1, 2, 4, 8, 16, 30])
        XCTAssertEqual(KrakenReconnectPolicy.delay(afterFailureCount: 10), 30)
    }
}
