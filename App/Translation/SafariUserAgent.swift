import Foundation
import UIKit

/// The User-Agent the app presents to Google.
///
/// Google refuses sign-in from browsers that are "embedded in a different
/// application" or "controlled through software automation"
/// (<https://support.google.com/accounts/answer/7675428>). A `WKWebView`'s stock
/// User-Agent advertises exactly that: it carries `Mobile/…` but no `Version/…`
/// and no `Safari/…` token, which is the classic embedded-browser signature.
///
/// Presenting mobile Safari's own User-Agent for this device's iOS version is what
/// lets a page inside a `WKWebView` complete a Google sign-in. The rest of the
/// fingerprint already matches Safari: WebKit is the same engine, and the request
/// is made by the page itself rather than by a native client.
enum SafariUserAgent {
    static func mobileSafari(systemVersion: String = UIDevice.current.systemVersion) -> String {
        let parts = systemVersion.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 26
        let minor = parts.count > 1 ? parts[1] : 0
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(major)_\(minor) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(major).0 Mobile/15E148 Safari/604.1"
    }
}
