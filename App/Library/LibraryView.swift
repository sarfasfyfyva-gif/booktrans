import SwiftUI
import BookTransCore

struct LibraryView: View {
    @Environment(AppState.self) private var app

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
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки")
            }
        }
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            Text("Библиотека пуста")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("Добавьте книгу в формате FB2 или EPUB —\nкнопкой импорта, через «Поделиться» из другого\nприложения или скопировав файл в папку BookTrans\nв приложении «Файлы».")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct BookGrid: View {
    let entries: [LibraryEntry]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { entry in
                    BookCardView(entry: entry)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
    }
}
