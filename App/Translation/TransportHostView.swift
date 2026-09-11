import SwiftUI
import WebKit
import BookTransCore

/// Keeps the transport's WebView in the view hierarchy at 1x1.
///
/// A detached `WKWebView` has its JavaScript timers throttled, which would stall
/// the `fetch` abort timer and any page work, so the transport's WebView lives
/// here for the whole session. It is deliberately not interactive: the login
/// screen has its own WebView, because a view can only have one superview and
/// moving this one into a sheet would leave it unmounted afterwards.
struct TransportHostView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.isUserInteractionEnabled = false
    }
}

/// Sheet used to sign in to Google.
///
/// It runs its own WebView over the same `WKWebsiteDataStore.default()`, so the
/// cookies it collects are exactly the ones the transport's requests read. Two
/// WebViews sharing a data store share the session; nothing else is shared.
struct GeminiLoginSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var webView = GeminiLoginSheet.makeWebView()
    @State private var isWorking = false

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return webView
    }

    var body: some View {
        NavigationStack {
            LoginWebView(webView: webView, startURL: app.gemini.config.appURL)
                .background(Theme.background)
                .navigationTitle("Вход в Gemini")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Закрыть") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                isWorking = true
                                let ok = await app.gemini.refreshSession(force: true)
                                if ok { await app.gemini.refreshAccountStatus() }
                                isWorking = false
                                if app.gemini.signInState == .signedIn {
                                    if app.queue.status == .waitingAuth,
                                       let bookId = app.queue.activeBookId {
                                        app.queue.resume(bookId: bookId)
                                    }
                                    dismiss()
                                } else {
                                    app.show("Вход не подтверждён — войдите в аккаунт Google",
                                             kind: .error)
                                }
                            }
                        } label: {
                            if isWorking {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Проверить вход")
                            }
                        }
                        .disabled(isWorking)
                    }
                }
        }
    }
}

/// Interactive WebView that loads the Gemini app once.
private struct LoginWebView: UIViewRepresentable {
    let webView: WKWebView
    let startURL: String

    func makeUIView(context: Context) -> WKWebView {
        if webView.url == nil, let url = URL(string: startURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
