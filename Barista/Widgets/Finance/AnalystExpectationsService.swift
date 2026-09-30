import Foundation

/// Public analyst snapshots are distinct from streaming quotes and SEC actuals.
final class AnalystExpectationsService {
    static let shared = AnalystExpectationsService()
    private var cache: [String: (Date, Data)] = [:]
    private var pending: [String: [(Data) -> Void]] = [:]

    func fetch(symbol: String, completion: @escaping (Data) -> Void) {
        if let (date, data) = cache[symbol], Date().timeIntervalSince(date) < 900 {
            completion(data); return
        }
        if pending[symbol] != nil { pending[symbol]?.append(completion); return }
        pending[symbol] = [completion]
        var payload: [String: Any] = ["source": "Nasdaq analyst feeds", "symbol": symbol]
        var remaining = 2
        var errors: [String] = []
        for (key, endpoint) in [("targets", "targetprice"), ("eps", "earnings-forecast")] {
            let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            guard let url = URL(string: "https://api.nasdaq.com/api/analyst/\(escaped)/\(endpoint)") else { continue }
            let request = DataFetcher.FetchRequest(url: url, headers: ["Accept": "application/json", "Origin": "https://www.nasdaq.com"], maxAge: 0, allowStaleCache: false)
            DataFetcher.shared.fetch(request) { result in
                switch result {
                case .success(let raw):
                    if let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                       let data = root["data"] as? [String: Any], !data.isEmpty {
                        payload[key] = data
                        payload[key + "RetrievedAt"] = Date().timeIntervalSince1970
                    } else { errors.append("\(key): provider returned no coverage") }
                case .failure(let error): errors.append("\(key): \(error.localizedDescription)")
                }
                remaining -= 1
                guard remaining == 0 else { return }
                payload["errors"] = errors
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
                // Failed calls are briefly cooled down; successful snapshots refresh in 15 minutes.
                self.cache[symbol] = (Date().addingTimeInterval(errors.isEmpty ? 0 : -840), data)
                let callbacks = self.pending.removeValue(forKey: symbol) ?? []
                callbacks.forEach { $0(data) }
            }
        }
    }
}
