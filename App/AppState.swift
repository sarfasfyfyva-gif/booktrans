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
    let queue: TranslationQueue

    /// Library screen contents, newest-opened first.
    private(set) var entries: [LibraryEntry] = []

    /// Transient user-facing message (errors, import results).
    var banner: Banner?

    /// Non-fatal problems surfaced by background work.
    private(set) var lastError: String?

    /// Bumped whenever finished batches change what the reader should show.
    /// Views observe this instead of polling the store.
    private(set) var translationRevision = 0

    /// True while an import is running, so the UI can disable the picker.
    private(set) var isImporting = false

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// Dependencies are injected as optionals and built inside the initializer:
    /// default arguments are evaluated in the caller's (nonisolated) context, so
    /// `= AppSettings()` there cannot reach a main-actor initializer.
    init(
        docsRoot: URL? = nil,
        settings: AppSettings? = nil,
        transport: GeminiWebTransport? = nil
    ) {
        let root = docsRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let paths = BookPaths(docsRoot: root)
        self.paths = paths
        self.library = LibraryStore(paths: paths)
        self.books = BookStore(paths: paths)
        let resolvedSettings = settings ?? AppSettings()
        let session = GeminiSession(paths: paths, transport: transport ?? GeminiWebTransport())
        self.settings = resolvedSettings
        self.gemini = session
        self.queue = TranslationQueue(
            paths: paths,
            books: BookStore(paths: paths),
            library: LibraryStore(paths: paths),
            settings: resolvedSettings,
            provider: resolvedSettings.useMockTranslator
                ? MockTranslationProvider()
                : GeminiTranslationProvider(session: session))

        // Logging hook is installed before any store touches disk so that early
        // failures reach the on-disk log.
        LogStore.shared.install()
        LogStore.shared.configure(url: paths.geminiLog)

        bootstrap()
        reloadLibrary()
        applyIdleTimerSetting()
        queue.onBatchFinished = { [weak self] _ in
            self?.noteTranslationChanged()
        }
    }

    /// Rebuilds the provider after the mock translator is toggled.
    func applyProviderSetting() {
        queue.setProvider(settings.useMockTranslator
            ? MockTranslationProvider()
            : GeminiTranslationProvider(session: gemini))
    }

    /// Continues a translation that was running when the app was last closed.
    func resumeQueueIfNeeded() {
        queue.resumeFromStoredState()
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

    /// Notifies the UI that finished batches changed what the reader shows.
    func noteTranslationChanged() {
        translationRevision &+= 1
        reloadLibrary()
    }

    /// Imports one file, reporting the outcome through the banner.
    @discardableResult
    func importBook(from url: URL) async -> String? {
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }

        let paths = self.paths
        let bookId = UUID().uuidString
        do {
            // Unzipping, XML parsing and image re-encoding are seconds of work on
            // the main thread would freeze the UI and can trip the watchdog, so
            // the whole import runs detached; only the library update returns.
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ImportCoordinator.prepare(source: url, bookId: bookId, paths: paths)
            }.value

            _ = library.upsert(prepared.entry)
            reloadLibrary()
            show("«\(prepared.meta.title)» добавлена: \(prepared.meta.chapterCount) глав, "
                 + "\(prepared.plan.batches.count) батчей")
            return prepared.bookId
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            show(message, kind: .error)
            return nil
        }
    }

    func deleteBook(_ bookId: String) {
        // Stop first: a running worker holds the plan in memory and would keep
        // translating (and re-creating files for) a book that is already gone.
        if queue.activeBookId == bookId {
            queue.stop()
        }
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
        switch phase {
        case .active:
            // Coming back from the background continues a translation that the
            // scene change stopped; a pause the user asked for is left alone.
            queue.resumeAfterScenePause()
        default:
            // iOS suspends the app, so translation cannot continue; stop after
            // the request that is already in flight.
            CoreLog.info("scene became \(String(describing: phase)); pausing translation")
            queue.pause(reason: .scene)
        }
    }

    func applyIdleTimerSetting() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
    }

}
