import SwiftUI
import BookTransCore

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var showingLogin = false
    @State private var isRefreshing = false

    var body: some View {
        Form {
            geminiSection
            modelSection
            translationSection
            appearanceSection
            dataSection

            Section {
                NavigationLink("Диагностика Gemini") { DebugView() }
                NavigationLink("Лимиты и тариф") { UsageView() }
            } footer: {
                Text("BookTrans 1.0 · перевод через веб-сессию gemini.google.com")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingLogin) { GeminiLoginSheet() }
        .task {
            if app.gemini.signInState == .unknown {
                _ = await app.gemini.refreshSession()
            }
        }
    }

    // MARK: - Sections

    private var geminiSection: some View {
        Section("Аккаунт Gemini") {
            HStack {
                Text("Состояние")
                Spacer()
                Text(stateLabel)
                    .foregroundStyle(stateColor)
            }
            if app.gemini.signInState == .signedIn {
                Button("Обновить сессию") {
                    Task { await refreshSession() }
                }
                .disabled(isRefreshing)
                Button("Выйти из аккаунта", role: .destructive) {
                    Task {
                        await app.gemini.signOut()
                        app.queue.requireAuthentication()
                        app.show("Выполнен выход из Gemini")
                    }
                }
            } else {
                Button("Войти в Gemini") { showingLogin = true }
            }
            if let error = app.gemini.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Модель", selection: Binding(
                get: { app.gemini.selectedModelId },
                set: { app.gemini.selectedModelId = $0 })) {
                ForEach(app.gemini.models) { model in
                    Text(model.label).tag(model.id)
                }
            }
            Button("Обновить список моделей") {
                Task {
                    isRefreshing = true
                    _ = await app.gemini.refreshSession()
                    await app.gemini.refreshAccountStatus()
                    isRefreshing = false
                }
            }
            .disabled(isRefreshing)
        } header: {
            Text("Модель")
        } footer: {
            Text("Список берётся из аккаунта (RPC \(app.gemini.config.rpcStatus)). Если он пуст, "
                 + "используются пресеты из gemini-web.json.")
        }
    }

    private var translationSection: some View {
        Section {
            Toggle("Не гасить экран во время перевода", isOn: app.settings.keepScreenAwakeBinding)
                .onChange(of: app.settings.keepScreenAwake) { _, _ in app.applyIdleTimerSetting() }
            Toggle("Мок-переводчик (без Gemini)", isOn: app.settings.useMockTranslatorBinding)
                .onChange(of: app.settings.useMockTranslator) { _, _ in app.applyProviderSetting() }
        } header: {
            Text("Перевод")
        } footer: {
            Text("iOS усыпляет приложение, поэтому перевод идёт только пока приложение "
                 + "на экране. «Не гасить экран» помогает не прерывать работу.")
        }
    }

    private var appearanceSection: some View {
        Section("Чтение") {
            stepperRow(title: "Размер шрифта", value: app.settings.readerFontSize,
                       range: 14...28, step: 1, suffix: "pt") { app.settings.setReaderFontSize($0) }
            stepperRow(title: "Интерлиньяж", value: app.settings.readerLineHeight,
                       range: 1.2...2.0, step: 0.05, suffix: "") { app.settings.setReaderLineHeight($0) }
            stepperRow(title: "Поля", value: app.settings.readerMargin,
                       range: 8...48, step: 2, suffix: "pt") { app.settings.setReaderMargin($0) }
        }
    }

    private var dataSection: some View {
        Section("Данные") {
            HStack {
                Text("Занято")
                Spacer()
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(totalDiskUsage), countStyle: .file))
                    .foregroundStyle(Theme.secondaryText)
            }
            Button("Скопировать журнал") {
                UIPasteboard.general.string = LogStore.shared.fullText()
                app.show("Журнал скопирован в буфер")
            }
            Button("Очистить журнал", role: .destructive) {
                LogStore.shared.clear()
                app.show("Журнал очищен")
            }
            Button("Записать gemini-web.json для правки") {
                if app.gemini.writeEditableConfigCopy() {
                    app.show("Файл записан в Documents/Config/gemini-web.json")
                } else {
                    app.show("Не удалось записать файл", kind: .error)
                }
            }
        }
    }

    private func stepperRow(
        title: String, value: Double, range: ClosedRange<Double>, step: Double,
        suffix: String, set: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: step < 1 ? "%.2f%@%@" : "%.0f%@%@",
                        value, suffix.isEmpty ? "" : " ", suffix))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            Stepper("", value: Binding(get: { value }, set: set), in: range, step: step)
                .labelsHidden()
        }
    }

    // MARK: - Helpers

    private var totalDiskUsage: Int {
        app.entries.reduce(0) { $0 + app.books.diskUsage($1.id) }
    }

    private var stateLabel: String {
        switch app.gemini.signInState {
        case .unknown: return "неизвестно"
        case .signedOut: return "не выполнен вход"
        case .signedIn: return "вход выполнен"
        }
    }

    private var stateColor: Color {
        switch app.gemini.signInState {
        case .signedIn: return Theme.success
        case .signedOut: return Theme.warning
        case .unknown: return Theme.secondaryText
        }
    }

    private func refreshSession() async {
        isRefreshing = true
        let ok = await app.gemini.refreshSession(force: true)
        if ok { await app.gemini.refreshAccountStatus() }
        isRefreshing = false
        if ok {
            // A waiting queue can carry on now that the session works again.
            if app.queue.status == .waitingAuth, let bookId = app.queue.activeBookId {
                app.queue.resume(bookId: bookId)
            }
            app.show("Сессия Gemini обновлена")
        } else {
            app.show("Нужно войти в Gemini", kind: .error)
        }
    }
}
