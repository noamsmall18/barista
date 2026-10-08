import Foundation

class DataFetcher {
    static let shared = DataFetcher()

    private let session: URLSession
    private var cache: [String: CachedResponse] = [:]
    private var pending: [String: [(Result<Data, Error>) -> Void]] = [:]
    private let cacheQueue = DispatchQueue(label: "barista.datafetcher.cache")

    struct CachedResponse {
        let data: Data
        let timestamp: Date
    }

    /// A non-2xx reply. Worth its own type so callers can tell "the server is
    /// throttling us" apart from "the network is down" and back off accordingly.
    struct HTTPError: LocalizedError {
        let statusCode: Int
        let host: String
        var retryAfter: TimeInterval? = nil

        var isRateLimited: Bool { statusCode == 429 }

        var errorDescription: String? {
            isRateLimited ? "\(host) is rate limiting requests (429)"
                          : "\(host) returned HTTP \(statusCode)"
        }
    }

    /// Structured fetch request with method, headers, and body support.
    struct FetchRequest {
        let url: URL
        var method: String = "GET"
        var headers: [String: String] = [:]
        var body: Data? = nil
        var maxAge: TimeInterval = 60
        var allowStaleCache: Bool = true
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Allows deterministic transport tests without contacting a price provider.
    init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Simple GET fetch with caching (existing API).
    func fetch(url: URL, maxAge: TimeInterval = 60, allowStaleCache: Bool = true, completion: @escaping (Result<Data, Error>) -> Void) {
        fetch(FetchRequest(url: url, maxAge: maxAge, allowStaleCache: allowStaleCache), completion: completion)
    }

    /// Delivers every completion on the main queue.
    ///
    /// Widgets are main-thread objects: their callbacks mutate widget state and
    /// touch UI. Handing results back on URLSession's queue made every caller
    /// responsible for hopping threads itself, and a caller that forgot read a
    /// shared array while the main thread was writing it, which corrupted the
    /// array badly enough to abort the process. Delivering on main removes the
    /// whole class of mistake instead of fixing it one call site at a time.
    private static func deliver(_ result: Result<Data, Error>,
                                to completion: @escaping (Result<Data, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Full fetch with method, headers, body, and caching.
    func fetch(_ request: FetchRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        // Enforce HTTPS for all requests
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" else {
            DataFetcher.deliver(.failure(URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Only HTTPS requests are allowed"])), to: completion)
            return
        }

        let key = "\(request.method):\(request.url.absoluteString)"
            + ":" + request.headers.sorted { $0.key < $1.key }.description
            + ":" + (request.body?.base64EncodedString() ?? "")

        // Check cache
        var cached: CachedResponse?
        cacheQueue.sync { cached = cache[key] }

        if let cached = cached, Date().timeIntervalSince(cached.timestamp) < request.maxAge {
            DataFetcher.deliver(.success(cached.data), to: completion)
            return
        }

        // Coalesce overlapping polls so a slow response cannot multiply network
        // traffic when a dashboard requests a faster cadence.
        let requestKey = key + ":" + String(request.allowStaleCache)
            + (request.method.uppercased() == "GET" ? "" : ":" + UUID().uuidString)
        let shouldStart = cacheQueue.sync { () -> Bool in
            if pending[requestKey] != nil { pending[requestKey]?.append(completion); return false }
            pending[requestKey] = [completion]
            return true
        }
        guard shouldStart else { return }
        let finish: (Result<Data, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            let callbacks = self.cacheQueue.sync { self.pending.removeValue(forKey: requestKey) ?? [] }
            callbacks.forEach { Self.deliver(result, to: $0) }
        }
        var urlReq = URLRequest(url: request.url)
        // This client owns its cache TTL. URLSession's protocol cache must not
        // silently reuse an older quote when the caller asks for a fresh one.
        urlReq.cachePolicy = .reloadIgnoringLocalCacheData
        urlReq.httpMethod = request.method
        urlReq.httpBody = request.body
        for (k, v) in request.headers {
            urlReq.setValue(v, forHTTPHeaderField: k)
        }

        session.dataTask(with: urlReq) { [weak self] data, response, error in
            if let error = error {
                if request.allowStaleCache, let cached = cached {
                    finish(.success(cached.data))
                } else {
                    finish(.failure(error))
                }
                return
            }

            // A throttled or failing endpoint still returns a body ("Too Many
            // Requests"), so without this check that body was treated as a good
            // response and cached, which quietly served garbage to the parsers
            // for the whole cache window.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(HTTPError(statusCode: http.statusCode,
                                         host: request.url.host ?? request.url.absoluteString,
                                         retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))))
                return
            }

            guard let data = data else {
                finish(.failure(URLError(.badServerResponse)))
                return
            }

            self?.cacheQueue.sync {
                self?.cache[key] = CachedResponse(data: data, timestamp: Date())
            }
            finish(.success(data))
        }.resume()
    }

    /// Async/await fetch.
    func fetch(_ request: FetchRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            fetch(request) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Async/await JSON decode.
    func fetchJSON<T: Decodable>(_ request: FetchRequest, as type: T.Type) async throws -> T {
        let data = try await fetch(request)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
