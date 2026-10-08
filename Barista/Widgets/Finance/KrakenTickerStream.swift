import Foundation
import CoreFoundation

struct KrakenTickerUpdate {
    let coinID: String
    let symbol: String
    let price: Double
    let changePercent: Double
    let high: Double?
    let low: Double?
    let volume: Double?
    let timestamp: Date?
}

enum KrakenReconnectPolicy {
    static func delay(afterFailureCount count: Int) -> UInt64 {
        guard count > 0 else { return 1 }
        return min(UInt64(1) << min(count - 1, 5), 30)
    }
}

enum KrakenTickerMessageParser {
    static func parse(_ data: Data) -> [KrakenTickerUpdate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["channel"] as? String == "ticker",
              let rows = root["data"] as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let pair = row["symbol"] as? String,
                  let coinID = StockTickerRefreshPolicy.coinID(forPair: pair),
                  let price = number(row["last"]), price > 0,
                  let change = number(row["change_pct"]) else { return nil }
            let time = (row["timestamp"] as? String).flatMap(parseTimestamp)
            return KrakenTickerUpdate(coinID: coinID, symbol: String(pair.prefix(while: { $0 != "/" })),
                                      price: price, changePercent: change,
                                      high: number(row["high"]), low: number(row["low"]),
                                      volume: number(row["volume"]), timestamp: time)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { parsed = number.doubleValue }
        else if let string = value as? String { parsed = Double(string) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Small no-credential consumer for Kraken's public spot WebSocket v2 ticker.
/// Reconnect uses bounded exponential backoff, and changing/stopping the watchlist
/// cancels the current socket before a new subscription is opened.
final class KrakenTickerStream {
    private let endpoint = URL(string: "wss://ws.kraken.com/v2")!
    private let onUpdate: (KrakenTickerUpdate) -> Void
    private let onConnectionChange: (Bool) -> Void
    private var pairs: [String]
    private var socket: URLSessionWebSocketTask?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private(set) var isConnected = false

    init(pairs: [String], onUpdate: @escaping (KrakenTickerUpdate) -> Void,
         onConnectionChange: @escaping (Bool) -> Void = { _ in }) {
        self.pairs = pairs
        self.onUpdate = onUpdate
        self.onConnectionChange = onConnectionChange
    }

    func setPairs(_ pairs: [String]) {
        guard self.pairs != pairs else { return }
        self.pairs = pairs
        start()
    }

    func start() {
        guard !pairs.isEmpty else { stop(); return }
        stop()
        generation += 1
        let activeGeneration = generation
        let activePairs = pairs
        let endpoint = endpoint
        worker = Task { [weak self] in
            await Self.run(endpoint: endpoint, pairs: activePairs,
                           isCurrent: { [weak self] in self?.generation == activeGeneration },
                           setSocket: { [weak self] socket in
                               guard let self, self.generation == activeGeneration else {
                                   socket?.cancel(with: .goingAway, reason: nil)
                                   return
                               }
                               self.socket = socket
                           },
                           setConnected: { [weak self] connected in
                               guard let self, self.generation == activeGeneration else { return }
                               self.updateConnection(connected)
                           },
                           onUpdate: { [weak self] update in self?.onUpdate(update) })
        }
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        updateConnection(false)
    }

    private func updateConnection(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        onConnectionChange(connected)
    }

    @MainActor
    private static func run(endpoint: URL, pairs: [String],
                            isCurrent: @escaping () -> Bool,
                            setSocket: @escaping (URLSessionWebSocketTask?) -> Void,
                            setConnected: @escaping (Bool) -> Void,
                            onUpdate: @escaping (KrakenTickerUpdate) -> Void) async {
        var failureCount = 0
        while !Task.isCancelled, isCurrent() {
            let connection = URLSession.shared.webSocketTask(with: endpoint)
            setSocket(connection)
            connection.resume()
            do {
                let request: [String: Any] = [
                    "method": "subscribe",
                    "params": ["channel": "ticker", "symbol": pairs,
                               "event_trigger": "trades", "snapshot": true]
                ]
                let requestData = try JSONSerialization.data(withJSONObject: request)
                try await connection.send(.string(String(decoding: requestData, as: UTF8.self)))
                while !Task.isCancelled, isCurrent() {
                    let message = try await withTaskCancellationHandler {
                        try await connection.receive()
                    } onCancel: {
                        connection.cancel(with: .goingAway, reason: nil)
                    }
                    guard case .string(let text) = message else { continue }
                    let updates = KrakenTickerMessageParser.parse(Data(text.utf8))
                    if !updates.isEmpty {
                        failureCount = 0
                        setConnected(true)
                    }
                    for update in updates { onUpdate(update) }
                }
            } catch {
                connection.cancel(with: .goingAway, reason: nil)
            }
            setConnected(false)
            setSocket(nil)
            guard !Task.isCancelled, isCurrent() else { return }
            failureCount += 1
            let retryDelay = KrakenReconnectPolicy.delay(afterFailureCount: failureCount)
            try? await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
        }
    }
}
