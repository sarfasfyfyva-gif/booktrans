import SwiftUI
import BookTransCore

@main
struct BookTransApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Hosts the library plus the app-wide banner. The hidden Gemini transport
/// WebView is attached here in Step 2 so it stays alive for the whole session.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            LibraryView()
        }
        .overlay(alignment: .bottom) {
            if let banner = app.banner {
                BannerView(banner: banner) { app.banner = nil }
                    .padding(.bottom, 12)
            }
        }
        .animation(.snappy, value: app.banner)
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
