import SwiftUI
import BookTransCore

/// The visible, editable terminology list. Editing a term offers to re-translate
/// exactly the batches whose text contains it, which is the reason the glossary
/// exists at all.
struct GlossaryView: View {
    let bookId: String

    @Environment(AppState.self) private var app
    @State private var terms: [GlossaryTerm] = []
    @State private var plan: BatchPlan?
    @State private var query = ""
    @State private var editing: EditingTerm?
    @State private var pendingRetranslation: PendingRetranslation?

    /// Wrapper so a term can be presented as a sheet item.
    private struct EditingTerm: Identifiable {
        var term: GlossaryTerm
        var id: String { term.key }
    }

    private struct PendingRetranslation: Identifiable {
        var term: String
        var batches: [Int]
        var id: String { term }
    }

    var body: some View {
        List {
            if terms.isEmpty {
                Section {
                    Text("Глоссарий пока пуст. Он наполняется автоматически перед переводом каждого батча.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            } else {
                ForEach(filtered, id: \.key) { term in
                    Button {
                        editing = EditingTerm(term: term)
                    } label: {
                        row(for: term)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Удалить", role: .destructive) {
                            remove(term)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Глоссарий")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Поиск термина")
        .task { reload() }
        .onChange(of: app.translationRevision) { _, _ in reload() }
        .sheet(item: $editing) { wrapper in
            TermEditor(bookId: bookId, term: wrapper.term) { updated in
                reload()
                offerRetranslation(for: updated)
            }
        }
        .confirmationDialog(
            retranslationTitle,
            isPresented: Binding(
                get: { pendingRetranslation != nil },
                set: { if !$0 { pendingRetranslation = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = pendingRetranslation {
                Button("Перевести заново: \(batchList(pending.batches))") {
                    app.queue.retranslate(bookId: bookId, indices: pending.batches)
                    pendingRetranslation = nil
                }
                Button("Позже", role: .cancel) { pendingRetranslation = nil }
            }
        }
    }

    // MARK: - Rows

    private func row(for term: GlossaryTerm) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(term.term).font(.subheadline.weight(.semibold))
                if term.source == .user {
                    Text("правка")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Text("×\(term.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(term.translation)
                .font(.footnote)
                .foregroundStyle(Theme.primaryText)
            if !term.note.isEmpty {
                Text(term.note).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .contentShape(Rectangle())
    }

    private var filtered: [GlossaryTerm] {
        guard !query.isEmpty else { return terms }
        let needle = query.lowercased()
        return terms.filter {
            $0.term.lowercased().contains(needle) || $0.translation.lowercased().contains(needle)
        }
    }

    private var retranslationTitle: String {
        guard let pending = pendingRetranslation else { return "" }
        return "Термин «\(pending.term)» изменён"
    }

    private func batchList(_ indices: [Int]) -> String {
        indices.prefix(8).map { String($0 + 1) }.joined(separator: ", ")
    }

    // MARK: - Data

    private func reload() {
        let store = GlossaryStore(glossary: app.books.loadGlossary(bookId))
        terms = store.sortedTerms
        plan = app.books.loadPlan(bookId)
    }

    private func remove(_ term: GlossaryTerm) {
        var store = GlossaryStore(glossary: app.books.loadGlossary(bookId))
        _ = store.remove(key: term.key)
        app.books.saveGlossary(store.glossary, bookId: bookId)
        reload()
    }

    private func offerRetranslation(for term: GlossaryTerm) {
        guard let plan else { return }
        let store = GlossaryStore(glossary: app.books.loadGlossary(bookId))
        let batches = store.affectedBatches(of: term.term, in: plan)
        guard !batches.isEmpty else {
            app.show("В переведённых батчах этот термин не встречается")
            return
        }
        pendingRetranslation = PendingRetranslation(term: term.term, batches: batches)
    }
}

/// Edits one term. Saving marks it as user-owned, so no automatic merge will
/// ever overwrite it again.
private struct TermEditor: View {
    let bookId: String
    let term: GlossaryTerm
    let onSaved: (GlossaryTerm) -> Void

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var translation: String
    @State private var note: String

    init(bookId: String, term: GlossaryTerm, onSaved: @escaping (GlossaryTerm) -> Void) {
        self.bookId = bookId
        self.term = term
        self.onSaved = onSaved
        _translation = State(initialValue: term.translation)
        _note = State(initialValue: term.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Термин") {
                    Text(term.term).font(.body.monospaced())
                }
                Section("Перевод") {
                    TextField("Перевод", text: $translation, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("Заметка") {
                    TextField("Необязательно", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section {
                    Text("После сохранения термин помечается как ваш: автоматика больше его не перезапишет.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Правка термина")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { save() }
                        .disabled(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        var store = GlossaryStore(glossary: app.books.loadGlossary(bookId))
        let updated = store.setUserTerm(term: term.term, translation: translation, note: note,
                                        kind: term.kind)
        app.books.saveGlossary(store.glossary, bookId: bookId)
        dismiss()
        onSaved(updated)
    }
}
