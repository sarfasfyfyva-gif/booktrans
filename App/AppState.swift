import SwiftUI
import Observation
import BookTransCore

/// Root object graph. Owns the on-disk layout and the stores every screen needs.
@MainActor
@Observable
final class AppState {
    let paths: BookPaths
    let library: LibraryStore
    let books: BookStore

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

    init(docsRoot: URL? = nil) {
        let root = docsRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let paths = BookPaths(docsRoot: root)
        self.paths = paths
        self.library = LibraryStore(paths: paths)
        self.books = BookStore(paths: paths)

        // Logging hook is installed before any store touches disk so that early
        // failures reach the on-disk log.
        LogStore.shared.install()
        bootstrap()
        reloadLibrary()
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
}
