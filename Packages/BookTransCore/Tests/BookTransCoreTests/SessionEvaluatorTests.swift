import XCTest
@testable import BookTransCore

/// The decision table for "may we make requests". Every branch here was a possible
/// cause of the reported failure — signed in, and the app still said no — so each
/// one is pinned rather than left to a successful compile.
final class SessionEvaluatorTests: XCTestCase {
    private func parameters(at: String = "", bl: String = "boq_build", sid: String = "1234")
    -> WizParameters {
        WizParameters(at: at, bl: bl, sessionId: sid)
    }

    private let appHost = "gemini.google.com"
    private let signedInCookies: Set<String> = ["__Secure-1PSID", "__Secure-1PSIDTS", "SID"]

    // MARK: - The regression

    func testSignedInWithoutTheAccessTokenIsStillSignedIn() {
        // Google stopped serving SNlM0e in the /app HTML in early 2026. Requiring it
        // is what made a signed-in user look signed out.
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(at: ""), host: appHost,
                                      cookieNames: signedInCookies),
            .signedIn)
    }

    func testTheTokenAloneDecidesNothing() {
        // Present or absent, the token does not change the verdict in either
        // direction: the sign-in page carries one of its own.
        let without = SessionEvaluator.evaluate(parameters: parameters(at: ""), host: appHost,
                                                cookieNames: signedInCookies)
        let with = SessionEvaluator.evaluate(parameters: parameters(at: "TOKEN"), host: appHost,
                                             cookieNames: signedInCookies)
        XCTAssertEqual(without, with)
    }

    // MARK: - Rejections

    func testMissingSessionParametersAreRejected() {
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(bl: "", sid: ""), host: appHost,
                                      cookieNames: signedInCookies),
            .missingParameters)
        // A token without the parameters a request needs is not a session.
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(at: "TOKEN", bl: "", sid: ""),
                                      host: appHost, cookieNames: signedInCookies),
            .missingParameters)
    }

    func testParametersFromAnotherHostAreRejected() {
        // The sign-in page serves its own SNlM0e and FdrFJe, so reading them there
        // would look like success while the app is not signed in.
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(at: "TOKEN"),
                                      host: "accounts.google.com",
                                      cookieNames: signedInCookies),
            .wrongHost("accounts.google.com"))
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(), host: "", cookieNames: []),
            .wrongHost(""), "an empty host is a wrong host, and is reported as one")
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(bl: "", sid: ""), host: "",
                                      cookieNames: []),
            .missingParameters, "missing parameters are reported before the host is judged")
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(), host: "gemini.google.com.evil.test",
                                      cookieNames: signedInCookies),
            .wrongHost("gemini.google.com.evil.test"),
            "a suffix match must not accept a lookalike host")
    }

    func testWithoutAGoogleSessionCookieNothingIsSignedIn() {
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(), host: appHost,
                                      cookieNames: ["NID", "__Host-GAPS"]),
            .missingCookies)
        XCTAssertEqual(
            SessionEvaluator.evaluate(parameters: parameters(), host: appHost, cookieNames: []),
            .missingCookies)
    }

    // MARK: - Combinations

    func testEveryCombinationOfTheThreeSignals() {
        let parameterSets = [parameters(), parameters(at: "T")]
        let hosts = [appHost, "accounts.google.com"]
        let cookies: [Set<String>] = [signedInCookies, ["NID"]]

        for p in parameterSets {
            for host in hosts {
                for cookieSet in cookies {
                    let verdict = SessionEvaluator.evaluate(parameters: p, host: host,
                                                            cookieNames: cookieSet)
                    let expected: SessionVerdict = (host == appHost && cookieSet == signedInCookies)
                        ? .signedIn
                        : (host == appHost ? .missingCookies : .wrongHost(host))
                    XCTAssertEqual(verdict, expected,
                                   "host=\(host) cookies=\(cookieSet.count) at=\(p.at)")
                }
            }
        }
    }

    func testVerdictReportsWhetherItIsSignedIn() {
        XCTAssertTrue(SessionVerdict.signedIn.isSignedIn)
        for verdict in [SessionVerdict.missingParameters, .wrongHost("x"), .missingCookies] {
            XCTAssertFalse(verdict.isSignedIn)
        }
    }

    func testAnyKnownGoogleSessionCookieIsEnough() {
        for cookie in SessionEvaluator.sessionCookies {
            XCTAssertEqual(
                SessionEvaluator.evaluate(parameters: parameters(), host: appHost,
                                          cookieNames: [cookie]),
                .signedIn, cookie)
        }
    }
}
