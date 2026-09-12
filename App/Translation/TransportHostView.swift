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
        guard claimsOwnership else { return host }
        Self.attach(webView, to: host)
        webView.isUserInteractionEnabled = interactive
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        // A host that is not the owner must not touch the WebView at all — not even
        // its interaction flag. Setting that flag here is what broke sign-in: the
        // 1x1 host re-renders whenever any app state changes, so it kept clearing the
        // flag the presented sheet had just set, and the sign-in page stayed fully
        // visible while ignoring every tap.
        guard claimsOwnership else { return }
        if webView.superview !== host {
            Self.attach(webView, to: host)
        }
        webView.isUserInteractionEnabled = interactive
    }

    private static func attach(_ child: UIView, to parent: UIView) {
        child.removeFromSuperview()
        parent.addSubview(child)
        pin(child, to: parent)
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
                                // refreshSession already confirms with the account
                                // RPC, so the result it reports is the checked one.
                                _ = await app.gemini.refreshSession(force: true)
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
                .task {
                    // Only load the page if the transport is not already sitting on
                    // it: reloading would throw away the page the user just signed
                    // in on.
                    if !(app.gemini.transport.currentURL?.contains("gemini.google.com") ?? false) {
                        try? await app.gemini.transport.load(app.gemini.config.appURL)
                    }
                }
                .onDisappear {
                    // Release the WebView back to the 1x1 host. The sheet is presented
                    // by this same flag, so the ordinary dismissal path has already
                    // cleared it; this guarantees the release on every path, because
                    // the 1x1 host is what keeps the page (and its session) alive.
                    app.isLoginPresented = false
                }
        }
    }
}
