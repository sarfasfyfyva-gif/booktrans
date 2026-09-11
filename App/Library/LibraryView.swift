import SwiftUI
import UniformTypeIdentifiers
import BookTransCore

struct LibraryView: View {
    @Environment(AppState.self) private var app
    @State private var isPickingFile = false

    var body: some View {
        Group {
            if app.entries.isEmpty {
                EmptyLibraryView()
            } else {
                BookGrid(entries: app.entries)
            }
        }
        .navigationTitle("BookTrans")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isPickingFile = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(app.isImporting)
                .accessibilityLabel("Добавить книгу")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки")
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: BookTransFileTypes.importable,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await app.importBook(from: url) }
            case .failure(let error):
                app.show("Не удалось выбрать файл: \(error.localizedDescription)", kind: .error)
            }
        }
        .overlay {
            if app.isImporting {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.accent)
                        Text("Импорт книги…")
                            .font(.footnote)
                            .foregroundStyle(Theme.primaryText)
                    }
                    .padding(20)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

/// The file types the picker offers. FB2 has no system type, so the app declares
/// its own (`com.gennadiy.booktrans.fb2` in Info.plist) and `.xml` is accepted
/// because FB2 files are frequently named that way.
enum BookTransFileTypes {
    static let fb2Identifier = "com.gennadiy.booktrans.fb2"

    static var importable: [UTType] {
        var types: [UTType] = [.epub]
        if let fb2 = UTType(fb2Identifier) { types.append(fb2) }
        types.append(.xml)
        return types
    }
}

private struct EmptyLibraryView: View {
    @Environment(AppState.self) private var app
    @State private var isPickingFile = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            Text("Библиотека пуста")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("Добавьте книгу в формате FB2 или EPUB.\nФайл можно открыть через «Поделиться»,\nскопировать в папку BookTrans в «Файлах»\nили выбрать кнопкой ниже.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
            Button {
                isPickingFile = true
            } label: {
                Label("Добавить книгу", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(app.isImporting)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: BookTransFileTypes.importable,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await app.importBook(from: url) }
            }
        }
    }
}

private struct BookGrid: View {
    @Environment(AppState.self) private var app
    let entries: [LibraryEntry]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entry in
                    NavigationLink {
                        BookView(bookId: entry.id)
                    } label: {
                        BookCardView(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Удалить", role: .destructive) {
                            app.deleteBook(entry.id)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
    }
}
