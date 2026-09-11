import Foundation
import WebKit
import SwiftUI
import BookTransCore

/// Owns the reader's `WKWebView` and the JavaScript bridge.
///
/// The page is a local file in the book directory, which is the only path the
/// WebView is granted read access to, so images resolve by relative path and no
/// network access is possible from here.
@MainActor
@Observable
final class ReaderWebController: NSObject {
    let webView: WKWebView
    private let bookDirectory: URL
    private let readerFile: URL
    private var pendingRestore: (block: Int, dy: Int)?

    /// Reported after every load so the caller can persist a position.
    private(set) var lastKnownPosition: (block: Int, dy: Int, progress: Double) = (0, 0, 0)
    private(set) var isLoaded = false
    private(set) var loadError: String?

    init(bookDirectory: URL, readerFile: URL) {
        self.bookDirectory = bookDirectory
        self.readerFile = readerFile
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.readerBackground)
        webView.scrollView.backgroundColor = UIColor(Theme.readerBackground)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Rendering

    /// Writes the chapter page and loads it, optionally restoring a position.
    func render(
        chapter: Chapter,
        translations: TranslationMap,
        configuration: ReaderHTMLBuilder.Configuration,
        restore: (block: Int, dy: Int)?
    ) {
        let html = ReaderHTMLBuilder.build(
            chapter: chapter, translations: translations, configuration: configuration)
        guard FileStore.writeData(Data(html.utf8), to: readerFile) else {
            loadError = "Не удалось записать страницу главы"
            return
        }
        pendingRestore = restore
        isLoaded = false
        loadError = nil
        webView.loadFileURL(readerFile, allowingReadAccessTo: bookDirectory)
    }

    /// Applies typography changes without a reload, which keeps the scroll
    /// position and avoids a visible flash.
    func applyStyle(_ configuration: ReaderHTMLBuilder.Configuration) async {
        guard isLoaded else { return }
        _ = try? await webView.callAsyncJavaScript(
            "return Reader.style(fontSize, lineHeight, margin);",
            arguments: [
                "fontSize": configuration.fontSize,
                "lineHeight": configuration.lineHeight,
                "margin": configuration.margin,
            ],
            in: nil, contentWorld: .page)
    }

    func scrollToTop() async {
        guard isLoaded else { return }
        _ = try? await webView.callAsyncJavaScript(
            "return Reader.top();", arguments: [:], in: nil, contentWorld: .page)
    }

    // MARK: - Position

    /// Reads the current reading position. Falls back to the last known value
    /// when the page is not ready, so a redraw can never lose the position.
    @discardableResult
    func capturePosition() async -> (block: Int, dy: Int, progress: Double) {
        guard isLoaded else { return lastKnownPosition }
        let result = try? await webView.callAsyncJavaScript(
            "return Reader.position();", arguments: [:], in: nil, contentWorld: .page)
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = object["block"] as? Int
        else { return lastKnownPosition }
        let dy = (object["dy"] as? NSNumber)?.intValue ?? 0
        let progress = (object["progress"] as? NSNumber)?.doubleValue ?? 0
        lastKnownPosition = (block, dy, progress)
        return lastKnownPosition
    }

    var currentChapterFraction: Double { lastKnownPosition.progress }
}

extension ReaderWebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        guard let restore = pendingRestore else { return }
        pendingRestore = nil
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "return Reader.restore(block, dy);",
                arguments: ["block": restore.block, "dy": restore.dy],
                in: nil, contentWorld: .page)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        loadError = error.localizedDescription
    }
}

/// Hosts the controller's WebView.
struct ReaderWebView: UIViewRepresentable {
    let controller: ReaderWebController

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
