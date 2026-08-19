import Foundation

class DataFetcher {
    static let shared = DataFetcher()

    private let session: URLSession
    private var cache: [String: CachedResponse] = [:]
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
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Simple GET fetch with caching (existing API).
    func fetch(url: URL, maxAge: TimeInterval = 60, completion: @escaping (Result<Data, Error>) -> Void) {
        fetch(FetchRequest(url: url, maxAge: maxAge), completion: completion)
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

        // Check cache
        var cached: CachedResponse?
        cacheQueue.sync { cached = cache[key] }

        if let cached = cached, Date().timeIntervalSince(cached.timestamp) < request.maxAge {
            DataFetcher.deliver(.success(cached.data), to: completion)
            return
        }

        var urlReq = URLRequest(url: request.url)
        urlReq.httpMethod = request.method
        urlReq.httpBody = request.body
        for (k, v) in request.headers {
            urlReq.setValue(v, forHTTPHeaderField: k)
        }

        session.dataTask(with: urlReq) { [weak self] data, response, error in
            if let error = error {
                if let cached = cached {
                    DataFetcher.deliver(.success(cached.data), to: completion)
                } else {
                    DataFetcher.deliver(.failure(error), to: completion)
                }
                return
            }

            // A throttled or failing endpoint still returns a body ("Too Many
            // Requests"), so without this check that body was treated as a good
            // response and cached, which quietly served garbage to the parsers
            // for the whole cache window.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                DataFetcher.deliver(.failure(HTTPError(statusCode: http.statusCode,
                                                 host: request.url.host ?? request.url.absoluteString)), to: completion)
                return
            }

            guard let data = data else {
                DataFetcher.deliver(.failure(URLError(.badServerResponse)), to: completion)
                return
            }

            self?.cacheQueue.sync {
                self?.cache[key] = CachedResponse(data: data, timestamp: Date())
            }
            DataFetcher.deliver(.success(data), to: completion)
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
