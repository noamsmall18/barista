import Foundation

/// Pure HTTP framing and authorization for the local research server.
enum ResearchWorkspaceRequest {
    static func validResearchSymbol(_ symbol: String) -> Bool {
        symbol.range(of: "^[A-Z0-9^][A-Z0-9.^=-]{0,29}$", options: .regularExpression) != nil
    }
    /// Wait for a complete, bounded body before routing fragmented POSTs.
    static func requestLength(_ data: Data) -> Int? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)), separator.upperBound <= 16_384,
              let text = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lengths = text.components(separatedBy: "\r\n").dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "content-length" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard lengths.count <= 1 else { return nil }
        let raw = lengths.first ?? "0"
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let bodyLength = Int(raw), bodyLength <= 245_760 else { return nil }
        return separator.upperBound + bodyLength
    }

    /// Strict same-origin request gate prevents websites from reading holdings
    /// through cross-origin requests or DNS rebinding to this loopback listener.
    static func authorizedPath(request: Data, origin: String, token: String) -> URLComponents? {
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[2] == "HTTP/1.1",
              requestLength(request) == request.count else { return nil }
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
              let parts = URLComponents(string: String(first[1])),
              parts.scheme == nil, parts.host == nil,
              parts.path.hasPrefix("/\(token)/") else { return nil }
        if first[0] == "POST" {
            guard parts.path == "/\(token)/workspace", headers["origin"] == origin,
                  headers["content-type"] == "application/json",
                  let length = headers["content-length"], Int(length) ?? 0 > 0 else { return nil }
        } else {
            guard headers["content-length"] == nil || headers["content-length"] == "0" else { return nil }
        }
        return parts
    }

}
