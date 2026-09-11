import Foundation

/// Per-book file facade over `BookPaths`. Every write is atomic; every read is
/// tolerant of absent or corrupt files (see `FileStore`).
public struct BookStore: Sendable {
    public let paths: BookPaths

    public init(paths: BookPaths) {
        self.paths = paths
    }

    // MARK: - Meta

    public func loadMeta(_ bookId: String) -> BookMeta? {
        FileStore.readJSON(BookMeta.self, from: paths.meta(bookId))
    }

    @discardableResult
    public func saveMeta(_ meta: BookMeta) -> Bool {
        FileStore.writeJSON(meta, to: paths.meta(meta.id))
    }

    // MARK: - Chapters

    public func loadChapters(_ bookId: String) -> [Chapter] {
        FileStore.readJSON([Chapter].self, from: paths.chapters(bookId)) ?? []
    }

    @discardableResult
    public func saveChapters(_ chapters: [Chapter], bookId: String) -> Bool {
        FileStore.writeJSON(chapters, to: paths.chapters(bookId))
    }

    /// Flat block lookup across the whole book.
    public func loadBlocksByChapter(_ bookId: String) -> (chapters: [Chapter], blocks: [Int: Block]) {
        let chapters = loadChapters(bookId)
        var blocks: [Int: Block] = [:]
        for chapter in chapters {
            for block in chapter.blocks { blocks[block.id] = block }
        }
        return (chapters, blocks)
    }

    // MARK: - Plan

    public func loadPlan(_ bookId: String) -> BatchPlan? {
        FileStore.readJSON(BatchPlan.self, from: paths.plan(bookId))
    }

    @discardableResult
    public func savePlan(_ plan: BatchPlan, bookId: String) -> Bool {
        FileStore.writeJSON(plan, to: paths.plan(bookId))
    }

    /// Mutates one batch in place and persists the whole plan atomically.
    @discardableResult
    public func updateBatch(
        bookId: String,
        index: Int,
        _ mutate: (inout Batch) -> Void
    ) -> BatchPlan? {
        guard var plan = loadPlan(bookId),
              let idx = plan.batches.firstIndex(where: { $0.index == index })
        else {
            CoreLog.warn("updateBatch: no batch \(index) in plan for \(bookId)")
            return nil
        }
        mutate(&plan.batches[idx])
        savePlan(plan, bookId: bookId)
        return plan
    }

    /// Resets a new batch to `running` and bumps its attempt counter.
    @discardableResult
    public func markBatchRunning(bookId: String, index: Int) -> BatchPlan? {
        updateBatch(bookId: bookId, index: index) { batch in
            batch.status = .running
            batch.attempts += 1
            batch.error = nil
        }
    }

    @discardableResult
    public func markBatch(
        bookId: String,
        index: Int,
        status: BatchStatus,
        error: String? = nil,
        resetAttempts: Bool = false
    ) -> BatchPlan? {
        updateBatch(bookId: bookId, index: index) { batch in
            batch.status = status
            batch.error = error
            if status == .done { batch.finishedAt = Date() }
            if resetAttempts { batch.attempts = 0 }
        }
    }

    // MARK: - Results

    public func loadResult(_ bookId: String, index: Int) -> BatchResult? {
        FileStore.readJSON(BatchResult.self, from: paths.batch(bookId, index: index))
    }

    @discardableResult
    public func saveResult(_ result: BatchResult, bookId: String) -> Bool {
        FileStore.writeJSON(result, to: paths.batch(bookId, index: result.index))
    }

    public func deleteResult(_ bookId: String, index: Int) {
        FileStore.remove(paths.batch(bookId, index: index))
    }

    /// All finished batch results, keyed by batch index.
    public func loadResults(_ bookId: String, plan: BatchPlan? = nil) -> [Int: BatchResult] {
        let plan = plan ?? loadPlan(bookId)
        var results: [Int: BatchResult] = [:]
        let indices = plan?.batches.map(\.index) ?? []
        for index in indices {
            if let result = loadResult(bookId, index: index) {
                results[index] = result
            }
        }
        return results
    }

    // MARK: - Glossary

    public func loadGlossary(_ bookId: String) -> Glossary {
        FileStore.readJSON(Glossary.self, from: paths.glossary(bookId)) ?? Glossary()
    }

    @discardableResult
    public func saveGlossary(_ glossary: Glossary, bookId: String) -> Bool {
        FileStore.writeJSON(glossary, to: paths.glossary(bookId))
    }

    // MARK: - Queue state

    public func loadState(_ bookId: String) -> QueueState? {
        FileStore.readJSON(QueueState.self, from: paths.state(bookId))
    }

    @discardableResult
    public func saveState(_ state: QueueState, bookId: String) -> Bool {
        FileStore.writeJSON(state, to: paths.state(bookId))
    }

    // MARK: - Reading progress

    public func loadProgress(_ bookId: String) -> ReadingProgress {
        FileStore.readJSON(ReadingProgress.self, from: paths.progress(bookId)) ?? ReadingProgress()
    }

    @discardableResult
    public func saveProgress(_ progress: ReadingProgress, bookId: String) -> Bool {
        FileStore.writeJSON(progress, to: paths.progress(bookId))
    }

    // MARK: - Lifecycle

    public func createDirectories(_ bookId: String) throws {
        try paths.createDirectories(forBook: bookId)
    }

    public func deleteBook(_ bookId: String) throws {
        try FileManager.default.removeItem(at: paths.bookDir(bookId))
    }

    /// Bytes on disk for the whole book directory.
    public func diskUsage(_ bookId: String) -> Int {
        let fm = FileManager.default
        let root = paths.bookDir(bookId)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }
}
