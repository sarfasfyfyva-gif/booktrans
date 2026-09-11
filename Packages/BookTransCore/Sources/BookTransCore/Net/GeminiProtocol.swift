import Foundation

/// A model offered by the account, as reported by the `status` RPC.
public struct GeminiModel: Codable, Sendable, Hashable, Identifiable {
    /// Opaque model id sent in the model header and payload index 79.
    public var id: String
    public var label: String
    /// Model "capacity" sent in the model header; read from the RPC, default 12.
    public var capacity: Int
    /// Model "number" sent in the model header and payload index 79.
    public var number: Int

    public init(id: String, label: String, capacity: Int, number: Int) {
        self.id = id
        self.label = label
        self.capacity = capacity
        self.number = number
    }

    private enum CodingKeys: String, CodingKey { case id, label, capacity, number }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        capacity = try c.decodeIfPresent(Int.self, forKey: .capacity) ?? 12
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 1
    }
}

/// Everything that is expected to rot as the web client changes. All of it is
/// data: the bundled `gemini-web.json` can be replaced on device without
/// rebuilding the app (see docs/GEMINI-CAPTURE.md).
///
/// Decode-only: the on-disk representation is the single source of truth and is
/// edited by hand after a protocol capture, so there is no encoder to keep in
/// sync with the key mapping below.
public struct GeminiConfig: Decodable, Sendable, Equatable {
    public var appURL: String
    public var generateURL: String
    public var batchexecuteURL: String
    public var rotateCookiesURL: String

    public var rpcStatus: String
    public var rpcUsage: String
    public var rpcQuota: String

    /// Names of the `WIZ_global_data` fields carrying session parameters.
    public var wizAt: String
    public var wizBuild: String
    public var wizSession: String
    public var wizLang: String

    public var models: [GeminiModel]
    public var defaultModel: String
    public var promptVersion: Int

    /// Optional overrides for the headers that select the model. These are the
    /// parameters most likely to be reworked when the web client changes, they
    /// fail with `1052` when wrong, and a wrong value must be fixable by editing
    /// this file on the device rather than by rebuilding the app.
    ///
    /// Placeholders: `{model}`, `{capacity}`, `{number}`, `{session}`.
    ///   * `modelHeader`      — `x-goog-ext-525001261-jspb` for generation
    ///   * `batchModelHeader` — the same header for batchexecute RPCs
    ///   * `sessionHeader`    — `x-goog-ext-525005358-jspb`; an empty string
    ///                          omits the header entirely
    public var modelHeaderTemplate: String?
    public var batchModelHeaderTemplate: String?
    public var sessionHeaderTemplate: String?

    private enum CodingKeys: String, CodingKey {
        case appURL = "init"
        case generateURL = "generate"
        case batchexecuteURL = "batchexecute"
        case rotateCookiesURL = "rotateCookies"
        case rpc, wizKeys, models, defaultModel, prompts
        case modelHeaderTemplate = "modelHeader"
        case batchModelHeaderTemplate = "batchModelHeader"
        case sessionHeaderTemplate = "sessionHeader"
    }

    private enum RPCKeys: String, CodingKey { case status, usage, quota }
    private enum WizKeys: String, CodingKey { case at, build, session, lang }
    private enum PromptKeys: String, CodingKey { case version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appURL = try c.decode(String.self, forKey: .appURL)
        generateURL = try c.decode(String.self, forKey: .generateURL)
        batchexecuteURL = try c.decode(String.self, forKey: .batchexecuteURL)
        rotateCookiesURL = try c.decode(String.self, forKey: .rotateCookiesURL)

        let rpc = try c.nestedContainer(keyedBy: RPCKeys.self, forKey: .rpc)
        rpcStatus = try rpc.decode(String.self, forKey: .status)
        rpcUsage = try rpc.decode(String.self, forKey: .usage)
        rpcQuota = try rpc.decode(String.self, forKey: .quota)

        let wiz = try c.nestedContainer(keyedBy: WizKeys.self, forKey: .wizKeys)
        wizAt = try wiz.decodeIfPresent(String.self, forKey: .at) ?? "SNlM0e"
        wizBuild = try wiz.decodeIfPresent(String.self, forKey: .build) ?? "cfb2h"
        wizSession = try wiz.decodeIfPresent(String.self, forKey: .session) ?? "FdrFJe"
        wizLang = try wiz.decodeIfPresent(String.self, forKey: .lang) ?? "TuX5cc"

        modelHeaderTemplate = try c.decodeIfPresent(String.self, forKey: .modelHeaderTemplate)
        batchModelHeaderTemplate = try c.decodeIfPresent(String.self, forKey: .batchModelHeaderTemplate)
        sessionHeaderTemplate = try c.decodeIfPresent(String.self, forKey: .sessionHeaderTemplate)

        models = try c.decodeIfPresent([GeminiModel].self, forKey: .models) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? models.first?.id ?? ""
        if let prompts = try? c.nestedContainer(keyedBy: PromptKeys.self, forKey: .prompts) {
            promptVersion = (try? prompts.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        } else {
            promptVersion = 1
        }
    }

    public init(
        appURL: String, generateURL: String, batchexecuteURL: String, rotateCookiesURL: String,
        rpcStatus: String, rpcUsage: String, rpcQuota: String,
        wizAt: String = "SNlM0e", wizBuild: String = "cfb2h",
        wizSession: String = "FdrFJe", wizLang: String = "TuX5cc",
        models: [GeminiModel], defaultModel: String, promptVersion: Int = 1,
        modelHeaderTemplate: String? = nil, batchModelHeaderTemplate: String? = nil,
        sessionHeaderTemplate: String? = nil
    ) {
        self.appURL = appURL
        self.generateURL = generateURL
        self.batchexecuteURL = batchexecuteURL
        self.rotateCookiesURL = rotateCookiesURL
        self.rpcStatus = rpcStatus
        self.rpcUsage = rpcUsage
        self.rpcQuota = rpcQuota
        self.wizAt = wizAt
        self.wizBuild = wizBuild
        self.wizSession = wizSession
        self.wizLang = wizLang
        self.models = models
        self.defaultModel = defaultModel
        self.promptVersion = promptVersion
        self.modelHeaderTemplate = modelHeaderTemplate
        self.batchModelHeaderTemplate = batchModelHeaderTemplate
        self.sessionHeaderTemplate = sessionHeaderTemplate
    }

    public func model(id: String?) -> GeminiModel? {
        guard let id else { return models.first { $0.id == defaultModel } ?? models.first }
        return models.first { $0.id == id } ?? models.first { $0.id == defaultModel } ?? models.first
    }

    /// Host used for the "only gemini.google.com/accounts.google.com" guarantee.
    public var allowedHosts: [String] { ["gemini.google.com", "accounts.google.com"] }
}

// MARK: - Loading

/// The configuration used when the bundled resource cannot be read. It is a
/// literal copy of `Resources/gemini-web.json`; `GeminiProtocolTests` asserts the
/// two are equal so they cannot drift apart.
public extension GeminiConfig {
    static let lastResort = GeminiConfig(
        appURL: "https://gemini.google.com/app",
        generateURL: "https://gemini.google.com"
            + "/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate",
        batchexecuteURL: "https://gemini.google.com/_/BardChatUi/data/batchexecute",
        rotateCookiesURL: "https://accounts.google.com/RotateCookies",
        rpcStatus: "otAQ7b", rpcUsage: "jSf9Qc", rpcQuota: "qpEbW",
        models: [
            GeminiModel(id: "56fdd199312815e2", label: "Flash (подписка)", capacity: 4, number: 1),
            GeminiModel(id: "e6fa609c3fa255c0", label: "Pro (подписка)", capacity: 4, number: 3),
            GeminiModel(id: "8c46e95b1a07cecc", label: "Flash Lite (подписка)", capacity: 4, number: 6),
            GeminiModel(id: "fbb127bbb056c959", label: "Flash (free)", capacity: 1, number: 1),
        ],
        defaultModel: "56fdd199312815e2")
}

public enum GeminiConfigLoader {
    /// Bundled defaults shipped inside the package.
    public static func bundled() -> GeminiConfig? {
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(forResource: "gemini-web", withExtension: "json"),
              let data = FileStore.readData(url)
        else { return nil }
        return try? JSONCoders.decode(GeminiConfig.self, from: data)
        #else
        return nil
        #endif
    }

    /// A user-supplied override wins over the bundled defaults. A malformed
    /// override is ignored and logged rather than taking translation down.
    public static func resolve(override data: Data?) -> GeminiConfig? {
        if let data {
            do {
                return try JSONCoders.decode(GeminiConfig.self, from: data)
            } catch {
                CoreLog.warn("gemini-web.json override is invalid, using bundled defaults: \(error)")
            }
        }
        return bundled()
    }

    /// A copy of the bundled defaults, for writing an editable starting point
    /// into `Documents/Config/`.
    public static func bundledJSONData() -> Data? {
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(forResource: "gemini-web", withExtension: "json") else { return nil }
        return FileStore.readData(url)
        #else
        return nil
        #endif
    }
}

// MARK: - Session parameters

/// `window.WIZ_global_data` values scraped from the Gemini app page.
public struct WizParameters: Codable, Sendable, Equatable {
    /// `SNlM0e` — the anti-CSRF token; its absence means "not signed in".
    public var at: String
    /// `cfb2h` — client build label.
    public var bl: String
    /// `FdrFJe` — session id.
    public var sessionId: String
    /// `TuX5cc` — UI language.
    public var language: String

    public init(at: String, bl: String, sessionId: String, language: String = "ru") {
        self.at = at
        self.bl = bl
        self.sessionId = sessionId
        self.language = language
    }

    public var isSignedIn: Bool { !at.isEmpty }

    public var maskedDescription: String {
        "at=\(WizParameters.mask(at)) bl=\(bl) f.sid=\(sessionId) hl=\(language)"
    }

    /// Shows just enough of a secret to tell two values apart.
    public static func mask(_ value: String) -> String {
        guard value.count > 6 else { return value.isEmpty ? "(пусто)" : "…" }
        return "\(value.prefix(3))…\(value.suffix(3))(\(value.count))"
    }
}

/// `_reqid` starts at a random five-digit value and grows by 100000 per request.
public struct ReqidGenerator: Sendable {
    private var current: Int

    public init(start: Int? = nil) {
        self.current = start ?? Int.random(in: 10000...99999)
    }

    /// Value for the next request; the counter is advanced by 100000.
    public mutating func next() -> Int {
        let value = current
        current += 100000
        return value
    }
}

// MARK: - Protocol constants

public enum GeminiProtocol {
    public static let formContentType = "application/x-www-form-urlencoded;charset=utf-8"
    public static let origin = "https://gemini.google.com"
    public static let referer = "https://gemini.google.com/"
    public static let sameDomain = "1"
    /// Streaming request timeout, seconds.
    public static let requestTimeout: TimeInterval = 180
    /// Payload array length is fixed at 81 by the web client.
    public static let payloadLength = 81
    public static let streamGeneratePath = "/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate"
    public static let batchexecutePath = "/_/BardChatUi/data/batchexecute"
    public static let rotateCookiesPath = "/RotateCookies"

    /// Header carrying the model selection, capacity and session id.
    public static let modelHeaderName = "x-goog-ext-525001261-jspb"
    public static let sessionHeaderName = "x-goog-ext-525005358-jspb"
    public static let extraHeaderName89 = "x-goog-ext-73010989-jspb"
    public static let extraHeaderName90 = "x-goog-ext-73010990-jspb"

    /// The model-selection header from docs/SPEC.md §7.2. Its length is part of
    /// the protocol: the reference implementation sends a 15-element form without
    /// the trailing `1,"<session>"`, so that variant is the first thing to try if
    /// the backend answers `1052`.
    public static let defaultModelHeaderTemplate =
        "[1,null,null,null,\"{model}\",null,null,0,[4,5,6,8],null,null,{capacity},null,null,{number},1,\"{session}\"]"

    /// The same header for batchexecute: no model id, only the flag set and the
    /// session.
    public static let defaultBatchModelHeaderTemplate =
        "[1,null,null,null,null,null,null,null,[4,5,6,8],null,null,null,null,null,null,null,\"{session}\"]"

    /// `x-goog-ext-525005358-jspb`. The reference implementation does not send it
    /// at all, so an empty override is a supported configuration.
    public static let defaultSessionHeaderTemplate = "[\"{session}\",1]"
}

// MARK: - Request building

public enum GeminiRequestBuilder {
    // MARK: Header templates

    /// Fills `{model}`, `{capacity}`, `{number}` and `{session}` in a template.
    static func substitute(
        _ template: String, model: GeminiModel?, sessionUUID: String
    ) -> String {
        var out = template.replacingOccurrences(of: "{session}", with: sessionUUID)
        if let model {
            out = out.replacingOccurrences(of: "{model}", with: model.id)
            out = out.replacingOccurrences(of: "{capacity}", with: String(model.capacity))
            out = out.replacingOccurrences(of: "{number}", with: String(model.number))
        }
        return out
    }

    /// Renders an override, falling back to the built-in template when the result
    /// is not valid JSON. A broken override is a configuration mistake, not a
    /// reason to stop translating.
    static func render(
        template: String?, fallback: String, model: GeminiModel?, sessionUUID: String,
        label: String
    ) -> String {
        guard let template else {
            return substitute(fallback, model: model, sessionUUID: sessionUUID)
        }
        let rendered = substitute(template, model: model, sessionUUID: sessionUUID)
        guard JSONPayload.parse(rendered) != nil else {
            CoreLog.warn("\(label): override is not valid JSON, using the built-in header")
            return substitute(fallback, model: model, sessionUUID: sessionUUID)
        }
        return rendered
    }

    public static func modelHeader(config: GeminiConfig, model: GeminiModel, sessionUUID: String) -> String {
        render(template: config.modelHeaderTemplate,
               fallback: GeminiProtocol.defaultModelHeaderTemplate,
               model: model, sessionUUID: sessionUUID, label: "modelHeader")
    }

    static func batchModelHeader(config: GeminiConfig, sessionUUID: String) -> String {
        render(template: config.batchModelHeaderTemplate,
               fallback: GeminiProtocol.defaultBatchModelHeaderTemplate,
               model: nil, sessionUUID: sessionUUID, label: "batchModelHeader")
    }

    /// Nil means "do not send the header": either the override is empty, or the
    /// built-in template was overridden to nothing.
    public static func sessionHeader(config: GeminiConfig, sessionUUID: String) -> String? {
        let template = config.sessionHeaderTemplate ?? GeminiProtocol.defaultSessionHeaderTemplate
        guard !template.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let rendered = substitute(template, model: nil, sessionUUID: sessionUUID)
        guard JSONPayload.parse(rendered) != nil else {
            CoreLog.warn("sessionHeader: override is not valid JSON, using the built-in header")
            return substitute(GeminiProtocol.defaultSessionHeaderTemplate,
                              model: nil, sessionUUID: sessionUUID)
        }
        return rendered
    }

    // MARK: Generate

    /// The 81-element positional array posted as `f.req`.
    public static func generatePayload(prompt: String, model: GeminiModel, sessionUUID: String) -> [JSONValue] {
        var inner = [JSONValue](repeating: .null, count: GeminiProtocol.payloadLength)
        inner[0] = .array([.string(prompt), .int(0), .null, .null, .null, .null, .int(0)])
        inner[1] = .array([.string("ru")])
        inner[2] = .array([.string(""), .string(""), .string(""),
                           .null, .null, .null, .null, .null, .null, .string("")])
        inner[6] = .array([.int(1)])
        inner[7] = .int(1)                                   // streaming
        inner[10] = .int(1)
        inner[11] = .int(0)
        inner[17] = .array([.array([.int(0)])])
        inner[18] = .int(0)
        inner[27] = .int(1)
        inner[30] = .array([.int(4)])
        inner[41] = .array([.int(1)])
        inner[53] = .int(0)
        inner[59] = .string(sessionUUID)
        inner[61] = .array([])
        inner[68] = .int(1)
        inner[79] = .int(model.number)
        inner[80] = .int(1)                                  // no extended thinking
        return inner
    }

    /// `f.req` for a fresh single-turn conversation.
    public static func generateFReq(prompt: String, model: GeminiModel, sessionUUID: String) -> String {
        let inner = generatePayload(prompt: prompt, model: model, sessionUUID: sessionUUID)
        let outer = JSONValue.array([.null, .string(JSONValue.array(inner).jsonText)])
        return outer.jsonText
    }

    public static func generateBody(at: String, fReq: String) -> String {
        "at=\(formEncode(at))&f.req=\(formEncode(fReq))"
    }

    public static func generateURL(
        config: GeminiConfig, bl: String, sessionId: String, reqid: Int
    ) -> String {
        var components = URLComponents(string: config.generateURL)!
        components.queryItems = [
            URLQueryItem(name: "hl", value: "ru"),
            URLQueryItem(name: "_reqid", value: String(reqid)),
            URLQueryItem(name: "rt", value: "c"),
            URLQueryItem(name: "bl", value: bl),
            URLQueryItem(name: "f.sid", value: sessionId),
        ]
        return components.url!.absoluteString
    }

    public static func generateHeaders(
        config: GeminiConfig, model: GeminiModel, sessionUUID: String
    ) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": GeminiProtocol.formContentType,
            "Origin": GeminiProtocol.origin,
            "Referer": GeminiProtocol.referer,
            "X-Same-Domain": GeminiProtocol.sameDomain,
            GeminiProtocol.modelHeaderName: modelHeader(
                config: config, model: model, sessionUUID: sessionUUID),
            GeminiProtocol.extraHeaderName89: "[0]",
            GeminiProtocol.extraHeaderName90: "[0,0,0]",
        ]
        if let session = sessionHeader(config: config, sessionUUID: sessionUUID) {
            headers[GeminiProtocol.sessionHeaderName] = session
        }
        return headers
    }

    // MARK: batchexecute

    /// `source-path` selects which backend the RPC runs against.
    public enum SourcePath: String, Sendable {
        case app = "/app"
        case usage = "/usage"
    }

    public static func batchExecFReq(rpcId: String, payload: String) -> String {
        let envelope = JSONValue.array([
            .array([.array([.string(rpcId), .string(payload), .null, .string("generic")])])
        ])
        return envelope.jsonText
    }

    public static func batchExecBody(at: String, fReq: String) -> String {
        "at=\(formEncode(at))&f.req=\(formEncode(fReq))"
    }

    public static func batchExecURL(
        config: GeminiConfig, rpcId: String, sourcePath: SourcePath,
        bl: String, sessionId: String, reqid: Int
    ) -> String {
        var components = URLComponents(string: config.batchexecuteURL)!
        components.queryItems = [
            URLQueryItem(name: "rpcids", value: rpcId),
            URLQueryItem(name: "source-path", value: sourcePath.rawValue),
            URLQueryItem(name: "hl", value: "ru"),
            URLQueryItem(name: "_reqid", value: String(reqid)),
            URLQueryItem(name: "rt", value: "c"),
            URLQueryItem(name: "bl", value: bl),
            URLQueryItem(name: "f.sid", value: sessionId),
        ]
        return components.url!.absoluteString
    }

    public static func batchExecHeaders(config: GeminiConfig, sessionUUID: String) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": GeminiProtocol.formContentType,
            "Origin": GeminiProtocol.origin,
            "Referer": GeminiProtocol.referer,
            "X-Same-Domain": GeminiProtocol.sameDomain,
            GeminiProtocol.modelHeaderName: batchModelHeader(config: config, sessionUUID: sessionUUID),
            GeminiProtocol.extraHeaderName89: "[0]",
            GeminiProtocol.extraHeaderName90: "[0,0,0]",
        ]
        if let session = sessionHeader(config: config, sessionUUID: sessionUUID) {
            headers[GeminiProtocol.sessionHeaderName] = session
        }
        return headers
    }

    /// Payload literals for the quota RPC.
    public enum QuotaPayload {
        public static let flash = "[[[1,11],[2,11],[6,11]]]"
        public static let pro = "[[[1,4],[6,6],[1,15]]]"
        public static let empty = "[]"
    }

    // MARK: Encoding helpers

    /// `application/x-www-form-urlencoded` byte serializer: unreserved
    /// characters are `A-Za-z0-9*-._`, space becomes `+`, everything else is
    /// percent-encoded with uppercase hex. This matches `URLSearchParams`.
    public static func formEncode(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2A, 0x2D, 0x2E, 0x5F:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out.append("%")
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    /// Session id used in the model and session headers and in payload index 59.
    public static func newSessionUUID() -> String {
        UUID().uuidString.uppercased()
    }

    /// `[000,"-0000000000000000000"]`, the body the web client posts to
    /// `RotateCookies` so WebKit refreshes `__Secure-1PSIDTS`.
    public static let rotateCookiesBody = "[000,\"-0000000000000000000\"]"

    public static func rotateCookiesHeaders() -> [String: String] {
        ["Content-Type": "application/json", "Origin": "https://accounts.google.com"]
    }
}
