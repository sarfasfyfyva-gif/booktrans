import SwiftUI
import Observation
import UIKit
import BookTransCore

/// Root object graph. Owns the on-disk layout, the stores every screen needs,
/// and the long-lived Gemini session (whose WebView must stay alive for the
/// whole process).
@MainActor
@Observable
final class AppState {
    let paths: BookPaths
    let library: LibraryStore
    let books: BookStore
    let settings: AppSettings
    let gemini: GeminiSession

    /// Library screen contents, newest-opened first.
    private(set) var entries: [LibraryEntry] = []

    /// Transient user-facing message (errors, import results).
    var banner: Banner?

    /// Non-fatal problems surfaced by background work.
    private(set) var lastError: String?

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    init(
        docsRoot: URL? = nil,
        settings: AppSettings = AppSettings(),
        transport: GeminiWebTransport = GeminiWebTransport()
    ) {
        let root = docsRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let paths = BookPaths(docsRoot: root)
        self.paths = paths
        self.library = LibraryStore(paths: paths)
        self.books = BookStore(paths: paths)
        self.settings = settings
        self.gemini = GeminiSession(paths: paths, transport: transport)

        // Logging hook is installed before any store touches disk so that early
        // failures reach the on-disk log.
        LogStore.shared.install()
        LogStore.shared.configure(url: paths.geminiLog)

        bootstrap()
        reloadLibrary()
        applyIdleTimerSetting()
    }

    /// Creates the fixed sandbox directories. Safe to run on every launch.
    private func bootstrap() {
        do {
            try paths.createAll(paths.allDirectories)
        } catch {
            lastError = "Не удалось создать каталоги: \(error.localizedDescription)"
            CoreLog.error("bootstrap failed: \(error)")
        }
    }

    func reloadLibrary() {
        entries = library.load().sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    func show(_ text: String, kind: Banner.Kind = .info) {
        banner = Banner(kind: kind, text: text)
    }

    func deleteBook(_ bookId: String) {
        do {
            try books.deleteBook(bookId)
            _ = library.remove(id: bookId)
            reloadLibrary()
            show("Книга удалена")
        } catch {
            show("Не удалось удалить книгу: \(error.localizedDescription)", kind: .error)
        }
    }

    // MARK: - Lifecycle

    /// iOS sleeps the app in the background, and translation only advances while
    /// it is active, so pausing is not optional.
    func handleScenePhase(_ phase: ScenePhase) {
        applyIdleTimerSetting()
        if phase != .active {
            CoreLog.info("scene became \(String(describing: phase)); pausing translation")
            requestTranslationPause()
        }
    }

    func applyIdleTimerSetting() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
    }

    /// Replaced by the translation queue once it exists; kept as an explicit
    /// hook so the lifecycle decision stays in one place.
    var onRequestTranslationPause: (() -> Void)?

    private func requestTranslationPause() {
        onRequestTranslationPause?()
    }
}
