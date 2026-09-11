import SwiftUI
import BookTransCore

/// The reading screen: one chapter at a time, translated or original, with the
/// scroll position kept in blocks rather than pixels so a redraw after a batch
/// finishes does not move the page.
struct ReaderView: View {
    let bookId: String
    /// Chapter to open instead of the stored position, used when a chapter is
    /// picked from the table of contents.
    var startChapter: Int?

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [Chapter] = []
    @State private var translations = TranslationMap()
    @State private var chapterIndex = 0
    @State private var showTranslation = true
    @State private var controller: ReaderWebController?
    @State private var showingTOC = false
    @State private var showingTypography = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Не удалось открыть главу",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if let controller {
                ZStack {
                    ReaderTheme.background.ignoresSafeArea()
                    ReaderWebView(controller: controller)
                        .ignoresSafeArea(edges: .bottom)
                    if !controller.isLoaded {
                        ProgressView().tint(Theme.accent)
                    }
                }
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .navigationTitle(currentChapter?.title ?? "Чтение")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingTOC) { tableOfContents }
        .sheet(isPresented: $showingTypography) { TypographySheet() }
        .task { await start() }
        .onDisappear { Task { await saveCurrentPosition() } }
        .onChange(of: chapterIndex) { _, _ in
            Task { await render(preservingPosition: false) }
        }
        .onChange(of: app.translationRevision) { _, _ in
            Task { await reloadTranslations(redraw: true) }
        }
        .onChange(of: app.settings.readerFontSize) { _, _ in Task { await applyStyle() } }
        .onChange(of: app.settings.readerLineHeight) { _, _ in Task { await applyStyle() } }
        .onChange(of: app.settings.readerMargin) { _, _ in Task { await applyStyle() } }
        .task {
            // Periodic position capture: cheap on a local page and it means a
            // crash or a kill never costs the reader their place.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await saveCurrentPosition()
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                Task {
                    await saveCurrentPosition()
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Назад")
        }
        ToolbarItem(placement: .principal) {
            Button {
                showingTOC = true
            } label: {
                HStack(spacing: 4) {
                    Text(currentChapter?.title ?? "Чтение")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundStyle(Theme.primaryText)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Режим", selection: $showTranslation) {
                    Text("Перевод").tag(true)
                    Text("Оригинал").tag(false)
                }
                .pickerStyle(.inline)
                Divider()
                Button {
                    showingTypography.toggle()
                } label: {
                    Label("Шрифт и поля", systemImage: "textformat.size")
                }
                Divider()
                Button {
                    if chapterIndex > 0 { chapterIndex -= 1 }
                } label: {
                    Label("Предыдущая глава", systemImage: "chevron.up")
                }
                .disabled(chapterIndex <= 0)
                Button {
                    if chapterIndex < chapters.count - 1 { chapterIndex += 1 }
                } label: {
                    Label("Следующая глава", systemImage: "chevron.down")
                }
                .disabled(chapterIndex >= chapters.count - 1)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Меню чтения")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                if chapterIndex > 0 { chapterIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(chapterIndex <= 0)
            Spacer()
            Text(chapterProgressLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button {
                if chapterIndex < chapters.count - 1 { chapterIndex += 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(chapterIndex >= chapters.count - 1)
        }
    }

    private var chapterProgressLabel: String {
        let counts = translations.blockCounts(in: currentChapter ?? Chapter(index: 0, title: "", blocks: []))
        return "\(chapterIndex + 1)/\(chapters.count) · \(counts.done)/\(counts.total)"
    }

    private var currentChapter: Chapter? {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil
    }

    // MARK: - Table of contents

    private var tableOfContents: some View {
        NavigationStack {
            List {
                ForEach(chapters) { chapter in
                    Button {
                        chapterIndex = chapter.index
                        showingTOC = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title.isEmpty ? "Без названия" : chapter.title)
                                    .foregroundStyle(Theme.primaryText)
                                let counts = translations.blockCounts(in: chapter)
                                Text(counts.total == 0
                                     ? "без текста"
                                     : "\(counts.done) из \(counts.total) блоков")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if translations.isTranslated(chapter) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                            }
                            if chapter.index == chapterIndex {
                                Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Оглавление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { showingTOC = false }
                }
            }
        }
    }

    // MARK: - Lifecycle

    private func start() async {
        let loaded = app.books.loadChapters(bookId)
        guard !loaded.isEmpty else {
            failure = "В этой книге нет ни одной главы."
            return
        }
        chapters = loaded

        let progress = app.books.loadProgress(bookId)
        showTranslation = progress.showTranslation
        let restored = min(max(0, progress.chapterIndex), loaded.count - 1)
        chapterIndex = startChapter.map { min(max(0, $0), loaded.count - 1) } ?? restored
        let resumePixels = startChapter == nil && (progress.blockId > 0 || progress.dy > 0)

        reloadTranslationsMap()
        let controller = ReaderWebController(
            bookDirectory: app.paths.bookDir(bookId),
            readerFile: app.paths.readerHTML(bookId))
        self.controller = controller

        await render(preservingPosition: resumePixels,
                     explicitRestore: resumePixels ? (progress.blockId, progress.dy) : nil)
    }

    private func reloadTranslationsMap() {
        guard let plan = app.books.loadPlan(bookId) else {
            translations = TranslationMap()
            return
        }
        translations = TranslationMap(plan: plan, results: app.books.loadResults(bookId, plan: plan))
    }

    /// Redraws only when the chapter on screen actually changed. Batches finish
    /// for every book and every chapter, and reloading the page for each of them
    /// would flash and re-scroll while the user is reading.
    private func reloadTranslations(redraw: Bool) async {
        let before = currentChapter.map { translations.blockCounts(in: $0).done }
        reloadTranslationsMap()
        let after = currentChapter.map { translations.blockCounts(in: $0).done }
        if redraw, before != after { await render(preservingPosition: true) }
    }

    private func render(
        preservingPosition: Bool,
        explicitRestore: (block: Int, dy: Int)? = nil
    ) async {
        guard let controller, let chapter = currentChapter else { return }

        var restore = explicitRestore
        if preservingPosition, restore == nil {
            let position = await controller.capturePosition()
            restore = (position.block, position.dy)
        }

        controller.render(
            chapter: chapter,
            translations: translations,
            configuration: ReaderTheme.configuration(
                settings: app.settings, showTranslation: showTranslation),
            restore: restore)
    }

    private func applyStyle() async {
        guard let controller else { return }
        await controller.applyStyle(ReaderTheme.configuration(
            settings: app.settings, showTranslation: showTranslation))
    }

    private func saveCurrentPosition() async {
        guard let controller else { return }
        let position = await controller.capturePosition()
        app.books.saveProgress(
            ReadingProgress(chapterIndex: chapterIndex, blockId: position.block, dy: position.dy,
                            showTranslation: showTranslation),
            bookId: bookId)
    }
}

/// Typography controls, mirroring the CSS variables in the reader page.
private struct TypographySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Шрифт и интерлиньяж") {
                    slider("Размер", value: app.settings.readerFontSize, range: 13...30, step: 1,
                           suffix: "pt") { app.settings.setReaderFontSize($0) }
                    slider("Интерлиньяж", value: app.settings.readerLineHeight, range: 1.2...2.2,
                           step: 0.05, suffix: "") { app.settings.setReaderLineHeight($0) }
                }
                Section("Поля") {
                    slider("Боковые", value: app.settings.readerMargin, range: 8...56, step: 2,
                           suffix: "pt") { app.settings.setReaderMargin($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Чтение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func slider(
        _ title: String, value: Double, range: ClosedRange<Double>, step: Double,
        suffix: String, set: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.2f%@" : "%.0f %@", value, suffix))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: set), in: range, step: step)
                .tint(Theme.accent)
        }
    }
}
