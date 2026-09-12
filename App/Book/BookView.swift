import SwiftUI
import BookTransCore

/// A book's home screen: what it is, how far translation has come, and the way in
/// to reading it.
struct BookView: View {
    let bookId: String

    @Environment(AppState.self) private var app
    @State private var meta: BookMeta?
    @State private var chapters: [Chapter] = []
    @State private var plan: BatchPlan?
    @State private var translations = TranslationMap()
    @State private var readingChapter: Int?

    var body: some View {
        List {
            header
            translationControlSection
            progressSection
            readingSection
            chaptersSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(meta?.title ?? "Книга")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onChange(of: app.translationRevision) { _, _ in reload() }
        // Presented by the same flag the transport host uses to decide who owns the
        // WebView: presenting and handing over have to happen in one update, or the
        // 1x1 host can reclaim the page between the two and the sheet comes up empty.
        .sheet(isPresented: Binding(get: { app.isLoginPresented },
                                    set: { app.isLoginPresented = $0 })) { GeminiLoginSheet() }
        .navigationDestination(isPresented: Binding(
            get: { readingChapter != nil },
            set: { if !$0 { readingChapter = nil } })) {
            if let index = readingChapter {
                ReaderView(bookId: bookId, startChapter: index)
            }
        }
    }

    // MARK: - Translation control

    @ViewBuilder
    private var translationControlSection: some View {
        Section("Управление переводом") {
            if let plan {
                let remaining = plan.batches.filter { $0.status != .done }.count
                let failed = plan.batches.filter { $0.status == .failed }.count

                if remaining == 0 {
                    Label("Перевод завершён", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.success)
                } else {
                    switch effectiveStatus {
                    case .running:
                        statusRow(spinner: true)
                        Button(role: .destructive) {
                            app.queue.pause()
                        } label: {
                            Label("Пауза", systemImage: "pause")
                        }

                    case .waitingQuota:
                        // The queue retries on its own; say so rather than
                        // offering a resume the user does not need.
                        statusRow(spinner: true)
                        Text("Продолжим автоматически")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Button(role: .destructive) {
                            app.queue.pause()
                        } label: {
                            Label("Пауза", systemImage: "pause")
                        }

                    case .waitingAuth:
                        statusRow(spinner: false)
                        Button {
                            app.isLoginPresented = true
                        } label: {
                            Label("Войти в Gemini",
                                  systemImage: "person.crop.circle.badge.exclamationmark")
                        }

                    case .paused, .idle, .failed:
                        Button {
                            app.queue.resume(bookId: bookId)
                        } label: {
                            Label(plan.doneCount > 0 ? "Продолжить перевод" : "Начать перевод",
                                  systemImage: "play")
                        }
                        Text("Осталось батчей: \(remaining)"
                             + (failed > 0 ? ", из них с ошибкой: \(failed)" : ""))
                            .font(.caption)
                            .foregroundStyle(failed > 0 ? Theme.danger : Theme.secondaryText)
                    }
                }
            }

            NavigationLink {
                GlossaryView(bookId: bookId)
            } label: {
                Label("Глоссарий", systemImage: "character.book.closed")
            }
            NavigationLink {
                BatchListView(bookId: bookId)
            } label: {
                Label("Батчи", systemImage: "square.stack.3d.up")
            }
        }
    }

    private func statusRow(spinner: Bool) -> some View {
        HStack {
            Text(app.queue.activeBookId == bookId
                 ? (app.queue.message ?? "Идёт перевод")
                 : "Состояние из прошлого запуска")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if spinner { ProgressView().controlSize(.small) }
        }
    }

    /// What this book's translation is doing. When the queue is not working on
    /// this book the stored state is what the user last saw, which is also what
    /// lets a pause survive a relaunch.
    private var effectiveStatus: QueueStatus {
        if app.queue.activeBookId == bookId { return app.queue.status }
        return app.books.loadState(bookId)?.status ?? .idle
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                CoverThumbnail(bookId: bookId, coverPath: meta?.coverPath)
                    .frame(width: 84, height: 126)
                VStack(alignment: .leading, spacing: 6) {
                    Text(meta?.title ?? "—")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    if let author = meta?.author, !author.isEmpty {
                        Text(author).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    if let meta {
                        Text("\(meta.format.rawValue.uppercased()) · \(meta.sourceLang) → \(meta.targetLang)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Text("\(meta.chapterCount) глав · \(formattedCharacters(meta.charCount)) знаков")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if let status = app.entries.first(where: { $0.id == bookId })?.status {
                        StatusChip(status: status)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder
    private var progressSection: some View {
        Section("Перевод") {
            if let plan {
                let done = plan.doneCount
                let total = plan.batches.count
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Батчей готово")
                        Spacer()
                        Text("\(done) из \(total)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                        .tint(Theme.accent)
                    let blocks = chapterProgress
                    Text("Блоков переведено: \(blocks.done) из \(blocks.total)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Text("Батч ≈ \(plan.target) знаков, в среднем \(averageBatchSize(plan)) знаков")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 2)
            } else {
                Text("План перевода ещё не построен").foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var readingSection: some View {
        Section {
            Button {
                let progress = app.books.loadProgress(bookId)
                readingChapter = min(max(0, progress.chapterIndex), max(0, chapters.count - 1))
            } label: {
                Label("Читать", systemImage: "book")
            }
            .disabled(chapters.isEmpty)
        }
    }

    @ViewBuilder
    private var chaptersSection: some View {
        Section("Главы") {
            ForEach(chapters) { chapter in
                Button {
                    readingChapter = chapter.index
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title.isEmpty ? "Без названия" : chapter.title)
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                            let counts = translations.blockCounts(in: chapter)
                            Text(counts.total == 0 ? "без текста" : "\(counts.done) из \(counts.total) блоков")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if translations.isTranslated(chapter) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.success)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data

    private func reload() {
        meta = app.books.loadMeta(bookId)
        chapters = app.books.loadChapters(bookId)
        plan = app.books.loadPlan(bookId)
        if let plan {
            translations = TranslationMap(plan: plan, results: app.books.loadResults(bookId, plan: plan))
        } else {
            translations = TranslationMap()
        }
    }

    private var chapterProgress: (done: Int, total: Int) {
        chapters.reduce(into: (done: 0, total: 0)) { accumulator, chapter in
            let counts = translations.blockCounts(in: chapter)
            accumulator.done += counts.done
            accumulator.total += counts.total
        }
    }

    private func averageBatchSize(_ plan: BatchPlan) -> Int {
        guard !plan.batches.isEmpty else { return 0 }
        return plan.batches.reduce(0) { $0 + $1.chars } / plan.batches.count
    }

    private func formattedCharacters(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }
}

/// Cover image loaded straight from the book directory.
struct CoverThumbnail: View {
    let bookId: String
    let coverPath: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.card)
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "book.closed")
                            .font(.title2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            } else {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
    }

    private var url: URL? {
        guard let coverPath, !coverPath.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = docs
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(bookId, isDirectory: true)
            .appendingPathComponent(coverPath)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
