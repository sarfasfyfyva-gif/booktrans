import SwiftUI
import WebKit

/// Embeds the transport's WebView so it stays in the view hierarchy and its
/// JavaScript is never throttled. Normally invisible; presented at full size
/// while the user signs in.
struct TransportHostView: UIViewRepresentable {
    let webView: WKWebView
    var interactive: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        webView.isUserInteractionEnabled = interactive
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.isUserInteractionEnabled = interactive
    }
}

/// Sheet used to sign in to Google. It is the same WebView the transport uses,
/// so cookies land exactly where the requests read them from.
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
                            await app.gemini?.refreshSession(force: true)
                            await app.gemini?.refreshAccountStatus()
                            isWorking = false
                            if app.gemini?.signInState == .signedIn { dismiss() }
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
