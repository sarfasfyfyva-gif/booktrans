import SwiftUI
import BookTransCore

/// Everything needed to tell whether a failure is ours or the protocol's:
/// session parameters, cookies, the model list, the account RPCs, and the last
/// raw exchange.
struct DebugView: View {
    @Environment(AppState.self) private var app

    @State private var isBusy = false
    @State private var smokeTestResult: String?
    @State private var showsRawResponse = false
    @State private var showsWizSecrets = false
    @State private var cookies: [GeminiWebTransport.CookieInfo] = []

    var body: some View {
        List {
            actionsSection
            wizSection
            cookiesSection
            modelsSection
            lastExchangeSection
            if showsRawResponse { rawResponseSection }
            logSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAll() }
        .refreshable { await refreshAll() }
    }

    // MARK: - Sections

    private var actionsSection: some View {
        Section {
            Button("Перечитать параметры") {
                Task { await refreshAll() }
            }
            .disabled(isBusy)

            Button("Тест: перевести 1 абзац") {
                Task {
                    isBusy = true
                    smokeTestResult = await app.gemini.runSmokeTest()
                    isBusy = false
                }
            }
            .disabled(isBusy)

            Button(showsRawResponse ? "Скрыть сырой ответ" : "Показать сырой ответ") {
                showsRawResponse.toggle()
            }
            .disabled(app.gemini.lastGeneration == nil)

            Button("Скопировать лог") {
                UIPasteboard.general.string = LogStore.shared.fullText()
                app.show("Журнал скопирован в буфер")
            }

            if let result = smokeTestResult {
                Text(result)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Действия")
        } footer: {
            Text("Тест отправляет один короткий абзац в выбранную модель и показывает, "
                 + "что именно вернул сервер.")
        }
    }

    private var wizSection: some View {
        Section {
            // The first thing to read when the app says it is not signed in: it
            // separates "the login never reached this app" from "the session is
            // here but the page did not give up its parameters".
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: app.gemini.signInState == .signedIn
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(app.gemini.signInState == .signedIn
                                     ? Theme.success : Theme.warning)
                Text(app.gemini.sessionDiagnosis)
                    .font(.footnote)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledRow("Cookies Google",
                       app.gemini.authCookieNames.isEmpty
                       ? "нет"
                       : app.gemini.authCookieNames.joined(separator: ", "))
            if let wiz = app.gemini.wiz {
                LabeledRow("at (\(app.gemini.config.wizAt))",
                           showsWizSecrets ? wiz.at : WizParameters.mask(wiz.at))
                LabeledRow("bl (\(app.gemini.config.wizBuild))", wiz.bl)
                LabeledRow("f.sid (\(app.gemini.config.wizSession))", wiz.sessionId)
                LabeledRow("hl (\(app.gemini.config.wizLang))", wiz.language)
                LabeledRow("Источник параметров", wiz.source)
            } else {
                Text("Параметры не прочитаны").foregroundStyle(Theme.secondaryText)
            }
            LabeledRow("Адрес страницы", app.gemini.transport.currentURL ?? "—")
            LabeledRow("gemini-web.json", app.gemini.hasConfigOverride
                       ? "свой файл в Documents/Config" : "встроенный по умолчанию")
            Toggle("Показать секреты", isOn: $showsWizSecrets)
        } header: {
            Text("Параметры сессии")
        } footer: {
            Text("Токен никогда не записывается в журнал: значение заменяется на <redacted>.")
        }
    }

    private var cookiesSection: some View {
        Section("Cookies (google.com)") {
            if cookies.isEmpty {
                Text("нет").foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(cookies, id: \.name) { cookie in
                    HStack {
                        Text(cookie.name).font(.caption.monospaced())
                        Spacer()
                        Text(cookie.expiresInSeconds == 0
                             ? "сессионная"
                             : "истекает через \(cookie.expiresInSeconds / 60) мин")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private var modelsSection: some View {
        Section {
            if app.gemini.models.isEmpty {
                Text("список пуст").foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(app.gemini.models) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.label)
                        Text("\(model.id) · capacity \(model.capacity) · number \(model.number)")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            if let account = app.gemini.account {
                DisclosureGroup("Сырой ответ \(app.gemini.config.rpcStatus)") {
                    Text(account.raw.jsonText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Модели аккаунта")
        } footer: {
            Text("Истина о доступных моделях — ответ RPC \(app.gemini.config.rpcStatus). "
                 + "capacity и number при совпадении id берутся из пресетов.")
        }
    }

    @ViewBuilder
    private var lastExchangeSection: some View {
        if let info = app.gemini.lastGeneration {
            Section("Последний обмен") {
                LabeledRow("Время", info.at.formatted(date: .omitted, time: .standard))
                LabeledRow("Статус", String(info.status))
                LabeledRow("Байт ответа", String(info.rawResponseBytes))
                LabeledRow("Фреймов", String(info.frameCount))
                LabeledRow("Секунд", String(format: "%.1f", info.elapsedSeconds))
                if let code = info.errorCode {
                    LabeledRow("Код ошибки", String(code))
                }
                DisclosureGroup("Заголовки запроса") {
                    ForEach(info.requestHeaders.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(info.requestHeaders[key] ?? "")")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rawResponseSection: some View {
        if let info = app.gemini.lastGeneration {
            Section("Сырой ответ") {
                Text(info.rawResponsePreview)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            Section("Тело запроса (начало)") {
                Text(info.requestBodyPreview)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var logSection: some View {
        Section("Журнал (последние строки)") {
            let lines = LogStore.shared.tail(20)
            if lines.isEmpty {
                Text("пусто").foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced())
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshAll() async {
        isBusy = true
        _ = await app.gemini.refreshSession(force: app.gemini.wiz == nil)
        await app.gemini.refreshAccountStatus()
        cookies = await app.gemini.transport.cookies()
        isBusy = false
    }
}

private struct LabeledRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(title).font(.footnote)
            Spacer(minLength: 12)
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
