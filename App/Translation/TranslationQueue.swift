import Foundation
import Observation
import BookTransCore

/// Drives translation one batch at a time: one book, one request in flight.
///
/// Everything here is main-actor isolated on purpose — the app has exactly one
/// queue, and keeping the state machine single-threaded is what makes "pause
/// after the current request" and "resume from state.json" easy to reason about.
@MainActor
@Observable
final class TranslationQueue {
    /// Backoff after a failed attempt, indexed by attempt number.
    static let retryDelays: [Duration] = [.seconds(15), .seconds(60), .seconds(300)]
    static let maxAttempts = 3
    /// How long to wait before retrying after a connectivity failure. Short,
    /// because the user may flip the VPN back on at any moment.
    static let connectivityRetryDelay: TimeInterval = 60

    /// Backoff actually used. Injectable so tests do not wait real seconds.
    var retrySchedule: [Duration] = TranslationQueue.retryDelays
    /// Overrides the configured quota wait. Injectable for the same reason.
    var quotaRetryDelayOverride: TimeInterval?
    /// Overrides the connectivity retry wait. Injectable for the same reason.
    var connectivityRetryDelayOverride: TimeInterval?

    private(set) var status: QueueStatus = .idle
    private(set) var message: String?
    private(set) var activeBookId: String?
    private(set) var activeBatchIndex: Int?
    /// Set by the user or by the scene going inactive.
    private(set) var isPaused = false
    /// True when the current stop was caused by the scene, not by the user.
    private(set) var pausedForScene = false

    private let paths: BookPaths
    private let books: BookStore
    private let library: LibraryStore
    private let settings: AppSettings
    private var provider: TranslationProvider

    private var worker: Task<Void, Never>?
    private var isWorking = false
    /// Not before this instant may the next request start.
    private var notBefore: Date?
    /// Called after a batch completes so views can refresh.
    var onBatchFinished: ((String) -> Void)?

    init(
        paths: BookPaths,
        books: BookStore,
        library: LibraryStore,
        settings: AppSettings,
        provider: TranslationProvider
    ) {
        self.paths = paths
        self.books = books
        self.library = library
        self.settings = settings
        self.provider = provider
    }

    /// Swaps the provider, used when the mock translator is toggled.
    func setProvider(_ provider: TranslationProvider) {
        self.provider = provider
    }

    var isRunning: Bool { isWorking && !isPaused }

    // MARK: - Control

    func start(bookId: String) {
        guard !isWorking else { return }
        isWorking = true
        isPaused = false
        activeBookId = bookId
        setStatus(.running, message: nil, bookId: bookId)
        worker = Task { [weak self] in
            await self?.run(bookId: bookId)
            // Cancellation is cooperative: a cancelled task can finish long after
            // its replacement started, so it must not clear the new worker's flag.
            guard let self, !Task.isCancelled else { return }
            self.worker = nil
            self.isWorking = false
        }
    }

    /// Why the queue stopped making requests.
    enum PauseReason {
        /// The user pressed a pause button. Survives a relaunch: only an explicit
        /// resume starts it again.
        case user
        /// The app went inactive. iOS suspends us anyway, so this is not a
        /// decision — the persisted state stays "unfinished" and the next launch
        /// continues automatically.
        case scene
    }

    /// Stops after the request that is already in flight.
    func pause(reason: PauseReason = .user) {
        isPaused = true
        pausedForScene = (reason == .scene)
        guard let bookId = activeBookId else { return }
        switch reason {
        case .user:
            setStatus(.paused, message: "Пауза", bookId: bookId)
            persistState(bookId: bookId, status: .paused, message: "Пауза")
        case .scene:
            // Deliberately no persist and no status change: the worker is idle
            // but the book's translation is still unfinished, and state.json
            // already says `.running` from the last batch.
            CoreLog.info("queue paused because the app became inactive")
        }
    }

    /// Restarts after the app came back to the foreground, but only if the stop
    /// was caused by the scene going inactive.
    func resumeAfterScenePause(bookId: String? = nil) {
        guard pausedForScene else { return }
        pausedForScene = false
        resume(bookId: bookId)
    }

    func resume(bookId: String? = nil) {
        let target = bookId ?? activeBookId
        guard let target else { return }
        isPaused = false
        pausedForScene = false
        start(bookId: target)
    }

    func stop() {
        worker?.cancel()
        worker = nil
        isWorking = false
        isPaused = false
        if let bookId = activeBookId {
            persistState(bookId: bookId, status: .idle, message: nil)
        }
        setStatus(.idle, message: nil, bookId: activeBookId)
    }

    /// Puts the queue into the "needs a sign-in" state. Called after the user
    /// signs out, so the UI shows the banner instead of silently doing nothing.
    func requireAuthentication(bookId: String? = nil) {
        guard let target = bookId ?? activeBookId else { return }
        worker?.cancel()
        worker = nil
        isWorking = false
        notBefore = nil
        let text = "Нужно войти в Gemini"
        setStatus(.waitingAuth, message: text, bookId: target)
        persistState(bookId: target, status: .waitingAuth, message: text)
    }

    /// Resets batches to `pending`, deleting their results, and starts again.
    func retranslate(bookId: String, indices: [Int]) {
        guard var plan = books.loadPlan(bookId) else { return }
        for index in indices {
            guard let position = plan.batches.firstIndex(where: { $0.index == index }) else { continue }
            plan.batches[position].status = .pending
            plan.batches[position].attempts = 0
            plan.batches[position].error = nil
            plan.batches[position].finishedAt = nil
            plan.batches[position].lookaheadDone = false
            books.deleteResult(bookId, index: index)
        }
        books.savePlan(plan, bookId: bookId)
        _ = library.refreshCounters(bookId: bookId, plan: plan, status: .idle)
        notBefore = nil
        if !isWorking { start(bookId: bookId) }
    }

    /// Called at launch: resumes a book whose stored state says it was running.
    @discardableResult
    func resumeFromStoredState() -> String? {
        guard let bookId = library.load().first(where: { $0.status.isActive || $0.status == .paused })?.id
                ?? library.load().first?.id
        else { return nil }
        guard let state = books.loadState(bookId) else { return nil }
        switch state.status {
        case .running, .waitingQuota, .waitingAuth:
            let plan = books.loadPlan(bookId)
            let next = plan?.batches.first { $0.status != .done }
            if plan?.nextPendingIndex == nil, next == nil { return nil }
            LogStore.shared.append(level: .info, event: "queue.resume",
                                   fields: ["book": bookId, "batch": String(state.currentBatch)])
            start(bookId: bookId)
            return bookId
        default:
            return nil
        }
    }

    // MARK: - Worker

    private func run(bookId: String) async {
        guard var plan = books.loadPlan(bookId) else {
            setStatus(.failed, message: "Нет плана перевода", bookId: bookId)
            return
        }

        while !Task.isCancelled {
            // The book may have been deleted while a request was in flight; the
            // worker must not resurrect its directory and keep spending quota.
            guard library.load().contains(where: { $0.id == bookId }) else {
                CoreLog.info("queue: book \(bookId) is gone from the library, stopping")
                setStatus(.idle, message: nil, bookId: nil)
                activeBookId = nil
                activeBatchIndex = nil
                return
            }
            if isPaused {
                await finish(bookId: bookId, plan: plan, reason: .paused)
                return
            }

            // Wait out a quota/backoff delay in slices so pause stays responsive.
            if let target = notBefore, Date() < target {
                let remaining = target.timeIntervalSinceNow
                setStatus(status == .waitingAuth ? .waitingAuth : .waitingQuota,
                          message: message, bookId: bookId)
                let slice = min(remaining, 20)
                try? await Task.sleep(for: .seconds(max(1, slice)))
                continue
            }
            notBefore = nil

            guard let batchIndex = nextBatchIndex(in: plan) else {
                await finish(bookId: bookId, plan: plan, reason: .complete)
                return
            }
            guard let batch = plan.batches.first(where: { $0.index == batchIndex }) else { break }

            activeBatchIndex = batchIndex
            setStatus(.running, message: "Батч \(batchIndex + 1) из \(plan.batches.count)", bookId: bookId)
            persistState(bookId: bookId, status: .running, message: nil, currentBatch: batchIndex)

            let outcome = await translate(batch: batch, bookId: bookId)
            switch outcome {
            case .finished(let updated):
                plan.batches[updated.index] = updated
                books.savePlan(plan, bookId: bookId)
                _ = library.refreshCounters(bookId: bookId, plan: plan, status: .running)
                onBatchFinished?(bookId)
                activeBatchIndex = nil

            case .retryLater(let delay, let error, let updated):
                plan.batches[updated.index] = updated
                books.savePlan(plan, bookId: bookId)
                activeBatchIndex = nil

                let waiting: QueueStatus?
                switch error.kind {
                case .usageLimit, .ipRegion, .unavailable: waiting = .waitingQuota
                case .unauthenticated: waiting = .waitingAuth
                default: waiting = nil
                }
                if let waiting {
                    setStatus(waiting, message: error.message, bookId: bookId)
                    persistState(bookId: bookId, status: waiting,
                                 message: error.message, currentBatch: batchIndex)
                } else {
                    setStatus(.running, message: error.message, bookId: bookId)
                }

                if waiting == .waitingAuth {
                    // Nothing can happen without the user signing in; end the
                    // worker and let the UI restart it after login.
                    return
                }
                notBefore = Date().addingTimeInterval(delay)

            case .giveUp(let error, let updated):
                plan.batches[updated.index] = updated
                books.savePlan(plan, bookId: bookId)
                _ = library.refreshCounters(bookId: bookId, plan: plan, status: .running)
                onBatchFinished?(bookId)
                activeBatchIndex = nil
                CoreLog.warn("batch \(batchIndex) failed: \(error)")
            }
        }
    }

    private enum FinishReason {
        case complete
        case paused
    }

    private func finish(bookId: String, plan: BatchPlan, reason: FinishReason) async {
        let failed = plan.batches.filter { $0.status == .failed }.count
        switch reason {
        case .paused:
            if pausedForScene {
                // Leave the persisted state as unfinished so the next launch picks
                // the translation up where it stopped.
                setStatus(.running, message: nil, bookId: bookId)
            } else {
                setStatus(.paused, message: "Пауза", bookId: bookId)
                persistState(bookId: bookId, status: .paused, message: "Пауза")
            }
        case .complete:
            if failed > 0 {
                let text = "Готово, но \(failed) батчей с ошибкой — их можно перезапустить"
                setStatus(.failed, message: text, bookId: bookId)
                persistState(bookId: bookId, status: .failed, message: text)
            } else {
                setStatus(.idle, message: "Перевод завершён", bookId: bookId)
                persistState(bookId: bookId, status: .idle, message: nil)
            }
        }
        _ = library.refreshCounters(bookId: bookId, plan: plan, status: status)
    }

    private enum Outcome {
        case finished(Batch)
        /// Retry the same batch after `delay` seconds.
        case retryLater(TimeInterval, GeminiError, Batch)
        /// Attempts exhausted; move on.
        case giveUp(String, Batch)
    }

    private func translate(batch: Batch, bookId: String) async -> Outcome {
        guard let running = books.markBatchRunning(bookId: bookId, index: batch.index)?
            .batches.first(where: { $0.index == batch.index })
        else { return .giveUp("план изменился", batch) }
        var batch = running

        // 1. Lookahead terminology, once per batch.
        if !batch.lookaheadDone, !batch.units.isEmpty {
            await runLookahead(batch: batch, bookId: bookId)
            // The flag is persisted even when the request failed, so a broken
            // lookahead cannot cost a request on every retry.
            books.updateBatch(bookId: bookId, index: batch.index) { $0.lookaheadDone = true }
            batch.lookaheadDone = true
        }

        // 2. Translate.
        let glossary = books.loadGlossary(bookId)
        // The previous batch's text is what keeps a term used just before this
        // batch inside a truncated glossary (docs/SPEC.md §8.4).
        let previousUnits = books.loadPlan(bookId)?
            .batches.first { $0.index == batch.index - 1 }?.units ?? []
        let prompt = PromptBuilder.translationPrompt(
            units: batch.units, glossary: glossary, previousUnits: previousUnits)
        do {
            let raw = try await provider.complete(prompt: prompt)
            switch ResponseParser.parse(raw, expectedCount: batch.units.count) {
            case .success(let answer):
                return finishBatch(batch: batch, answer: answer, bookId: bookId)
            case .failure(let error):
                // One retry with an explicit reminder, as the spec requires.
                let retryRaw = try await provider.complete(
                    prompt: PromptBuilder.retry(prompt))
                switch ResponseParser.parse(retryRaw, expectedCount: batch.units.count) {
                case .success(let answer):
                    return finishBatch(batch: batch, answer: answer, bookId: bookId)
                case .failure:
                    LogStore.shared.append(level: .error, event: "batch.unparsable", fields: [
                        "batch": String(batch.index),
                        "bytes": String(retryRaw.count),
                        "preview": String(retryRaw.prefix(8192)),
                    ])
                    batch.status = .failed
                    batch.error = "unparsable response"
                    books.markBatch(bookId: bookId, index: batch.index, status: .failed,
                                    error: "unparsable response")
                    return .giveUp("\(error)", batch)
                }
            }
        } catch let error as GeminiSessionError {
            let classified = error.geminiError ?? GeminiError(kind: .unknown, code: nil,
                                                              message: error.localizedDescription)
            return retryOrGiveUp(batch: batch, error: classified, bookId: bookId,
                                 detail: error.rawPreview)
        } catch {
            return retryOrGiveUp(
                batch: batch,
                error: GeminiError(kind: .unknown, code: nil, message: error.localizedDescription),
                bookId: bookId, detail: "")
        }
    }

    private func retryOrGiveUp(
        batch: Batch, error: GeminiError, bookId: String, detail: String
    ) -> Outcome {
        var batch = batch

        if error.kind == .unavailable {
            // Nothing was actually asked of the model, so this must not spend an
            // attempt: an outage would otherwise fail batches permanently.
            let restored = max(0, batch.attempts - 1)
            batch.attempts = restored
            batch.status = .pending
            batch.error = error.message
            books.updateBatch(bookId: bookId, index: batch.index) { stored in
                stored.attempts = restored
                stored.status = .pending
                stored.error = error.message
            }
            LogStore.shared.append(level: .warn, event: "batch.offline", fields: [
                "batch": String(batch.index),
                "detail": detail,
            ])
            return .retryLater(
                connectivityRetryDelayOverride ?? TranslationQueue.connectivityRetryDelay,
                error, batch)
        }

        let index = min(batch.attempts - 1, max(0, retrySchedule.count - 1))

        if batch.attempts >= TranslationQueue.maxAttempts {
            batch.status = .failed
            batch.error = error.message
            books.markBatch(bookId: bookId, index: batch.index, status: .failed,
                            error: error.message)
            LogStore.shared.append(level: .error, event: "batch.failed", fields: [
                "batch": String(batch.index),
                "attempts": String(batch.attempts),
                "kind": "\(error.kind)",
                "code": String(error.code ?? -1),
                "detail": detail,
            ])
            return .giveUp(error.message, batch)
        }

        batch.status = .pending
        batch.error = error.message
        let delay: TimeInterval
        switch error.kind {
        case .usageLimit, .ipRegion:
            delay = quotaRetryDelay
        case .unauthenticated, .unavailable:
            delay = 0
        default:
            delay = retrySchedule.isEmpty ? 15 : retrySchedule[index].seconds
        }
        books.updateBatch(bookId: bookId, index: batch.index) { stored in
            stored.status = .pending
            stored.error = error.message
        }
        LogStore.shared.append(level: .warn, event: "batch.retry", fields: [
            "batch": String(batch.index),
            "attempt": String(batch.attempts),
            "kind": "\(error.kind)",
            "delay": String(Int(delay)),
        ])
        return .retryLater(delay, error, batch)
    }

    private func finishBatch(
        batch: Batch, answer: ParsedModelAnswer, bookId: String
    ) -> Outcome {
        let result = BatchResult(
            index: batch.index,
            modelId: provider.modelIdentifier,
            translations: answer.translations,
            glossaryAdditions: answer.glossary,
            rawChars: answer.translations.reduce(0) { $0 + $1.count })
        books.saveResult(result, bookId: bookId)

        if !answer.glossary.isEmpty {
            var store = GlossaryStore(glossary: books.loadGlossary(bookId))
            let firstBlock = batch.units.first?.block ?? -1
            let outcome = store.merge(answer.glossary, source: .auto, firstBlock: firstBlock)
            books.saveGlossary(store.glossary, bookId: bookId)
            CoreLog.info("glossary merged: +\(outcome.added) ~\(outcome.incremented)")
        }

        books.markBatch(bookId: bookId, index: batch.index, status: .done)
        var updated = batch
        updated.status = .done
        updated.error = nil
        updated.finishedAt = Date()
        LogStore.shared.append(level: .info, event: "batch.done", fields: [
            "batch": String(batch.index),
            "units": String(batch.units.count),
            "chars": String(batch.chars),
        ])
        return .finished(updated)
    }

    private func runLookahead(batch: Batch, bookId: String) async {
        let prompt = PromptBuilder.termExtractionPrompt(units: batch.units)
        do {
            let raw = try await provider.complete(prompt: prompt)
            let additions = ResponseParser.parseGlossary(raw)
            guard !additions.isEmpty else { return }
            var store = GlossaryStore(glossary: books.loadGlossary(bookId))
            let outcome = store.merge(additions, source: .auto,
                                      firstBlock: batch.units.first?.block ?? -1)
            books.saveGlossary(store.glossary, bookId: bookId)
            LogStore.shared.append(level: .info, event: "glossary.lookahead", fields: [
                "batch": String(batch.index),
                "added": String(outcome.added),
            ])
        } catch {
            LogStore.shared.append(level: .warn, event: "glossary.lookahead failed",
                                   fields: ["error": "\(error)"])
        }
    }

    /// How long to wait after a quota or region error before trying again.
    private var quotaRetryDelay: TimeInterval {
        quotaRetryDelayOverride ?? Double(settings.retryLimitMinutes) * 60
    }

    private func nextBatchIndex(in plan: BatchPlan) -> Int? {
        plan.batches.first { $0.status == .pending || $0.status == .running }?.index
    }

    // MARK: - State

    private func setStatus(_ status: QueueStatus, message: String?, bookId: String?) {
        self.status = status
        self.message = message
        if let bookId { self.activeBookId = bookId }
        // Keep the library badge in step with the queue without waiting for the
        // next finished batch.
        if let bookId, let plan = books.loadPlan(bookId) {
            _ = library.refreshCounters(bookId: bookId, plan: plan, status: status)
        }
    }

    private func persistState(
        bookId: String, status: QueueStatus, message: String?, currentBatch: Int? = nil
    ) {
        let state = QueueState(
            status: status,
            bookId: bookId,
            currentBatch: currentBatch ?? activeBatchIndex ?? 0,
            message: message,
            updatedAt: Date())
        books.saveState(state, bookId: bookId)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
