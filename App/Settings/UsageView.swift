import SwiftUI
import BookTransCore

/// Subscription tier and rolling-window consumption, read from the account RPCs.
struct UsageView: View {
    @Environment(AppState.self) private var app
    @State private var isLoading = false
    @State private var showsRaw = false

    var body: some View {
        List {
            Section("Тариф") {
                HStack {
                    Text("Аккаунт")
                    Spacer()
                    Text(app.gemini.usage?.tierLabel ?? "неизвестно")
                        .foregroundStyle(Theme.secondaryText)
                }
                if let status = app.gemini.account?.statusCode {
                    HStack {
                        Text("Код статуса")
                        Spacer()
                        Text(String(status)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                    }
                }
            }

            windowsSection

            Section {
                Toggle("Показать сырые ответы", isOn: $showsRaw)
            }

            if showsRaw {
                rawSection
            }

            Section {
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Обновляем…") }
                    } else {
                        Text("Обновить данные о лимитах")
                    }
                }
                .disabled(isLoading)
            } footer: {
                Text("Лимиты берутся из RPC \(app.gemini.config.rpcUsage) и \(app.gemini.config.rpcQuota). "
                     + "Точные поля этих ответов не документированы, поэтому сырые значения "
                     + "показаны как есть.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Лимиты")
        .navigationBarTitleDisplayMode(.inline)
        .task { if app.gemini.usage == nil { await reload() } }
    }

    @ViewBuilder
    private var windowsSection: some View {
        Section("Окна лимитов") {
            if let usage = app.gemini.usage,
               let short = usage.shortWindow, let long = usage.longWindow {
                windowRow(title: "Короткое окно (~5 часов)", window: short)
                windowRow(title: "Длинное окно (~неделя)", window: long)
            } else {
                Text("Данные о лимитах недоступны")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func windowRow(title: String, window: GeminiUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f%%", window.usedFraction * 100))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            ProgressView(value: window.usedFraction)
                .tint(window.usedFraction > 0.9 ? Theme.danger : Theme.accent)
        }
    }

    @ViewBuilder
    private var rawSection: some View {
        if let usage = app.gemini.usage {
            Section("Сырой ответ \(app.gemini.config.rpcUsage)") {
                Text(usage.raw.jsonText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        ForEach(app.gemini.quotaPayloads.keys.sorted(), id: \.self) { key in
            Section("Сырой ответ \(app.gemini.config.rpcQuota) — \(key)") {
                Text(app.gemini.quotaPayloads[key] ?? "")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func reload() async {
        isLoading = true
        if app.gemini.signInState != .signedIn {
            _ = await app.gemini.refreshSession()
        }
        await app.gemini.refreshUsage()
        await app.gemini.refreshQuotaCounters()
        isLoading = false
    }
}
