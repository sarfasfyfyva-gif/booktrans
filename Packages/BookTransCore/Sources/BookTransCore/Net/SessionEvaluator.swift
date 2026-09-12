import Foundation

/// Why a session was accepted or rejected.
///
/// This decision used to live inline in the app, which meant the single most
/// consequential branch in the product — "may we translate" — was covered by
/// nothing but a successful compile. It also held the bug that cost a device round
/// trip: the anti-CSRF token was required, and Google stopped serving it in 2026,
/// so a signed-in user was reported as signed out.
public enum SessionVerdict: Equatable, Sendable {
    case signedIn
    /// The page did not hand over `bl`/`f.sid`, so no request could be built.
    case missingParameters
    /// The parameters came from somewhere other than the Gemini app — most likely
    /// the sign-in page, which carries `SNlM0e` and `FdrFJe` of its own.
    case wrongHost(String)
    /// No Google session cookie in this WebView's own store, so nothing is signed in.
    case missingCookies

    public var isSignedIn: Bool { self == .signedIn }
}

public enum SessionEvaluator {
    /// The session cookies that mean "a Google account is signed in here".
    public static let sessionCookies: Set<String> = [
        "__Secure-1PSID", "__Secure-1PSID3P", "__Secure-3PSID", "SID",
    ]

    /// Decides whether the app may make requests.
    ///
    /// Deliberately says nothing about `SNlM0e`: Google stopped serving it in the
    /// `/app` HTML in early 2026, and the sign-in page carries one of its own, so
    /// the token is evidence in neither direction. What is checked is what Google
    /// did not change — the parameters a request needs, the host the page really
    /// came from, and the session cookie in this WebView's own store.
    public static func evaluate(
        parameters: WizParameters,
        host: String,
        cookieNames: Set<String>
    ) -> SessionVerdict {
        guard parameters.hasSessionParameters else { return .missingParameters }
        guard host == "gemini.google.com" || host.hasSuffix(".gemini.google.com") else {
            return .wrongHost(host)
        }
        guard !cookieNames.isDisjoint(with: sessionCookies) else { return .missingCookies }
        return .signedIn
    }
}
