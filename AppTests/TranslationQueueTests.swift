import XCTest
import BookTransCore
@testable import BookTrans

/// The translation queue is the one component whose state machine cannot be
/// checked on a device here, so it is driven directly against the mock provider.
/// The timings are injected, which is why these tests take milliseconds instead
/// of the real 15/60/300 second backoff.
@MainActor
final class TranslationQueueTests: XCTestCase {
    private var root: URL!
    private var paths: BookPaths!
    private var books: BookStore!
    private var library: LibraryStore!
    private var settings: AppSettings!
    private var provider: MockTranslationProvider!
    private var queue: TranslationQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("booktrans-queue-\(UUID().uuidString)", isDirectory: true)
        paths = BookPaths(docsRoot: root)
        try paths.createAll(paths.allDirectories)
        books = BookStore(paths: paths)
        library = LibraryStore(paths: paths)

        let suite = try XCTUnwrap(UserDefaults(suiteName: "booktrans-tests-\(UUID().uuidString)"))
        settings = AppSettings(defaults: suite)
        settings.setRetryLimitMinutes(5)

        provider = MockTranslationProvider()
        provider.delay = .milliseconds(30)

        queue = TranslationQueue(paths: paths, books: books, library: library,
                                 settings: settings, provider: provider)
        queue.retrySchedule = [.milliseconds(1)]
        queue.quotaRetryDelayOverride = 0.25
        queue.connectivityRetryDelayOverride = 0.05
    }

    override func tearDownWithError() throws {
        queue?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    /// A book whose chapters are each larger than the batch target, so the plan
    /// has exactly `batches` batches.
    @discardableResult
    private func makeBook(batches: Int) throws -> String {
        let bookId = UUID().uuidString
        try paths.createDirectories(forBook: bookId)
        let chapters = (0..<batches).map { index in
            Chapter(index: index, title: "Chapter \(index + 1)", docHref: "",
                    blocks: [Block(id: index, kind: .paragraph,
                                   text: String(repeating: "a", count: 5000))])
        }
        XCTAssertTrue(books.saveChapters(chapters, bookId: bookId))
        let plan = Chunker.plan(chapters: chapters)
        XCTAssertEqual(plan.batches.count, batches, "fixture must produce the expected plan")
        XCTAssertTrue(books.savePlan(plan, bookId: bookId))
        books.saveMeta(BookMeta(id: bookId, title: "T", author: "A", format: .fb2,
                                charCount: plan.totalChars, chapterCount: chapters.count,
                                batchCount: plan.batches.count))
        library.upsert(LibraryEntry(id: bookId, title: "T", author: "A",
                                    batchesDone: 0, batchesTotal: plan.batches.count))
        return bookId
    }

    private func plan(_ bookId: String) throws -> BatchPlan {
        try XCTUnwrap(books.loadPlan(bookId))
    }

    /// Polls until `condition` holds, yielding so the worker task can run.
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 6,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - Happy path

    func testEveryBatchIsTranslatedAndTheQueueFinishesIdle() async throws {
        let bookId = try makeBook(batches: 3)
        queue.start(bookId: bookId)

        await wait(until: { [self] in queue.status == .idle && !queue.isRunning })

        let finished = try plan(bookId)
        XCTAssertEqual(finished.batches.map(\.status), [.done, .done, .done])
        for batch in finished.batches {
            let result = try XCTUnwrap(books.loadResult(bookId, index: batch.index))
            XCTAssertEqual(result.translations.count, batch.units.count,
                           "every unit of batch \(batch.index) must have an answer")
            XCTAssertTrue(result.translations.allSatisfy { $0.hasPrefix("[перевод] ") })
            XCTAssertFalse(result.modelId.isEmpty, "the result records which model produced it")
        }
        XCTAssertEqual(books.loadState(bookId)?.status, .idle)
        XCTAssertEqual(library.load().first?.batchesDone, 3, "the library badge follows the plan")
        XCTAssertFalse(books.loadGlossary(bookId).terms.isEmpty,
                       "terminology from the lookahead must be stored")
    }

    func testLookaheadRunsOncePerBatch() async throws {
        let bookId = try makeBook(batches: 2)
        queue.start(bookId: bookId)
        await wait(until: { [self] in queue.status == .idle && !queue.isRunning })
        let finished = try plan(bookId)
        XCTAssertTrue(finished.batches.allSatisfy(\.lookaheadDone),
                      "the flag is persisted so a retry cannot re-spend a request")
    }

    // MARK: - Failures

    func testAFailedAttemptIsRetriedAndTheBatchStillSucceeds() async throws {
        let bookId = try makeBook(batches: 1)
        provider.failuresBeforeSuccess = 1
        queue.start(bookId: bookId)

        await wait(until: { [self] in queue.status == .idle && !queue.isRunning })

        let finished = try plan(bookId)
        XCTAssertEqual(finished.batches.first?.status, .done)
        XCTAssertEqual(finished.batches.first?.attempts, 2, "one failure, then a success")
        XCTAssertNotNil(books.loadResult(bookId, index: 0))
    }

    func testPersistentFailureMarksTheBatchAndKeepsGoing() async throws {
        let bookId = try makeBook(batches: 2)
        provider.alwaysFails = true
        queue.start(bookId: bookId)

        await wait(until: { [self] in
            let finished = books.loadPlan(bookId)
            return finished?.batches.allSatisfy { $0.status == .failed } ?? false
        })
        await wait(until: { [self] in !queue.isRunning })

        let finished = try plan(bookId)
        XCTAssertEqual(finished.batches.map(\.status), [.failed, .failed])
        XCTAssertEqual(finished.batches.first?.attempts, TranslationQueue.maxAttempts)
        XCTAssertEqual(queue.status, .failed, "a finished run with failures is reported as such")
        XCTAssertTrue(queue.message?.contains("ошибкой") ?? false, "\(queue.message ?? "")")
        XCTAssertEqual(books.loadState(bookId)?.status, .failed)
    }

    func testUsageLimitWaitsAndThenContinues() async throws {
        let bookId = try makeBook(batches: 1)
        provider.scriptedErrors = [
            GeminiSessionError.protocolError(GeminiError.forCode(1037), raw: ""),
        ]
        queue.start(bookId: bookId)

        // The queue must park instead of spending the batch's attempts.
        await wait(until: { [self] in queue.status == .waitingQuota })
        XCTAssertNotEqual(books.loadPlan(bookId)?.batches.first?.status, .failed)

        await wait(until: { [self] in queue.status == .idle && !queue.isRunning }, timeout: 8)
        XCTAssertEqual(books.loadPlan(bookId)?.batches.first?.status, .done,
                       "translation resumes by itself once the limit window passes")
    }

    func testConnectivityFailureNeverExhaustsTheRetryBudget() async throws {
        let bookId = try makeBook(batches: 1)
        // More failures than `maxAttempts`: an implementation that counted them
        // would permanently fail the batch and stop spending quota on it.
        provider.scriptedErrors = Array(repeating: GeminiSessionError.protocolError(
            GeminiError.unavailable, raw: ""), count: TranslationQueue.maxAttempts + 3)
        queue.start(bookId: bookId)

        await wait(until: { [self] in queue.status == .waitingQuota })
        XCTAssertEqual(books.loadPlan(bookId)?.batches.first?.status, .pending,
                       "an outage leaves the batch pending, not failed")

        await wait(until: { [self] in queue.status == .idle && !queue.isRunning }, timeout: 8)
        XCTAssertEqual(books.loadPlan(bookId)?.batches.first?.status, .done,
                       "the batch survives an outage longer than the retry budget")
    }

    func testUnauthenticatedStopsTheWorkerAndCanBeResumed() async throws {
        let bookId = try makeBook(batches: 1)
        provider.scriptedErrors = [GeminiSessionError.notSignedIn]
        queue.start(bookId: bookId)

        await wait(until: { [self] in queue.status == .waitingAuth && !queue.isRunning })
        XCTAssertEqual(books.loadState(bookId)?.status, .waitingAuth)
        XCTAssertNotEqual(books.loadPlan(bookId)?.batches.first?.status, .done)

        // Signing back in and resuming finishes the book.
        queue.resume(bookId: bookId)
        await wait(until: { [self] in queue.status == .idle && !queue.isRunning })
        XCTAssertEqual(books.loadPlan(bookId)?.batches.first?.status, .done)
    }

    // MARK: - Pause

    func testUserPauseStopsAfterTheInFlightRequest() async throws {
        let bookId = try makeBook(batches: 3)
        provider.delay = .milliseconds(200)
        queue.start(bookId: bookId)

        await wait(until: { [self] in queue.activeBatchIndex != nil })
        queue.pause()
        await wait(until: { [self] in queue.status == .paused && !queue.isRunning })

        // The request that was already in flight finishes; nothing after it starts.
        let pausedDone = try plan(bookId).batches.filter { $0.status == .done }.count
        XCTAssertLessThan(pausedDone, 3, "a pause must not run the whole book")
        XCTAssertEqual(books.loadState(bookId)?.status, .paused)

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try plan(bookId).batches.filter { $0.status == .done }.count, pausedDone,
                       "nothing continues on its own after a user pause")

        // An explicit resume finishes it.
        queue.resume(bookId: bookId)
        await wait(until: { [self] in queue.status == .idle && !queue.isRunning }, timeout: 10)
        XCTAssertEqual(try plan(bookId).batches.map(\.status), [.done, .done, .done])
    }

    func testScenePauseLeavesTheBookResumableAfterRelaunch() async throws {
        let bookId = try makeBook(batches: 3)
        provider.delay = .milliseconds(200)
        queue.start(bookId: bookId)
        await wait(until: { [self] in queue.activeBatchIndex != nil })

        queue.pause(reason: .scene)
        await wait(until: { [self] in !queue.isRunning })

        XCTAssertEqual(books.loadState(bookId)?.status, .running,
                       "a scene change is not a decision: the next launch must continue")
        XCTAssertTrue(queue.isPaused, "the worker stopped")
        XCTAssertTrue(queue.pausedForScene, "and it stopped because of the scene, not the user")
    }

    func testResumeAfterScenePauseDoesNotUndoAUserPause() async throws {
        let bookId = try makeBook(batches: 2)
        provider.delay = .milliseconds(200)
        queue.start(bookId: bookId)
        await wait(until: { [self] in queue.activeBatchIndex != nil })

        queue.pause()
        await wait(until: { [self] in queue.status == .paused && !queue.isRunning })

        let stoppedAt = try plan(bookId).batches.filter { $0.status == .done }.count

        // Coming back to the foreground must not restart work the user stopped.
        queue.resumeAfterScenePause(bookId: bookId)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(queue.status, .paused)
        XCTAssertFalse(queue.isRunning)
        XCTAssertEqual(try plan(bookId).batches.filter { $0.status == .done }.count, stoppedAt)
    }

    // MARK: - Restoring from disk

    func testOnlyAnUnfinishedStateIsResumedAtLaunch() throws {
        let bookId = try makeBook(batches: 1)

        for status in [QueueStatus.idle, .paused, .failed, .running, .waitingQuota, .waitingAuth] {
            books.saveState(QueueState(status: status, bookId: bookId, currentBatch: 0,
                                       message: nil, updatedAt: Date()), bookId: bookId)
            let fresh = TranslationQueue(paths: paths, books: books, library: library,
                                         settings: settings, provider: provider)
            fresh.retrySchedule = [.milliseconds(1)]
            let resumed = fresh.resumeFromStoredState()
            switch status {
            case .running, .waitingQuota, .waitingAuth:
                XCTAssertEqual(resumed, bookId, "\(status) must resume")
                fresh.pause()
            case .idle, .paused, .failed:
                XCTAssertNil(resumed, "\(status) must not resume by itself")
            }
        }
    }

    func testAFullyTranslatedBookIsNotResumed() throws {
        let bookId = try makeBook(batches: 1)
        books.markBatch(bookId: bookId, index: 0, status: .done)
        books.saveState(QueueState(status: .running, bookId: bookId, currentBatch: 0,
                                   message: nil, updatedAt: Date()), bookId: bookId)
        let fresh = TranslationQueue(paths: paths, books: books, library: library,
                                     settings: settings, provider: provider)
        XCTAssertNil(fresh.resumeFromStoredState(), "nothing left to do")
    }

    // MARK: - Deletion

    func testDeletingTheBookStopsTheWorker() async throws {
        let bookId = try makeBook(batches: 3)
        provider.delay = .milliseconds(150)
        queue.start(bookId: bookId)
        await wait(until: { [self] in queue.activeBatchIndex != nil })

        // Simulate what AppState.deleteBook does.
        try books.deleteBook(bookId)
        _ = library.remove(id: bookId)

        await wait(until: { [self] in !queue.isRunning }, timeout: 5)
        XCTAssertNil(queue.activeBookId, "the queue lets go of a deleted book")

        // A batch that was in flight may still land, so clear again and then check
        // that nothing keeps working on a book the user removed.
        try? books.deleteBook(bookId)
        let doneWhenStopped = books.loadPlan(bookId)?.doneCount ?? 0
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(books.loadPlan(bookId)?.doneCount ?? 0, doneWhenStopped,
                       "a deleted book must not keep being translated")
    }

    // MARK: - Batch index

    func testNextBatchSkipsFinishedAndFailedOnes() async throws {
        let bookId = try makeBook(batches: 3)
        books.markBatch(bookId: bookId, index: 0, status: .done)
        books.markBatch(bookId: bookId, index: 1, status: .failed, error: "x")
        queue.start(bookId: bookId)

        await wait(until: { [self] in !queue.isRunning })

        let finished = try plan(bookId)
        XCTAssertEqual(finished.batches[0].status, .done)
        XCTAssertEqual(finished.batches[1].status, .failed, "a failed batch is not retried unasked")
        XCTAssertEqual(finished.batches[2].status, .done,
                       "the loop must work past a failed batch")
        XCTAssertEqual(queue.status, .failed,
                       "the run reports the failure rather than claiming success")
    }
}
