import Cocoa
import Network

/// A private browser companion. Portfolio data is read-only; research notes
/// and view preferences have their own storage. Each running flavor gets its own
/// loopback port and capability URL, hosted by the independent research helper.
final class PortfolioWebServer {
    private weak var widget: StockTickerWidget?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let token: String
    private let preferredPort: UInt16?
    private var ready: ((URL) -> Void)?
    private var failed: ((Error) -> Void)?
    private var origin: String? { listener?.port.map { "http://127.0.0.1:\($0.rawValue)" } }
    private var researchCache: [String: (Date, Data)] = [:]
    private var researchPending: [String: [(Data) -> Void]] = [:]
    private var newsCache: [String: (Date, Data)] = [:]
    private var newsPending: [String: [(Data) -> Void]] = [:]

    init(widget: StockTickerWidget, token: String = UUID().uuidString + UUID().uuidString,
         preferredPort: UInt16? = nil) {
        self.widget = widget
        self.token = token
        self.preferredPort = preferredPort
    }

    func start(onReady: @escaping (URL) -> Void, onFailure: @escaping (Error) -> Void) {
        ready = onReady
        failed = onFailure
        listen(port: preferredPort)
    }

    private func listen(port: UInt16?) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let origin = self.origin, let url = URL(string: "\(origin)/\(self.token)/") {
                        self.ready?(url)
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    self.listener = nil
                    // A previous port may have been claimed since the helper stopped.
                    if port != nil { self.listen(port: nil) }
                    else { self.failed?(error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connections.count < 32 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { connection.stateUpdateHandler = nil; self?.connections.removeValue(forKey: id) }
                    if case .failed = state { connection.cancel() }
                }
                connection.start(queue: .main)
                self.receive(connection, data: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak connection] in connection?.cancel() }
            }
            listener.start(queue: .main)
        } catch {
            if port != nil { listen(port: nil) }
            else { failed?(error) }
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= 262_144 else { self.respond(connection, status: 413); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let length = Self.requestLength(data) else { self.respond(connection, status: 400); return }
                if data.count >= length { self.route(connection, request: data) }
                else if complete || error != nil { connection.cancel() }
                else { self.receive(connection, data: data) }
            } else if data.count > 16_384 { self.respond(connection, status: 413) }
            else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: data) }
        }
    }

    static func requestLength(_ data: Data) -> Int? {
        ResearchWorkspaceRequest.requestLength(data)
    }

    static func authorizedPath(request: Data, origin: String, token: String) -> URLComponents? {
        ResearchWorkspaceRequest.authorizedPath(request: request, origin: origin, token: token)
    }

    private func route(_ connection: NWConnection, request: Data) {
        guard let origin, let parts = Self.authorizedPath(request: request, origin: origin, token: token),
              let widget else { respond(connection, status: 403); return }
        let path = String(parts.path.dropFirst(token.count + 2))
        if path == "health" {
            respond(connection, body: Self.json(["service": "research-workspace", "pid": ProcessInfo.processInfo.processIdentifier]), mime: "application/json")
            return
        }
        if path == "workspace" {
            if request.starts(with: Data("POST ".utf8)) {
                guard let separator = request.range(of: Data("\r\n\r\n".utf8)),
                      ResearchWorkspaceStore.save(Data(request[separator.upperBound...])) else {
                    respond(connection, status: 400, body: Self.json(["error": "Invalid workspace update"]), mime: "application/json"); return
                }
                respond(connection, body: Self.json(["saved": true]), mime: "application/json")
            } else { respond(connection, body: Self.json(ResearchWorkspaceStore.load()), mime: "application/json") }
            return
        }
        if path == "snapshot" {
            widget.dashboardHeartbeat()
            var payload = PortfolioWebSnapshot.make(config: widget.config, quotes: widget.sortedQuotes(), indices: widget.indexQuotes)
            payload["updatedAt"] = PortfolioWebSnapshot.number(widget.lastUpdated?.timeIntervalSince1970)
            payload["standalone"] = true
            payload["servedAt"] = Date().timeIntervalSince1970
            payload["status"] = widget.freshnessDescription()
            payload["failedSymbols"] = Array(widget.failedSymbols).sorted()
            payload["stale"] = widget.isDataStale || widget.isUsingCachedData || widget.lastFetchFailed || !widget.failedSymbols.isEmpty
            payload["backoffSeconds"] = widget.backoffRemaining
            payload["pollSeconds"] = widget.refreshInterval ?? 5
            let intraday = widget.intradayPortfolioSeries() ?? []
            payload["intraday"] = intraday.map { [$0.date.timeIntervalSince1970, $0.value] }
            payload["benchmark"] = (widget.intradayBenchmarkSeries(matching: intraday.map(\.date), startingAt: intraday.first?.value ?? 0) ?? []).map { [$0.date.timeIntervalSince1970, $0.value] }
            payload["history"] = PortfolioHistoryService.shared.points(for: widget.config.activePortfolioID, range: .all)
                .map { [$0.time.timeIntervalSince1970, $0.value] }
            respond(connection, body: Self.json(payload), mime: "application/json")
            return
        }
        if ["research", "news", "chart", "expectations", "study-quote"].contains(path) {
            guard let symbol = parts.queryItems?.first(where: { $0.name == "symbol" })?.value,
                  ResearchWorkspaceRequest.validResearchSymbol(symbol),
                  widget.quotes.first(where: { $0.symbol == symbol })?.kind != .crypto else {
                respond(connection, status: 404); return
            }
            let finish: (Data) -> Void = { [weak self] data in self?.respond(connection, body: data, mime: "application/json") }
            switch path {
            case "study-quote":
                StockPriceHistoryService.shared.fetch(symbol: symbol, range: .oneDay) { result in
                    switch result {
                    case .success(let history):
                        guard history.instrumentType == "EQUITY" else {
                            finish(Self.json(["error": "Independent company research requires an equity ticker. Provider instrument type: \(history.instrumentType ?? "unavailable")."])); return
                        }
                        let latest = history.latest
                        let previous = history.previousClose
                        let change = latest.flatMap { point in previous.flatMap { $0 > 0 ? (point.close / $0 - 1) * 100 : nil } }
                        finish(Self.json(["symbol": symbol, "kind": "stock", "currency": history.currency,
                                          "price": Self.number(latest?.close), "change": Self.number(change),
                                          "previousClose": Self.number(previous), "quantity": 0,
                                          "session": "Last observed bar", "researchOnly": true,
                                          "company": history.companyName ?? symbol,
                                          "receivedAt": history.fetchedAt.timeIntervalSince1970,
                                          "observedAt": Self.number(latest?.date.timeIntervalSince1970),
                                          "sparkline": history.points.suffix(90).map(\.close)]))
                    case .failure(let error): finish(Self.json(["error": "Symbol unavailable: \(error.localizedDescription)"]))
                    }
                }
            case "research": fundamentals(symbol, completion: finish)
            case "news": news(symbol, completion: finish)
            case "expectations": AnalystExpectationsService.shared.fetch(symbol: symbol, completion: finish)
            default:
                guard let raw = parts.queryItems?.first(where: { $0.name == "range" })?.value,
                      let range = StockChartRange(rawValue: raw) else { respond(connection, status: 400); return }
                StockPriceHistoryService.shared.fetch(symbol: symbol, range: range) { result in
                    switch result {
                    case .success(let history):
                        finish(Self.json(["points": history.points.map { [$0.date.timeIntervalSince1970, $0.close] },
                                          "currency": history.currency, "updatedAt": history.fetchedAt.timeIntervalSince1970]))
                    case .failure(let error): finish(Self.json(["error": error.localizedDescription]))
                    }
                }
            }
            return
        }
        let files = ["": ("index.html", "text/html"), "app.js": ("app.js", "text/javascript"), "analytics.js": ("analytics.js", "text/javascript"), "desk-model.js": ("desk-model.js", "text/javascript"), "desk.js": ("desk.js", "text/javascript"), "style.css": ("style.css", "text/css"), "marketbar-logo.png": ("marketbar-logo.png", "image/png")]
        guard let (file, mime) = files[path], let data = Self.asset(file) else { respond(connection, status: 404); return }
        respond(connection, body: data, mime: mime)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"error\":\"Unable to encode data\"}".utf8)
    }

    private static func number(_ value: Double?) -> Any { PortfolioWebSnapshot.number(value) }

    static func asset(_ name: String) -> Data? {
        let resource = Bundle.main.resourceURL?.appendingPathComponent("Web").appendingPathComponent(name)
        if let resource, let data = try? Data(contentsOf: resource) { return data }
        #if SWIFT_PACKAGE
        if let root = Bundle.module.resourceURL {
            return try? Data(contentsOf: root.appendingPathComponent("Web").appendingPathComponent(name))
        }
        #endif
        return nil
    }

    private func respond(_ connection: NWConnection, status: Int = 200, body: Data = Data(), mime: String = "text/plain") {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime); charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func fundamentals(_ symbol: String, completion: @escaping (Data) -> Void) {
        if let (date, data) = researchCache[symbol], Date().timeIntervalSince(date) < 600 { completion(data); return }
        if researchPending[symbol] != nil { researchPending[symbol]?.append(completion); return }
        researchPending[symbol] = [completion]
        StockFundamentalsService.shared.fetch(symbol: symbol, maxAge: 900) { [weak self] result in
            guard let self else { return }
            let data: Data
            switch result {
            case .failure(let error): data = Self.json(["error": "SEC fundamentals unavailable: \(error.localizedDescription)"])
            case .success(let f):
                func metrics(_ values: [String: FundamentalMetricSeries]) -> [[String: Any]] {
                    values.values.sorted { $0.id < $1.id }.map { metric in
                        ["id": metric.id, "label": metric.label, "statement": metric.statement,
                         "unit": metric.unit, "concept": metric.sourceConcept,
                         "points": metric.points.map { p in
                            ["label": p.label, "value": PortfolioWebSnapshot.number(p.value), "filed": p.filedDate,
                             "end": p.endDate, "form": p.form] as [String: Any]
                         }] as [String: Any]
                    }
                }
                data = Self.json(["company": f.companyName, "cik": f.cik, "updatedAt": f.fetchedAt.timeIntervalSince1970,
                                  "annual": metrics(f.annualMetrics), "quarterly": metrics(f.quarterlyMetrics),
                                  "ratios": f.ratios.map { ["label": $0.label, "display": $0.display, "detail": $0.detail] }])
            }
            self.researchCache[symbol] = (Date(), data)
            let callbacks = self.researchPending.removeValue(forKey: symbol) ?? []
            callbacks.forEach { $0(data) }
        }
    }

    private func news(_ symbol: String, completion: @escaping (Data) -> Void) {
        if let (date, data) = newsCache[symbol], Date().timeIntervalSince(date) < 300 { completion(data); return }
        if newsPending[symbol] != nil { newsPending[symbol]?.append(completion); return }
        newsPending[symbol] = [completion]
        var parts = URLComponents(string: "https://feeds.finance.yahoo.com/rss/2.0/headline")!
        parts.queryItems = [.init(name: "s", value: symbol), .init(name: "region", value: "US"), .init(name: "lang", value: "en-US")]
        DataFetcher.shared.fetch(url: parts.url!, maxAge: 300) { [weak self] result in
            guard let self else { return }
            let data: Data
            switch result {
            case .failure(let error): data = Self.json(["error": error.localizedDescription])
            case .success(let raw):
                let feed = ResearchNewsParser()
                let parser = XMLParser(data: raw)
                parser.shouldResolveExternalEntities = false
                parser.delegate = feed
                data = parser.parse() ? Self.json(["items": feed.items, "updatedAt": Date().timeIntervalSince1970])
                    : Self.json(["error": "News feed unavailable"])
            }
            self.newsCache[symbol] = (Date(), data)
            let callbacks = self.newsPending.removeValue(forKey: symbol) ?? []
            callbacks.forEach { $0(data) }
        }
    }

    deinit { listener?.cancel(); connections.values.forEach { $0.cancel() } }
}

final class ResearchNewsParser: NSObject, XMLParserDelegate {
    private(set) var items: [[String: String]] = []
    private var item: [String: String]?
    private var field = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "item" { item = [:] }
        field = name
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if ["title", "link", "pubDate", "source"].contains(field), item != nil { item?[field, default: ""] += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let item, items.count < 15,
           let link = item["link"], URL(string: link)?.scheme == "https", !(item["title"] ?? "").isEmpty {
            items.append(item)
        }
        if name == "item" { item = nil }
        field = ""
    }
}
