import Cocoa
import Network

/// A private, read-only browser companion. Each running flavor gets its own
/// random loopback port and capability URL, tied to its live widget instance.
final class PortfolioWebServer {
    private weak var widget: StockTickerWidget?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let token = UUID().uuidString + UUID().uuidString
    private var openWhenReady = false
    private var isReady = false
    private var origin: String? { listener?.port.map { "http://127.0.0.1:\($0.rawValue)" } }
    private var researchCache: [String: (Date, Data)] = [:]
    private var researchPending: [String: [(Data) -> Void]] = [:]
    private var newsCache: [String: (Date, Data)] = [:]
    private var newsPending: [String: [(Data) -> Void]] = [:]

    init(widget: StockTickerWidget) { self.widget = widget }

    func open() {
        if isReady, let origin { NSWorkspace.shared.open(URL(string: "\(origin)/\(token)/")!); return }
        openWhenReady = true
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    if self.openWhenReady, let origin = self.origin {
                        self.openWhenReady = false
                        NSWorkspace.shared.open(URL(string: "\(origin)/\(self.token)/")!)
                    }
                case .failed(let error):
                    self.isReady = false
                    self.listener?.cancel(); self.listener = nil
                    let alert = NSAlert()
                    alert.messageText = "Couldn't open portfolio research"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
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
            let alert = NSAlert()
            alert.messageText = "Couldn't start portfolio research"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= 16_384 else { self.respond(connection, status: 413); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.route(connection, request: data)
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: data) }
        }
    }

    /// Strict same-origin request gate prevents websites from reading holdings
    /// through cross-origin requests or DNS rebinding to this loopback listener.
    static func authorizedPath(request: Data, origin: String, token: String) -> URLComponents? {
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return nil }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == String(origin.dropFirst("http://".count)),
              headers["origin"] == nil || headers["origin"] == origin,
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0",
              let parts = URLComponents(string: String(first[1])),
              parts.scheme == nil, parts.host == nil,
              parts.path.hasPrefix("/\(token)/") else { return nil }
        return parts
    }

    private func route(_ connection: NWConnection, request: Data) {
        guard let origin, let parts = Self.authorizedPath(request: request, origin: origin, token: token),
              let widget else { respond(connection, status: 403); return }
        let path = String(parts.path.dropFirst(token.count + 2))
        if path == "snapshot" {
            widget.dashboardHeartbeat()
            var payload = PortfolioWebSnapshot.make(config: widget.config, quotes: widget.sortedQuotes(), indices: widget.indexQuotes)
            payload["updatedAt"] = PortfolioWebSnapshot.number(widget.lastUpdated?.timeIntervalSince1970)
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
        if ["research", "news", "chart", "expectations"].contains(path) {
            guard let symbol = parts.queryItems?.first(where: { $0.name == "symbol" })?.value,
                  let quote = widget.quotes.first(where: { $0.symbol == symbol }), quote.kind == .stock else {
                respond(connection, status: 404); return
            }
            let finish: (Data) -> Void = { [weak self] data in self?.respond(connection, body: data, mime: "application/json") }
            switch path {
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
        let files = ["": ("index.html", "text/html"), "app.js": ("app.js", "text/javascript"), "style.css": ("style.css", "text/css")]
        guard let (file, mime) = files[path], let data = Self.asset(file) else { respond(connection, status: 404); return }
        respond(connection, body: data, mime: mime)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"error\":\"Unable to encode data\"}".utf8)
    }

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
