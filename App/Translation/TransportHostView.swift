import SwiftUI
import WebKit
import BookTransCore

/// Keeps the transport's WebView in the view hierarchy at 1x1.
///
/// A detached `WKWebView` has its JavaScript timers throttled, which would stall
/// the `fetch` abort timer and any page work, so the transport's WebView lives
/// here for the whole session.
///
/// It is hosted inside a container so that the same WebView can be presented full
/// size for the Google sign-in and then come back here: `updateUIView` re-claims
/// it whenever the sheet has taken it. Signing in and then reading the session
/// from *one* WebView is the whole point — the session lives in that page, and
/// having two WebViews share a cookie store is a question that then never arises.
struct TransportHostView: UIViewRepresentable {
    let webView: WKWebView
    var interactive: Bool = false
    /// False while the login sheet is presenting this WebView: the 1x1 host must
    /// not pull it back on some unrelated re-render, or the page the user is
    /// signing in on would vanish mid-flow.
    var claimsOwnership: Bool = true

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.backgroundColor = .clear
        host.addSubview(webView)
        Self.pin(webView, to: host)
        webView.isUserInteractionEnabled = interactive
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        webView.isUserInteractionEnabled = interactive
        guard claimsOwnership, webView.superview !== host else { return }
        webView.removeFromSuperview()
        host.addSubview(webView)
        Self.pin(webView, to: host)
    }

    private static func pin(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

/// Sheet used to sign in to Google.
///
/// It presents the transport's own WebView, so the page the user signs in on is
/// the page the app later reads its session parameters from and issues its requests
/// through. Nothing has to be shared or copied between browsing contexts.
struct GeminiLoginSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            TransportHostView(webView: app.gemini.transport.webView, interactive: true)
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
                                    app.show(app.gemini.sessionDiagnosis, kind: .error)
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
                .onAppear {
                    app.isLoginPresented = true
                    // Only load the page if the transport is not already sitting on
                    // it: reloading would throw away the page the user just signed
                    // in on.
                    Task {
                        if !(app.gemini.transport.currentURL?.contains("gemini.google.com") ?? false) {
                            try? await app.gemini.transport.load(app.gemini.config.appURL)
                        }
                    }
                }
                .onDisappear { app.isLoginPresented = false }
        }
    }
}
