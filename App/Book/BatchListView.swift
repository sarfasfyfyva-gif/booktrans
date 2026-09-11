import SwiftUI
import BookTransCore

/// Batch-by-batch view of a book's translation: what is done, what failed, and
/// the manual controls for both.
struct BatchListView: View {
    let bookId: String

    @Environment(AppState.self) private var app
    @State private var plan: BatchPlan?
    @State private var meta: BookMeta?

    var body: some View {
        List {
            summarySection
            batchesSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Батчи")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onChange(of: app.translationRevision) { _, _ in reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        restartAll(failedOnly: true)
                    } label: {
                        Label("Перезапустить батчи с ошибкой", systemImage: "arrow.clockwise")
                    }
                    .disabled(failedIndices.isEmpty)
                    Button {
                        restartAll(failedOnly: false)
                    } label: {
                        Label("Перевести всё заново", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var summarySection: some View {
        if let plan {
            Section {
                let done = plan.doneCount
                let failed = failedIndices.count
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Готово")
                        Spacer()
                        Text("\(done) из \(plan.batches.count)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ProgressView(value: plan.batches.isEmpty ? 0
                                 : Double(done) / Double(plan.batches.count))
                        .tint(Theme.accent)
                    if failed > 0 {
                        Text("С ошибкой: \(failed)")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                    Text("Целевой размер батча: \(plan.target) знаков")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            } footer: {
                if let message = app.queue.message, app.queue.activeBookId == bookId {
                    Text(message)
                }
            }
        }
    }

    @ViewBuilder
    private var batchesSection: some View {
        Section("Батчи") {
            if let plan {
                ForEach(plan.batches) { batch in
                    row(for: batch)
                        .swipeActions(edge: .trailing) {
                            Button("Заново") {
                                app.queue.retranslate(bookId: bookId, indices: [batch.index])
                            }
                            .tint(Theme.accent)
                        }
                }
            } else {
                Text("План не найден").foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func row(for batch: Batch) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(batch.index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusChip(status: chipStatus(batch.status))
                    Text("\(batch.chars) знаков · \(batch.units.count) блоков")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    if batch.attempts > 0 {
                        Text("попыток: \(batch.attempts)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                if let error = batch.error, batch.status == .failed || batch.status == .pending {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(batch.status == .failed ? Theme.danger : Theme.warning)
                        .lineLimit(2)
                }
                if let finishedAt = batch.finishedAt {
                    Text(finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func chipStatus(_ status: BatchStatus) -> QueueStatus {
        switch status {
        case .done: return .idle
        case .running: return .running
        case .pending: return .paused
        case .failed: return .failed
        }
    }

    // MARK: - Data

    private var failedIndices: [Int] {
        plan?.batches.filter { $0.status == .failed }.map(\.index) ?? []
    }

    private func reload() {
        plan = app.books.loadPlan(bookId)
        meta = app.books.loadMeta(bookId)
    }

    private func restartAll(failedOnly: Bool) {
        guard let plan else { return }
        let indices = failedOnly
            ? failedIndices
            : plan.batches.filter { $0.status != .done }.map(\.index)
        guard !indices.isEmpty else { return }
        app.queue.retranslate(bookId: bookId, indices: indices)
        app.show("Перезапускаем батчи: \(indices.count)")
    }
}
