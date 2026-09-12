import Foundation
import WebKit
import BookTransCore

/// One HTTP call executed from inside the Gemini page.
struct TransportRequest: Sendable {
    var url: String
    var method: String = "POST"
    var headers: [String: String] = [:]
    var body: String?
    var timeout: TimeInterval = GeminiProtocol.requestTimeout
}

struct TransportResponse: Sendable {
    var status: Int
    var raw: String
    var errorText: String?

    var isSuccess: Bool { (200...299).contains(status) }
}

/// Drives a hidden `WKWebView` and runs `fetch` from inside the page.
///
/// All Gemini traffic goes through the page context, so:
/// * the request is same-origin — no CORS preflight and no custom headers
///   blocked by the browser;
/// * cookies, including the rotating `__Secure-1PSIDTS`, are WebKit's problem;
/// * the TLS and header fingerprint matches a real browser tab.
///
/// The alternative (reading cookies out of `WKWebsiteDataStore` and using
/// `URLSession`) is kept as a fallback and would live here too; see
/// docs/SPEC.md §7.6.
@MainActor
final class GeminiWebTransport {
    /// Kept alive for the whole session; also presented full size during login.
    let webView: WKWebView
    private let delegate: NavigationDelegate
    private let uiDelegate: InteractionDelegate

    init(websiteDataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                configuration: configuration)
        // Not `nil`: the stock WKWebView UA is the embedded-browser signature
        // Google refuses to sign in from. See SafariUserAgent.
        webView.customUserAgent = SafariUserAgent.mobileSafari()
        webView.allowsBackForwardNavigationGestures = false
        self.webView = webView
        self.delegate = NavigationDelegate()
        self.uiDelegate = InteractionDelegate()
        webView.navigationDelegate = delegate
        // Without a UI delegate WebKit drops `window.open` and `target="_blank"`
        // links on the floor — no window, no error, nothing. Google's sign-in flow
        // uses exactly those, so tapping "Sign in" looked like a dead button in an
        // otherwise live page. Loading such links in the same WebView keeps the
        // whole sign-in in the browsing context the app later reads its session from.
        webView.uiDelegate = uiDelegate
    }

    // MARK: - Navigation

    /// Loads a URL in the transport's WebView and resolves when it finishes.
    func load(_ urlString: String, timeout: TimeInterval = 60) async throws {
        guard let url = URL(string: urlString) else {
            throw TransportError.badURL(urlString)
        }
        delegate.reset()
        webView.load(URLRequest(url: url))
        try await delegate.waitForNavigation(timeout: timeout)
    }

    /// Reloads the Gemini app page so `WIZ_global_data` is refreshed.
    func reloadApp(config: GeminiConfig) async throws {
        try await load(config.appURL)
    }

    var currentURL: String? { webView.url?.absoluteString }

    // MARK: - Session parameters

    /// Reads the session parameters the page uses for its own requests.
    ///
    /// Four strategies, in order, because this single call decides whether the app
    /// can translate at all and each one has failed in the wild for a different
    /// reason:
    ///
    /// 1. `window.WIZ_global_data` — how the app itself reads them;
    /// 2. a scan of the inline scripts, where the same values also appear;
    /// 3. a scan of the document HTML;
    /// 4. a fresh same-origin `fetch` of the page, because the bootstrapped
    ///    document can be served without the parameters while the server-rendered
    ///    one always carries them.
    ///
    /// The key names are interpolated into the script rather than passed as
    /// `callAsyncJavaScript` arguments: the binding of named arguments is one
    /// more thing that can silently differ, and these are static configuration
    /// strings, not secrets.
    func readWizParameters(config: GeminiConfig) async throws -> WizParameters {
        let script = """
        const names = { at: "\(config.wizAt)", build: "\(config.wizBuild)",
                        session: "\(config.wizSession)", lang: "\(config.wizLang)" };

        // Inline data is JSON embedded in a script, so its quotes may be escaped
        // as \" . The backslash is built from its char code: written literally it
        // has to survive Swift's own unescaping as well as JavaScript's, and one
        // layer too few turns the pattern into a no-op that silently matches
        // nothing.
        const ESCAPED_QUOTE = String.fromCharCode(92) + '"';
        const plain = (text) => String(text || "").split(ESCAPED_QUOTE).join('"');
        const grab = (text, name) => {
          if (!text) { return ""; }
          const m = plain(text).match(new RegExp('"' + name + '"\\s*:\\s*"([^"]*)"'));
          return m ? m[1] : "";
        };
        const fromText = (text) => {
          const out = {};
          for (const role in names) { out[role] = grab(text, names[role]); }
          return out;
        };
        // What makes a find usable is what a request needs: `bl` and `f.sid`.
        // The anti-CSRF token is not part of this, in either direction: Google
        // stopped serving it in the /app HTML in early 2026, so requiring it threw
        // away a perfectly good session and reported a signed-in user as a guest.
        // A token on its own is not usable either, since no request can be built.
        const usable = (value) => Boolean(value && value.build && value.session);

        let result = {};
        let source = "";
        const remember = (value, name) => {
          if (!usable(value)) { return false; }
          result = value; source = name; return true;
        };

        // 1. the global the app itself uses
        const global = window.WIZ_global_data;
        if (global) {
          const out = {};
          for (const role in names) {
            const value = global[names[role]];
            out[role] = (typeof value === "string") ? value : "";
          }
          remember(out, "WIZ_global_data");
        }

        // 2. every inline script, in document order
        if (!usable(result)) {
          for (const script of Array.from(document.scripts || [])) {
            if (remember(fromText(script.textContent), "inline-script")) { break; }
          }
        }

        // 3. the document itself
        if (!usable(result)) {
          remember(fromText(document.documentElement ? document.documentElement.innerHTML : ""),
                   "document-html");
        }

        // 4. ask the server again, with the session cookies the page holds
        if (!usable(result)) {
          try {
            const response = await fetch(location.origin + "/app",
                                         { credentials: "include", redirect: "follow" });
            remember(fromText(await response.text()), "refetch");
          } catch (error) {
            if (!source) { source = "refetch-failed"; }
          }
        }

        // Diagnostics for the case where nothing was found: enough to tell an
        // unauthenticated page from a page whose parameters moved, plus whether the
        // optional token was on it, which explains the absence of `at` above.
        const html = document.documentElement ? document.documentElement.innerHTML : "";
        const page = String(html);
        return JSON.stringify({
          at: result.at || "", bl: result.build || "", sid: result.session || "",
          hl: result.lang || "", source: source,
          href: location.href, title: document.title || "",
          htmlLength: page.length,
          mentionsAt: page.indexOf(names.at) >= 0,
          mentionsBuild: page.indexOf(names.build) >= 0
        });
        """
        let result = try await evaluate(script, arguments: [:])
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TransportError.badScriptResult
        }
        func string(_ key: String) -> String { object[key] as? String ?? "" }

        let params = WizParameters(
            at: string("at"),
            bl: string("bl"),
            sessionId: string("sid"),
            language: string("hl").isEmpty ? "ru" : string("hl"),
            source: string("source").isEmpty ? "none" : string("source"))
        if params.hasAccessToken {
            LogStore.shared.registerSecret(params.at)
        }
        // This reports what the *page* gave up, not whether the user is signed in:
        // that needs the cookie store, and `at` is optional since 2026, so its
        // absence is logged but is not a failure.
        LogStore.shared.append(level: params.hasSessionParameters ? .info : .warn,
                               event: "wiz.read", fields: [
            "session": params.hasSessionParameters ? "1" : "0",
            "hasAt": params.hasAccessToken ? "1" : "0",
            "source": string("source"),
            "bl": params.bl,
            "sid": params.sessionId,
            "href": string("href"),
            "title": string("title"),
            "htmlLength": String(object["htmlLength"] as? Int ?? 0),
            "mentionsAt": (object["mentionsAt"] as? Bool) == true ? "1" : "0",
            "mentionsBuild": (object["mentionsBuild"] as? Bool) == true ? "1" : "0",
        ])
        if !params.hasSessionParameters {
            CoreLog.warn("session parameters not found on \(string("href")) (\(string("source")))")
        }
        return params
    }

    // MARK: - Requests

    /// Runs `fetch` inside the page and returns the raw body.
    func send(_ request: TransportRequest) async throws -> TransportResponse {
        let script = """
        const started = Date.now();
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        try {
          const response = await fetch(url, {
            method: method,
            credentials: "include",
            redirect: "follow",
            signal: controller.signal,
            headers: headers,
            body: body
          });
          const raw = await response.text();
          return JSON.stringify({ status: response.status, raw: raw, elapsedMs: Date.now() - started });
        } catch (error) {
          return JSON.stringify({ status: 0, raw: "", error: String(error), elapsedMs: Date.now() - started });
        } finally {
          clearTimeout(timer);
        }
        """
        var arguments: [String: Any] = [
            "url": request.url,
            "method": request.method,
            "headers": request.headers,
            "timeoutMs": Int(request.timeout * 1000),
        ]
        if let body = request.body {
            arguments["body"] = body
        } else {
            arguments["body"] = NSNull()
        }

        let result = try await evaluate(script, arguments: arguments)
        guard let text = result as? String, let data = text.data(using: .utf8) else {
            throw TransportError.badScriptResult
        }
        struct Payload: Decodable {
            var status: Int
            var raw: String
            var error: String?
            var elapsedMs: Int?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw TransportError.badScriptResult
        }
        LogStore.shared.append(level: payload.status == 0 ? .warn : .info, event: "transport.request", fields: [
            "url": LogStore.shared.redactedHost(request.url),
            "status": String(payload.status),
            "bytes": String(payload.raw.count),
            "ms": String(payload.elapsedMs ?? 0),
        ])
        if payload.status == 0 {
            // A page-level failure: offline, VPN off, timeout, CSP. The reason is
            // in `errorText` and the caller classifies it as a connectivity
            // problem rather than a protocol error.
            return TransportResponse(status: 0, raw: payload.raw,
                                     errorText: payload.error ?? "fetch failed")
        }
        return TransportResponse(status: payload.status, raw: payload.raw, errorText: payload.error)
    }

    /// `POST https://accounts.google.com/RotateCookies` from inside a Gemini
    /// page so WebKit refreshes `__Secure-1PSIDTS` itself. Best effort: a
    /// failure is logged and never blocks translation.
    func rotateCookies(config: GeminiConfig) async {
        do {
            let response = try await send(TransportRequest(
                url: config.rotateCookiesURL,
                method: "POST",
                headers: GeminiRequestBuilder.rotateCookiesHeaders(),
                body: GeminiRequestBuilder.rotateCookiesBody,
                timeout: 30))
            LogStore.shared.append(level: .info, event: "session.rotateCookies", fields: [
                "status": String(response.status),
            ])
        } catch {
            LogStore.shared.append(level: .warn, event: "session.rotateCookies failed",
                                   fields: ["error": "\(error)"])
        }
    }

    // MARK: - Cookies

    struct CookieInfo: Sendable {
        var name: String
        /// Seconds until expiry; 0 for a session cookie. WebKit does not expose
        /// a cookie's creation time, so this is the only age-like value there is.
        var expiresInSeconds: Int
        var domain: String
    }

    func cookies() async -> [CookieInfo] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let now = Date()
        return all
            .filter { $0.domain.contains("google.com") }
            .map { cookie in
                CookieInfo(name: cookie.name,
                           expiresInSeconds: cookie.expiresDate.map { Int($0.timeIntervalSince(now)) } ?? 0,
                           domain: cookie.domain)
            }
            .sorted { $0.name < $1.name }
    }

    func clearWebsiteData() async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let google = records.filter { $0.displayName.contains("google") }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: google) { continuation.resume() }
        }
        LogStore.shared.append(level: .info, event: "session.clearedWebsiteData",
                               fields: ["records": String(google.count)])
    }

    // MARK: - Script evaluation

    private func evaluate(_ body: String, arguments: [String: Any]) async throws -> Any? {
        let wrapped = "(async () => { \(body) })()"
        return try await webView.callAsyncJavaScript(
            wrapped, arguments: arguments, in: nil, contentWorld: .page)
    }
}

enum TransportError: LocalizedError {
    case badURL(String)
    case badScriptResult
    case navigationFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .badURL(let value): return "Некорректный адрес: \(value)"
        case .badScriptResult: return "Не удалось разобрать ответ страницы Gemini."
        case .navigationFailed(let reason): return "Не удалось открыть Gemini: \(reason)"
        case .timedOut: return "Превышено время ожидания Gemini."
        }
    }
}

/// Bridges `WKNavigationDelegate` callbacks into async continuations.
@MainActor
/// Keeps the user's page usable during sign-in.
///
/// The delegate's job is the popup case: WebKit refuses to open a new window unless
/// something handles the request, and refusing silently is what made the sign-in
/// button appear dead. Anything the page tries to open in a new window is loaded in
/// this one instead, which also keeps the resulting cookies in the store the app
/// reads from.
@MainActor
private final class InteractionDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            LogStore.shared.append(level: .info, event: "popup.loaded-in-place",
                                   fields: ["host": url.host ?? ""])
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// Google's consent and account pages ask for the camera-free defaults; without
    /// an answer the sheet stays empty.
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    /// Supersedes any in-flight wait. The earlier caller is resumed with an error
    /// instead of being left suspended forever.
    func reset() {
        resume(throwing: TransportError.navigationFailed("переход отменён новым запросом"))
    }

    func waitForNavigation(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resume(throwing: TransportError.timedOut)
            }
        }
    }

    private func resume(throwing error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(throwing: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(throwing: TransportError.navigationFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        resume(throwing: TransportError.navigationFailed(error.localizedDescription))
    }
}
