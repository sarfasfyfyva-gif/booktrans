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

    init(websiteDataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                configuration: configuration)
        webView.customUserAgent = nil    // keep the stock Safari UA
        webView.allowsBackForwardNavigationGestures = false
        self.webView = webView
        self.delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
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

    /// Reads `window.WIZ_global_data`, falling back to scraping the HTML for the
    /// parameter literals when the global is not populated.
    func readWizParameters(config: GeminiConfig) async throws -> WizParameters {
        let script = """
        const g = window.WIZ_global_data || {};
        const keys = arguments[0];
        const pick = (name) => {
          const value = g[name];
          return (typeof value === "string") ? value : "";
        };
        let at = pick(keys.at), bl = pick(keys.build), sid = pick(keys.session), hl = pick(keys.lang);
        if (!at || !bl || !sid) {
          const html = document.documentElement ? document.documentElement.innerHTML : "";
          const scrape = (name) => {
            const m = html.match(new RegExp('"' + name + '":"([^"]*)"'));
            return m ? m[1] : "";
          };
          at = at || scrape(keys.at);
          bl = bl || scrape(keys.build);
          sid = sid || scrape(keys.session);
          hl = hl || scrape(keys.lang);
        }
        const title = document.title || "";
        return JSON.stringify({ at, bl, sid, hl, title, href: location.href });
        """
        let arguments: [String: Any] = [
            "0": [
                "at": config.wizAt,
                "build": config.wizBuild,
                "session": config.wizSession,
                "lang": config.wizLang,
            ]
        ]
        let result = try await evaluate(script, arguments: arguments)
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            throw TransportError.badScriptResult
        }
        let params = WizParameters(
            at: object["at"] ?? "",
            bl: object["bl"] ?? "",
            sessionId: object["sid"] ?? "",
            language: (object["hl"]?.isEmpty == false ? object["hl"]! : "ru"))
        LogStore.shared.append(level: .info, event: "wiz.read", fields: [
            "signedIn": params.isSignedIn ? "1" : "0",
            "bl": params.bl,
            "href": object["href"] ?? "",
        ])
        if !params.at.isEmpty {
            LogStore.shared.registerSecret(params.at)
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
            // A page-level failure (CSP, navigation, offline) surfaces here.
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
        var ageSeconds: Int
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
                           ageSeconds: cookie.expiresDate.map { Int(now.timeIntervalSince($0)) } ?? 0,
                           domain: cookie.domain)
            }
            .sorted { $0.name < $1.name }
    }

    /// True when the rotating cookie is older than 20 minutes and should be
    /// refreshed before the next request.
    func shouldRotateCookies() async -> Bool {
        let cookies = await cookies()
        guard let rotating = cookies.first(where: { $0.name == "__Secure-1PSIDTS" }) else { return true }
        // `expiresDate` is in the future for session cookies; use the presence
        // of a fresh value rather than a hard clock, and rotate on a timer.
        return abs(rotating.ageSeconds) > 20 * 60
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
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func reset() {
        continuation = nil
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
