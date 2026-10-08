import XCTest
import Foundation
@testable import Barista

final class DataFetcherTransportTests: XCTestCase {
    private func fetcher() -> DataFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuoteTransportStub.self]
        return DataFetcher(configuration: configuration)
    }

    func testOverlappingQuoteRequestsShareOneTransportRequest() {
        let client = fetcher()
        let complete = expectation(description: "both quote consumers")
        complete.expectedFulfillmentCount = 2
        let url = URL(string: "https://quotes.example/coalesce")!
        for _ in 0..<2 {
            client.fetch(url: url, maxAge: 0, allowStaleCache: false) { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(try? result.get(), Data("1".utf8), "the transport count must stay one")
                complete.fulfill()
            }
        }
        wait(for: [complete], timeout: 3)
    }

    func testExplicitRefreshUsesNetworkAndSkipsProtocolCache() {
        let client = fetcher()
        let complete = expectation(description: "fresh quote")
        let url = URL(string: "https://quotes.example/refresh")!
        client.fetch(url: url, maxAge: 60, allowStaleCache: false) { result in
            XCTAssertEqual(try? result.get(), Data("1".utf8))
            client.fetch(url: url, maxAge: 0, allowStaleCache: false) { result in
                XCTAssertEqual(try? result.get(), Data("2".utf8))
                complete.fulfill()
            }
        }
        wait(for: [complete], timeout: 3)
    }

    func testRateLimitPreservesProviderRetryDelay() {
        let client = fetcher()
        let complete = expectation(description: "rate limit")
        client.fetch(url: URL(string: "https://quotes.example/throttle")!, allowStaleCache: false) { result in
            guard case .failure(let error) = result, let http = error as? DataFetcher.HTTPError else {
                XCTFail("429 must be an HTTP error"); complete.fulfill(); return
            }
            XCTAssertTrue(http.isRateLimited)
            XCTAssertEqual(http.retryAfter, 120)
            complete.fulfill()
        }
        wait(for: [complete], timeout: 3)
    }

    func testRetryAfterSupportsHTTPDatesAndRejectsInvalidValues() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(DataFetcher.retryDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: now), 120)
        XCTAssertEqual(DataFetcher.retryDelay(" 30 ", now: now), 30)
        XCTAssertEqual(DataFetcher.retryDelay("Thu, 01 Jan 1970 00:00:00 GMT", now: now), 0)
        XCTAssertNil(DataFetcher.retryDelay("-1", now: now))
        XCTAssertNil(DataFetcher.retryDelay("nan", now: now))
        XCTAssertNil(DataFetcher.retryDelay("invalid", now: now))
    }
}

private final class QuoteTransportStub: URLProtocol {
    private static let queue = DispatchQueue(label: "barista.tests.quote-transport")
    private static var counts: [URL: Int] = [:]
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "quotes.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        let count = Self.queue.sync { () -> Int in
            Self.counts[url, default: 0] += 1
            return Self.counts[url]!
        }
        let throttle = url.path == "/throttle"
        let response = HTTPURLResponse(url: url, statusCode: throttle ? 429 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: throttle ? ["Retry-After": "120"] : nil)!
        Self.queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(String(count).utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { Self.queue.async { [self] in stopped = true } }
}
