import XCTest
@testable import Barista

final class AppInstanceLockTests: XCTestCase {
    func testOnlyOneProcessCanOwnTheNativeAppAndTerminationReleasesOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: AppInstanceLock? = try XCTUnwrap(AppInstanceLock(directory: directory))
        XCTAssertNotNil(first)
        XCTAssertNil(try AppInstanceLock(directory: directory), "Opening a build copy must not create a second menu-bar app")
        first = nil
        let reopened = try XCTUnwrap(AppInstanceLock(directory: directory))
        try withExtendedLifetime(reopened) {
            XCTAssertNil(try AppInstanceLock(directory: directory))
        }
    }
}
