import XCTest
@testable import Barista

/// DataFetcher used to hand results back on the URLSession queue, leaving every
/// widget to hop threads itself. One that forgot read the quotes array while the
/// main thread was writing it, which corrupted the array's reference counts and
/// aborted the process.
///
/// Delivering on the main thread is now the contract the whole app relies on, so
/// it is pinned here. These use rejected URLs so nothing touches the network.
final class DataFetcherThreadingTests: XCTestCase {

    func testCompletionArrivesOnTheMainThreadForARejectedURL() {
        let done = expectation(description: "completion delivered")
        var wasMain = false

        // Plain http is refused before any request is made, so this exercises the
        // delivery path without leaving the machine.
        DataFetcher.shared.fetch(url: URL(string: "http://example.com")!) { _ in
            wasMain = Thread.isMainThread
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        XCTAssertTrue(wasMain, "widgets mutate their own state from here; it must be the main thread")
    }

    func testCompletionIsAlwaysAsynchronous() {
        let done = expectation(description: "completion delivered")
        var completedSynchronously = true

        DataFetcher.shared.fetch(url: URL(string: "http://example.com")!) { _ in
            done.fulfill()
        }
        // If the callback had fired inline, this line would run after it.
        completedSynchronously = false

        wait(for: [done], timeout: 5)
        XCTAssertFalse(completedSynchronously,
                       "a callback that is sometimes sync and sometimes async is its own bug source")
    }

    func testRejectedURLReportsAFailure() {
        let done = expectation(description: "completion delivered")
        var failed = false

        DataFetcher.shared.fetch(url: URL(string: "http://example.com")!) { result in
            if case .failure = result { failed = true }
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        XCTAssertTrue(failed, "only https is allowed")
    }
}
