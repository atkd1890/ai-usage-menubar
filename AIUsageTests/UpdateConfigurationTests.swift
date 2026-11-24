import Foundation
import XCTest
@testable import AIUsage

final class UpdateConfigurationTests: XCTestCase {
    func testSignedUpdateConfigurationIsEmbeddedInTheApp() {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://raw.githubusercontent.com/burakgon/ai-usage-menubar/main/appcast.xml"
        )
        XCTAssertEqual(
            info?["SUPublicEDKey"] as? String,
            "Axec4KdnVCK/H0z6UrhigcI44LRzdrN8vnBxIvqPurc="
        )
        XCTAssertEqual(info?["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info?["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info?["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info?["SUScheduledCheckInterval"] as? Int, 86_400)
    }

    func testUpstreamNoticeHidesSyncedAndOlderVersionsUntilNewerReleaseAppears() {
        XCTAssertEqual(UpdateController.syncedUpstreamVersion, "0.5.0")

        for suppressed in [nil, "", "   ", "0.4.0", "0.4.9", "0.5", "0.5.0", "v0.5.0", "0.5.0-beta.1", "abc", "0..5"] {
            XCTAssertNil(UpdateController.visibleUpstreamVersion(suppressed), "Expected nil for \(String(describing: suppressed))")
        }

        for expected in ["0.5.1", "0.6.0", "0.10.0", "1.0.0", "v0.5.1", "0.5.1-beta.1"] {
            XCTAssertEqual(UpdateController.visibleUpstreamVersion(expected), expected)
        }
        XCTAssertEqual(UpdateController.visibleUpstreamVersion("  0.5.1  "), "0.5.1")
        XCTAssertTrue(UpdateController.isVersion("0.5.0", newerThan: "0.5.0-beta.1"))
    }
}
