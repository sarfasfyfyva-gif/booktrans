import SwiftUI
import BookTransCore

struct BookCardView: View {
    let entry: LibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            Text(entry.title.isEmpty ? "Без названия" : entry.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !entry.author.isEmpty {
                Text(entry.author)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            ProgressView(value: entry.progressFraction)
                .progressViewStyle(.linear)
                .tint(entry.status == .failed ? Theme.danger : Theme.accent)
            HStack(spacing: 6) {
                Text("\(entry.batchesDone)/\(entry.batchesTotal)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                StatusChip(status: entry.status)
            }
        }
    }

    private var cover: some View {
        CoverThumbnail(bookId: entry.id, coverPath: entry.coverPath)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }
}

struct StatusChip: View {
    let status: QueueStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .idle: return "готово"
        case .running: return "перевод"
        case .paused: return "пауза"
        case .waitingQuota: return "лимит"
        case .waitingAuth: return "вход"
        case .failed: return "ошибка"
        }
    }

    private var color: Color {
        switch status {
        case .idle: return Theme.secondaryText
        case .running: return Theme.accent
        case .paused: return Theme.secondaryText
        case .waitingQuota: return Theme.warning
        case .waitingAuth: return Theme.warning
        case .failed: return Theme.danger
        }
    }
}
