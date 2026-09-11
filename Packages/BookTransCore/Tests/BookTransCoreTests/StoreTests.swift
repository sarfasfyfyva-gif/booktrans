import XCTest
@testable import BookTransCore

/// Store-layer behaviour: every file here is a rebuildable cache, so reads must
/// survive absent and corrupt content while writes must be crash-atomic.
final class StoreTests: XCTestCase {
    private var root: URL!
    private var paths: BookPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("booktrans-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = BookPaths(docsRoot: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - FileStore

    func testAtomicWriteReplacesExistingContentAndLeavesNoTempFiles() throws {
        let url = root.appendingPathComponent("value.json")
        try FileStore.writeAtomic(Data("first".utf8), to: url)
        try FileStore.writeAtomic(Data("second".utf8), to: url)

        XCTAssertEqual(String(data: try Data(contentsOf: url), encoding: .utf8), "second")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(siblings.filter { $0.contains(".tmp-") }.count, 0, "temp files leaked: \(siblings)")
    }

    func testReadJSONReturnsNilForMissingFile() {
        let missing = root.appendingPathComponent("nope.json")
        XCTAssertNil(FileStore.readJSON([String].self, from: missing))
    }

    func testReadJSONReturnsNilForCorruptFileAndPreservesIt() throws {
        let url = root.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: url)

        XCTAssertNil(FileStore.readJSON([String].self, from: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "corrupt file must be kept for post-mortem")
    }

    func testReadJSONReturnsNilForEmptyFile() throws {
        let url = root.appendingPathComponent("empty.json")
        try Data().write(to: url)
        XCTAssertNil(FileStore.readJSON([String].self, from: url))
    }

    func testJSONRoundTripPreservesUTCDates() throws {
        let url = root.appendingPathComponent("meta.json")
        let meta = BookMeta(id: "abc", title: "T", author: "A", format: .epub,
                            charCount: 10, chapterCount: 2, batchCount: 1,
                            createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(FileStore.writeJSON(meta, to: url))

        let text = String(data: try Data(contentsOf: url), encoding: .utf8)!
        XCTAssertTrue(text.contains("\"createdAt\":\"1970-01-01T00:00:00Z\""), text)

        let restored = FileStore.readJSON(BookMeta.self, from: url)
        XCTAssertEqual(restored?.id, "abc")
        XCTAssertEqual(restored?.format, .epub)
        XCTAssertEqual(restored?.createdAt, Date(timeIntervalSince1970: 0))
    }

    // MARK: - BookPaths

    func testBookPathsLayout() {
        let id = "book-1"
        XCTAssertEqual(paths.libraryJSON.lastPathComponent, "library.json")
        XCTAssertEqual(paths.meta(id).lastPathComponent, "book.json")
        XCTAssertEqual(paths.original(id, ext: "fb2").lastPathComponent, "original.fb2")
        XCTAssertEqual(paths.chapters(id).path, paths.parsedDir(id).appendingPathComponent("chapters.json").path)
        XCTAssertEqual(paths.batch(id, index: 7).lastPathComponent, "007.json")
        XCTAssertEqual(paths.batch(id, index: 123).lastPathComponent, "123.json")
        XCTAssertEqual(paths.glossary(id).lastPathComponent, "glossary.json")
        XCTAssertEqual(paths.state(id).lastPathComponent, "state.json")
        XCTAssertEqual(paths.progress(id).lastPathComponent, "progress.json")
        XCTAssertEqual(BookPaths.imageRef(fileName: "a.jpg"), "images/a.jpg")
    }

    func testCreateDirectoriesForBookIsIdempotent() throws {
        try paths.createDirectories(forBook: "book-1")
        try paths.createDirectories(forBook: "book-1")

        let fm = FileManager.default
        for dir in paths.allDirectories + paths.allDirectories(forBook: "book-1") {
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: dir.path, isDirectory: &isDir), "missing \(dir.path)")
            XCTAssertTrue(isDir.boolValue)
        }
    }

    func testExistingOriginalFindsAnyKnownExtension() throws {
        XCTAssertNil(paths.existingOriginal("b"))
        try paths.createDirectories(forBook: "b")
        try Data("x".utf8).write(to: paths.original("b", ext: "epub"))
        XCTAssertEqual(paths.existingOriginal("b")?.pathExtension, "epub")
    }

    // MARK: - LibraryStore

    func testLibraryUpsertReplacesByIdInsteadOfDuplicating() {
        let store = LibraryStore(paths: paths)
        store.upsert(LibraryEntry(id: "a", title: "First", author: ""))
        store.upsert(LibraryEntry(id: "a", title: "Second", author: ""))
        store.upsert(LibraryEntry(id: "b", title: "Other", author: ""))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == "a" }?.title, "Second")
    }

    func testLibraryRemoveDropsOnlyRequestedEntry() {
        let store = LibraryStore(paths: paths)
        store.upsert(LibraryEntry(id: "a", title: "A", author: ""))
        store.upsert(LibraryEntry(id: "b", title: "B", author: ""))

        XCTAssertEqual(store.remove(id: "a").map(\.id), ["b"])
        XCTAssertEqual(store.load().map(\.id), ["b"])
    }

    func testLibraryRefreshCountersDerivesFromPlan() {
        let store = LibraryStore(paths: paths)
        store.upsert(LibraryEntry(id: "a", title: "A", author: "", batchesDone: 0, batchesTotal: 0))

        let plan = BatchPlan(target: 4000, totalChars: 8000, batches: [
            Batch(index: 0, chars: 4000, status: .done, units: [Unit(block: 0, part: 0, text: "x")]),
            Batch(index: 1, chars: 4000, status: .pending, units: [Unit(block: 1, part: 0, text: "y")]),
        ])
        let entries = store.refreshCounters(bookId: "a", plan: plan, status: .running)

        XCTAssertEqual(entries.first?.batchesDone, 1)
        XCTAssertEqual(entries.first?.batchesTotal, 2)
        XCTAssertEqual(entries.first?.status, .running)
        XCTAssertEqual(entries.first?.progressFraction ?? 0, 0.5, accuracy: 0.001)
    }

    // MARK: - BookStore

    func testPlanRoundTripAndBatchStatusTransitions() throws {
        let store = BookStore(paths: paths)
        try store.createDirectories("b")

        let plan = BatchPlan(target: 4000, totalChars: 4000, batches: [
            Batch(index: 0, chars: 4000, units: [
                Unit(block: 0, part: 0, text: "one"),
                Unit(block: 1, part: 0, text: "two"),
            ])
        ])
        XCTAssertTrue(store.savePlan(plan, bookId: "b"))
        XCTAssertEqual(store.loadPlan("b")?.batches.first?.units.count, 2)

        let marked = store.markBatchRunning(bookId: "b", index: 0)
        XCTAssertEqual(marked?.batches.first?.status, .running)
        XCTAssertEqual(marked?.batches.first?.attempts, 1, "attempts must increment on each try")

        let done = store.markBatch(bookId: "b", index: 0, status: .done)
        XCTAssertEqual(done?.batches.first?.status, .done)
        XCTAssertNotNil(done?.batches.first?.finishedAt)

        let reset = store.markBatch(bookId: "b", index: 0, status: .pending, resetAttempts: true)
        XCTAssertEqual(reset?.batches.first?.attempts, 0)
    }

    func testMarkBatchOnUnknownIndexIsNoOp() throws {
        let store = BookStore(paths: paths)
        try store.createDirectories("b")
        store.savePlan(BatchPlan(target: 4000, totalChars: 0, batches: []), bookId: "b")
        XCTAssertNil(store.markBatchRunning(bookId: "b", index: 5))
    }

    func testResultRoundTripAndDelete() throws {
        let store = BookStore(paths: paths)
        try store.createDirectories("b")

        let result = BatchResult(index: 3, modelId: "m1",
                                 translations: ["раз", "два"],
                                 glossaryAdditions: [GlossaryAddition(term: "ROI", translation: "ROI")],
                                 rawChars: 42)
        XCTAssertTrue(store.saveResult(result, bookId: "b"))
        XCTAssertEqual(store.loadResult("b", index: 3)?.translations, ["раз", "два"])

        store.deleteResult("b", index: 3)
        XCTAssertNil(store.loadResult("b", index: 3))
    }

    func testGlossaryStateAndProgressAreIndependentFiles() throws {
        let store = BookStore(paths: paths)
        try store.createDirectories("b")

        store.saveGlossary(Glossary(terms: [GlossaryTerm(term: "ROI", translation: "ROI")]), bookId: "b")
        store.saveState(QueueState(status: .waitingQuota, bookId: "b", currentBatch: 4,
                                   message: "лимит"), bookId: "b")
        store.saveProgress(ReadingProgress(chapterIndex: 2, blockId: 17, dy: 240,
                                           showTranslation: false), bookId: "b")

        XCTAssertEqual(store.loadGlossary("b").terms.map(\.key), ["roi"])
        XCTAssertEqual(store.loadState("b")?.status, .waitingQuota)
        XCTAssertEqual(store.loadState("b")?.currentBatch, 4)
        let progress = store.loadProgress("b")
        XCTAssertEqual(progress.chapterIndex, 2)
        XCTAssertEqual(progress.blockId, 17)
        XCTAssertEqual(progress.dy, 240)
        XCTAssertFalse(progress.showTranslation)
    }

    func testProgressDefaultsWhenFileMissing() throws {
        let store = BookStore(paths: paths)
        try store.createDirectories("b")
        let progress = store.loadProgress("b")
        XCTAssertEqual(progress.chapterIndex, 0)
        XCTAssertTrue(progress.showTranslation)
    }

    func testLoadResultsSkipsBatchesWithoutFiles() throws {
        let store = BookStore(paths: paths)
        try store.createDirectories("b")
        let plan = BatchPlan(target: 4000, totalChars: 0, batches: [
            Batch(index: 0, chars: 1, status: .done, units: []),
            Batch(index: 1, chars: 1, status: .pending, units: []),
        ])
        store.savePlan(plan, bookId: "b")
        store.saveResult(BatchResult(index: 0, modelId: "m", translations: []), bookId: "b")

        let results = store.loadResults("b", plan: plan)
        XCTAssertEqual(results.keys.sorted(), [0])
    }
}
