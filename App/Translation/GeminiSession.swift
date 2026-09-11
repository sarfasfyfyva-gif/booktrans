import Foundation
import BookTransCore

/// Owns the Gemini account session: configuration, WIZ parameters, model list,
/// usage counters and the single generate call. Everything else in the app asks
/// this type to turn a prompt into model output.
@MainActor
@Observable
final class GeminiSession {
    enum SignInState: Equatable {
        case unknown
        case signedOut
        case signedIn
    }

    let transport: GeminiWebTransport
    private let paths: BookPaths

    private(set) var config: GeminiConfig
    private(set) var wiz: WizParameters?
    private(set) var signInState: SignInState = .unknown
    private(set) var account: GeminiAccountStatus?
    private(set) var usage: GeminiUsage?
    private(set) var models: [GeminiModel] = []
    private(set) var lastError: String?
    private(set) var lastGeneration: GenerationDebugInfo?
    /// Raw `qpEbW` payloads keyed by `flash` / `pro`.
    private(set) var quotaPayloads: [String: String] = [:]

    /// Selected model id; falls back to the configured default.
    var selectedModelId: String {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.modelDefaultsKey) }
    }

    private static let modelDefaultsKey = "com.gennadiy.booktrans.selectedModel"

    /// Last full request/response, kept for the debug screen.
    struct GenerationDebugInfo {
        var requestURL: String
        var requestHeaders: [String: String]
        var requestBodyPreview: String
        var status: Int
        var rawResponsePreview: String
        var rawResponseBytes: Int
        var errorCode: Int?
        var frameCount: Int
        var elapsedSeconds: Double
        var at: Date
    }

    private var reqid = ReqidGenerator()
    private var lastWizRefresh: Date?
    private var lastCookieRotation: Date?

    init(paths: BookPaths, transport: GeminiWebTransport) {
        self.paths = paths
        self.transport = transport
        self.config = GeminiConfigLoader.resolve(override: FileStore.readData(paths.geminiConfigOverride))
            ?? GeminiConfig.lastResort
        self.models = config.models
        let stored = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
        self.selectedModelId = stored ?? config.defaultModel
    }

    var selectedModel: GeminiModel? { config.model(id: selectedModelId) }

    // MARK: - Configuration

    /// Re-reads the on-device override; used by the settings screen and after a
    /// protocol capture.
    func reloadConfig() {
        config = GeminiConfigLoader.resolve(override: FileStore.readData(paths.geminiConfigOverride))
            ?? GeminiConfig.lastResort
        models = mergedModels(rpc: account?.models ?? [], presets: config.models)
        if !models.contains(where: { $0.id == selectedModelId }) {
            selectedModelId = config.defaultModel
        }
        LogStore.shared.append(level: .info, event: "config.reloaded", fields: [
            "models": String(models.count),
            "default": config.defaultModel,
        ])
    }

    /// Writes the bundled defaults into `Documents/Config/gemini-web.json` so
    /// the user has something to edit after a protocol capture.
    @discardableResult
    func writeEditableConfigCopy() -> Bool {
        guard let data = GeminiConfigLoader.bundledJSONData() else { return false }
        return FileStore.writeData(data, to: paths.geminiConfigOverride)
    }

    var hasConfigOverride: Bool { FileStore.exists(paths.geminiConfigOverride) }

    /// The RPC is the source of truth for which models exist and what the account
    /// calls them; presets only fill in `capacity`/`number` (which are positional
    /// and cannot be derived) and stand in when the RPC returns nothing.
    private func mergedModels(rpc: [GeminiModel], presets: [GeminiModel]) -> [GeminiModel] {
        guard !rpc.isEmpty else { return presets }
        var result = rpc
        for preset in presets where !result.contains(where: { $0.id == preset.id }) {
            result.append(preset)
        }
        return result
    }

    // MARK: - Session

    /// Loads the app page if needed and refreshes WIZ parameters. Returns
    /// `false` when the account is not signed in.
    @discardableResult
    func refreshSession(force: Bool = false) async -> Bool {
        let stale = lastWizRefresh.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
        let onGemini = transport.currentURL?.contains("gemini.google.com") ?? false
        do {
            if force || !onGemini || wiz == nil {
                try await transport.load(config.appURL)
            } else if stale {
                // A same-URL reload keeps the WebView on gemini.google.com so
                // the following fetch stays same-origin.
                webViewReload()
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
            let parameters = try await transport.readWizParameters(config: config)
            wiz = parameters
            lastWizRefresh = Date()
            signInState = parameters.isSignedIn ? .signedIn : .signedOut
            lastError = signInState == .signedOut ? "Нужно войти в Gemini." : nil
            return parameters.isSignedIn
        } catch {
            signInState = .unknown
            lastError = error.localizedDescription
            LogStore.shared.append(level: .error, event: "session.refresh failed", fields: ["error": "\(error)"])
            return false
        }
    }

    private func webViewReload() {
        transport.webView.reload()
    }

    func markSignedOut() {
        signInState = .signedOut
        wiz = nil
        lastWizRefresh = nil
    }

    /// Clears cookies and website data, then returns to the signed-out state.
    func signOut() async {
        await transport.clearWebsiteData()
        markSignedOut()
        account = nil
        usage = nil
        LogStore.shared.append(level: .info, event: "session.signedOut")
    }

    /// Keeps `__Secure-1PSIDTS` fresh; called before each generation.
    private func maintainCookies(force: Bool = false) async {
        let due = lastCookieRotation.map { Date().timeIntervalSince($0) > 20 * 60 } ?? true
        guard force || due else { return }
        lastCookieRotation = Date()
        await transport.rotateCookies(config: config)
    }

    // MARK: - batchexecute RPCs

    private func batchExec(
        rpcId: String, payload: String, sourcePath: GeminiRequestBuilder.SourcePath
    ) async throws -> JSONValue {
        guard let wiz, wiz.isSignedIn else {
            throw GeminiSessionError.notSignedIn
        }
        let sessionUUID = GeminiRequestBuilder.newSessionUUID()
        let request = TransportRequest(
            url: GeminiRequestBuilder.batchExecURL(
                config: config, rpcId: rpcId, sourcePath: sourcePath,
                bl: wiz.bl, sessionId: wiz.sessionId, reqid: reqid.next()),
            method: "POST",
            headers: GeminiRequestBuilder.batchExecHeaders(sessionUUID: sessionUUID),
            body: GeminiRequestBuilder.batchExecBody(
                at: wiz.at,
                fReq: GeminiRequestBuilder.batchExecFReq(rpcId: rpcId, payload: payload)),
            timeout: 60)

        let response = try await transport.send(request)
        if let httpError = GeminiResponseParser.error(forHTTPStatus: response.status) {
            throw GeminiSessionError.protocolError(httpError, raw: preview(response.raw))
        }
        let frames = GeminiResponseParser.parseFrames(response.raw)
        guard let result = GeminiResponseParser.payload(for: rpcId, in: frames) else {
            throw GeminiSessionError.unparsable(rpcId: rpcId, raw: preview(response.raw))
        }
        if let error = result.error {
            throw GeminiSessionError.protocolError(error, raw: preview(response.raw))
        }
        return result.value
    }

    /// `otAQ7b` on `/app`: account status and the authoritative model list.
    func refreshAccountStatus() async {
        do {
            let value = try await batchExec(rpcId: config.rpcStatus, payload: "[]", sourcePath: .app)
            let status = GeminiResponseParser.parseAccountStatus(value, presets: config.models)
            account = status
            models = mergedModels(rpc: status.models, presets: config.models)
            if let error = status.error {
                lastError = error.message
                if error.kind == .unauthenticated { signInState = .signedOut }
            } else {
                signInState = .signedIn
                lastError = nil
            }
            LogStore.shared.append(level: .info, event: "rpc.status", fields: [
                "code": String(status.statusCode ?? -1),
                "models": String(status.models.count),
                "tier": String(status.tierRaw ?? -1),
            ])
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            LogStore.shared.append(level: .warn, event: "rpc.status failed", fields: ["error": "\(error)"])
        }
    }

    /// `jSf9Qc` on `/usage`: subscription tier and window consumption.
    func refreshUsage() async {
        do {
            let value = try await batchExec(rpcId: config.rpcUsage, payload: "[]", sourcePath: .usage)
            usage = GeminiResponseParser.parseUsage(value)
            LogStore.shared.append(level: .info, event: "rpc.usage", fields: [
                "tier": usage?.tierLabel ?? "?",
            ])
        } catch {
            LogStore.shared.append(level: .warn, event: "rpc.usage failed", fields: ["error": "\(error)"])
        }
    }

    /// `qpEbW`: per-model limit counters. The response shape is not documented
    /// by any capture we have, so the raw payloads are kept verbatim for the
    /// usage screen rather than guessed at.
    func refreshQuotaCounters() async {
        let attempts: [(String, String)] = [
            ("flash", GeminiRequestBuilder.QuotaPayload.flash),
            ("pro", GeminiRequestBuilder.QuotaPayload.pro),
        ]
        for (key, payload) in attempts {
            do {
                let value = try await batchExec(rpcId: config.rpcQuota, payload: payload, sourcePath: .usage)
                quotaPayloads[key] = value.jsonText
            } catch {
                quotaPayloads[key] = "ошибка: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
        LogStore.shared.append(level: .info, event: "rpc.quota", fields: [
            "keys": quotaPayloads.keys.sorted().joined(separator: ","),
        ])
    }

    // MARK: - Generation

    /// Sends one prompt as a fresh single-turn conversation and returns the text.
    func generate(prompt: String) async throws -> String {
        let started = Date()
        if wiz == nil || !(wiz?.isSignedIn ?? false) {
            let ok = await refreshSession()
            if !ok { throw GeminiSessionError.notSignedIn }
        }
        if lastWizRefresh.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? false {
            await refreshSession()
        }
        await maintainCookies()

        guard let wiz, wiz.isSignedIn else { throw GeminiSessionError.notSignedIn }
        guard let model = selectedModel else { throw GeminiSessionError.noModel }

        let sessionUUID = GeminiRequestBuilder.newSessionUUID()
        let requestURL = GeminiRequestBuilder.generateURL(
            config: config, bl: wiz.bl, sessionId: wiz.sessionId, reqid: reqid.next())
        let headers = GeminiRequestBuilder.generateHeaders(model: model, sessionUUID: sessionUUID)
        let body = GeminiRequestBuilder.generateBody(
            at: wiz.at,
            fReq: GeminiRequestBuilder.generateFReq(
                prompt: prompt, model: model, sessionUUID: sessionUUID))

        let response: TransportResponse
        do {
            response = try await transport.send(TransportRequest(
                url: requestURL, method: "POST", headers: headers, body: body))
        } catch {
            let info = GenerationDebugInfo(
                requestURL: requestURL, requestHeaders: headers,
                requestBodyPreview: Self.previewBody(body), status: 0, rawResponsePreview: "",
                rawResponseBytes: 0, errorCode: nil, frameCount: 0,
                elapsedSeconds: Date().timeIntervalSince(started), at: Date())
            lastGeneration = info
            throw error
        }

        let parsed = GeminiResponseParser.parseStreamGenerate(response.raw)
        lastGeneration = GenerationDebugInfo(
            requestURL: requestURL, requestHeaders: headers,
            requestBodyPreview: Self.previewBody(body),
            status: response.status,
            rawResponsePreview: preview(response.raw, limit: 4096),
            rawResponseBytes: response.raw.count,
            errorCode: parsed.error?.code,
            frameCount: parsed.frameCount,
            elapsedSeconds: Date().timeIntervalSince(started), at: Date())

        if let httpError = GeminiResponseParser.error(forHTTPStatus: response.status) {
            if httpError.kind == .unauthenticated { markSignedOut() }
            throw GeminiSessionError.protocolError(httpError, raw: preview(response.raw))
        }
        if let error = parsed.error {
            if error.kind == .unauthenticated { markSignedOut() }
            LogStore.shared.append(level: .warn, event: "generate.failed", fields: [
                "kind": "\(error.kind)", "code": String(error.code ?? -1),
            ])
            throw GeminiSessionError.protocolError(error, raw: preview(response.raw))
        }
        guard let text = parsed.text else {
            LogStore.shared.append(level: .error, event: "generate.empty",
                                   fields: ["bytes": String(response.raw.count)])
            throw GeminiSessionError.unparsable(rpcId: "StreamGenerate", raw: preview(response.raw))
        }
        LogStore.shared.append(level: .info, event: "generate.ok", fields: [
            "in": String(prompt.count), "out": String(text.count),
            "frames": String(parsed.frameCount),
            "reasoning": parsed.hadReasoning ? "1" : "0",
            "s": String(format: "%.1f", Date().timeIntervalSince(started)),
        ])
        return text
    }

    // MARK: - Diagnostics

    /// One-shot sanity check used by the debug screen: translate a short
    /// paragraph and show exactly what came back.
    func runSmokeTest() async -> String {
        let probe = "The quick brown fox jumps over the lazy dog."
        do {
            let text = try await generate(prompt: """
            [ИНСТРУКЦИЯ]
            Ты профессиональный переводчик. Переведи текст с английского на русский.

            [ЗАДАЧА]
            Верни ровно один JSON-объект без markdown-обрамления:
            {"translations": ["<перевод>"]}

            [БЛОКИ]
            ["\(probe)"]
            """)
            return "Модель вернула:\n\(text)"
        } catch {
            return "Ошибка: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    private func preview(_ text: String, limit: Int = 8192) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n…(обрезано)"
    }

    private static func previewBody(_ body: String) -> String {
        let limit = 1200
        return body.count <= limit ? body : String(body.prefix(limit)) + "…"
    }
}

enum GeminiSessionError: LocalizedError {
    case notSignedIn
    case noModel
    case protocolError(GeminiError, raw: String)
    case unparsable(rpcId: String, raw: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Нужно войти в Gemini."
        case .noModel: return "Не выбрана модель Gemini."
        case .protocolError(let error, _): return error.message
        case .unparsable(let rpcId, _): return "Не удалось разобрать ответ Gemini (\(rpcId))."
        }
    }

    /// Failure classification used by the translation queue.
    var geminiError: GeminiError? {
        if case .protocolError(let error, _) = self { return error }
        if case .notSignedIn = self { return .unauthenticated }
        return nil
    }

    /// Raw response tail, for the log.
    var rawPreview: String {
        switch self {
        case .protocolError(_, let raw), .unparsable(_, let raw): return raw
        default: return ""
        }
    }
}
