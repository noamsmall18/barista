import XCTest
@testable import Barista

final class NativeAppInstallationTests: XCTestCase {
    func testCanonicalInstalledAppCanStart() {
        for flavor in [AppFlavor.marketbar, .barista] {
            XCTAssertEqual(NativeAppInstallation.launchAction(for: flavor,
                bundleURL: NativeAppInstallation.canonicalURL(for: flavor),
                installedBundleIdentifier: flavor.defaultsSuite), .run)
        }
    }

    func testOtherAppCopiesRedirectToVerifiedInstalledApp() {
        for path in ["/Users/example/Downloads/Marketbar.app", "/tmp/Marketbar.app", "/repo/dist/Marketbar.app"] {
            XCTAssertEqual(NativeAppInstallation.launchAction(for: .marketbar,
                bundleURL: URL(fileURLWithPath: path), installedBundleIdentifier: AppFlavor.marketbar.defaultsSuite),
                .openInstalled(NativeAppInstallation.canonicalURL(for: .marketbar)))
        }
    }

    func testMissingOrUnrelatedInstalledAppCannotStartAnAlternateCopy() {
        for identifier in [nil, AppFlavor.barista.defaultsSuite, "com.example.other"] {
            XCTAssertEqual(NativeAppInstallation.launchAction(for: .marketbar,
                bundleURL: URL(fileURLWithPath: "/tmp/Marketbar.app"), installedBundleIdentifier: identifier),
                .needsInstallation(NativeAppInstallation.canonicalURL(for: .marketbar)))
        }
    }

    func testRawExecutablesAndResearchBundlesAreNotRedirected() {
        for path in ["/repo/.build/release/Barista", "/tmp/MarketbarResearch.bundle"] {
            XCTAssertEqual(NativeAppInstallation.launchAction(for: .marketbar,
                bundleURL: URL(fileURLWithPath: path), installedBundleIdentifier: nil), .run)
        }
    }
}
