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

    /// Full fetch with method, headers, body, and caching.
    func fetch(_ request: FetchRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        // Enforce HTTPS for all requests
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" else {
            completion(.failure(URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Only HTTPS requests are allowed"])))
            return
        }

        let key = "\(request.method):\(request.url.absoluteString)"

        // Check cache
        var cached: CachedResponse?
        cacheQueue.sync { cached = cache[key] }

        if let cached = cached, Date().timeIntervalSince(cached.timestamp) < request.maxAge {
            completion(.success(cached.data))
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
                    completion(.success(cached.data))
                } else {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }

            self?.cacheQueue.sync {
                self?.cache[key] = CachedResponse(data: data, timestamp: Date())
            }
            completion(.success(data))
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
