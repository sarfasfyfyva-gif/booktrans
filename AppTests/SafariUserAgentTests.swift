import XCTest
import BookTransCore
@testable import BookTrans

/// The User-Agent is not cosmetic: Google refuses sign-in from browsers that are
/// "embedded in a different application", and a stock WKWebView User-Agent is
/// exactly that signature. These assertions pin the two tokens the stock one is
/// missing.
final class SafariUserAgentTests: XCTestCase {
    func testPresentsSafariRatherThanAnEmbeddedWebView() {
        let agent = SafariUserAgent.mobileSafari(systemVersion: "26.6.1")
        XCTAssertTrue(agent.contains("Safari/604.1"),
                      "a WKWebView's stock UA has no Safari/ token, which is what Google blocks on")
        XCTAssertTrue(agent.contains("Version/26.0"), "and no Version/ token either")
        XCTAssertTrue(agent.contains("AppleWebKit/605.1.15"))
        XCTAssertTrue(agent.hasPrefix("Mozilla/5.0 (iPhone;"))
    }

    func testReflectsTheReportedSystemVersion() {
        XCTAssertTrue(SafariUserAgent.mobileSafari(systemVersion: "26.6.1")
            .contains("CPU iPhone OS 26_6 like Mac OS X"))
        XCTAssertTrue(SafariUserAgent.mobileSafari(systemVersion: "18.0")
            .contains("CPU iPhone OS 18_0 like Mac OS X"))
        XCTAssertTrue(SafariUserAgent.mobileSafari(systemVersion: "26")
            .contains("CPU iPhone OS 26_0 like Mac OS X"),
            "a version without a minor component must still produce a valid UA")
    }

    func testSurvivesAnUnparseableSystemVersion() {
        let agent = SafariUserAgent.mobileSafari(systemVersion: "")
        XCTAssertTrue(agent.contains("Safari/604.1"))
        XCTAssertFalse(agent.contains("CPU iPhone OS  like"), agent)
    }
}
