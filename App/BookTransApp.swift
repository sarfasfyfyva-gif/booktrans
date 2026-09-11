import SwiftUI
import BookTransCore

@main
struct BookTransApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            app.handleScenePhase(phase)
        }
    }
}

/// Hosts the library plus the app-wide banner. The Gemini WebView lives here so
/// it stays in the view hierarchy for the whole session (a detached WebView has
/// its JavaScript throttled, which would stall translation).
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            NavigationStack {
                LibraryView()
            }
            TransportHostView(webView: app.gemini.transport.webView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let banner = app.banner {
                BannerView(banner: banner) { app.banner = nil }
                    .padding(.bottom, 12)
            }
        }
        .animation(.snappy, value: app.banner)
        .onOpenURL { url in
            // Documents copied into the sandbox or shared from another app.
            Task { await app.importBook(from: url) }
        }
    }
}

private struct BannerView: View {
    let banner: AppState.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.kind == .error ? Theme.danger : Theme.accent)
            Text(banner.text)
                .font(.footnote)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
