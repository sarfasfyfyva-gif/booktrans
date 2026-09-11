import Foundation

/// `Documents/library.json` — the ordered list shown on the home screen.
public struct LibraryStore: Sendable {
    public let paths: BookPaths

    public init(paths: BookPaths) {
        self.paths = paths
    }

    /// Never throws: a missing or corrupt library file reads as an empty library
    /// so the user still reaches the import screen.
    public func load() -> [LibraryEntry] {
        guard let data = FileStore.readData(paths.libraryJSON), !data.isEmpty else { return [] }
        do {
            return try JSONCoders.decode([LibraryEntry].self, from: data)
        } catch {
            CoreLog.warn("library.json unreadable, treating as empty: \(error)")
            return []
        }
    }

    @discardableResult
    public func save(_ entries: [LibraryEntry]) -> Bool {
        FileStore.writeJSON(entries, to: paths.libraryJSON)
    }

    /// Inserts or replaces by id, newest-opened first.
    @discardableResult
    public func upsert(_ entry: LibraryEntry) -> [LibraryEntry] {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        save(entries)
        return entries
    }

    @discardableResult
    public func remove(id: String) -> [LibraryEntry] {
        var entries = load()
        entries.removeAll { $0.id == id }
        save(entries)
        return entries
    }

    /// Recomputes progress counters from the book's own plan, so a stale
    /// `library.json` self-heals on open.
    @discardableResult
    public func refreshCounters(bookId: String, plan: BatchPlan, status: QueueStatus) -> [LibraryEntry] {
        var entries = load()
        guard let idx = entries.firstIndex(where: { $0.id == bookId }) else { return entries }
        entries[idx].batchesDone = plan.doneCount
        entries[idx].batchesTotal = plan.batches.count
        entries[idx].status = status
        save(entries)
        return entries
    }
}
