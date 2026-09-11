import Foundation

/// A single part of a `batchexecute` / `StreamGenerate` frame.
public struct GeminiPart: Sendable {
    /// `part[1]` — the RPC id this part answers.
    public var rpcId: String
    /// `part[2]` — the payload, itself a JSON document encoded as a string.
    public var payloadText: String?
    /// `part[5][0] == 7` means the request was rejected for lack of auth.
    public var rejected: Bool
    /// `part[5][2][0][1][0]` when the backend reported a failure.
    public var errorCode: Int?
    public var raw: JSONValue
}

/// One length-prefixed frame of a chunked response.
public struct GeminiFrame: Sendable {
    public var parts: [GeminiPart]
    public var payloadJSON: String
}

/// Failure classification shared by all endpoints.
public struct GeminiError: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 1037 — subscription usage limit reached.
        case usageLimit
        /// 1060 — IP/region blocked.
        case ipRegion
        /// 1013 — transient backend error.
        case temporary
        /// 1050 — model does not match the conversation.
        case modelMismatch
        /// 1052 — bad model header.
        case badModelHeader
        /// Reject code 7, or HTTP 401/403.
        case unauthenticated
        /// No connection at all: offline, VPN off, timeout. Not the protocol's
        /// fault, so it must not consume the retry budget.
        case unavailable
        case unknown
    }

    public var kind: Kind
    public var code: Int?
    public var message: String

    public init(kind: Kind, code: Int? = nil, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    public static func forCode(_ code: Int) -> GeminiError {
        switch code {
        case 1013:
            return GeminiError(kind: .temporary, code: code,
                               message: "Gemini временно недоступен (1013). Повторим автоматически.")
        case 1037:
            return GeminiError(kind: .usageLimit, code: code,
                               message: "Лимит Gemini исчерпан, продолжаем автоматически.")
        case 1050:
            return GeminiError(kind: .modelMismatch, code: code,
                               message: "Выбранная модель не подходит к этому запросу (1050). Смените модель в настройках.")
        case 1052:
            return GeminiError(kind: .badModelHeader, code: code,
                               message: "Неверный model header (1052). Обновите gemini-web.json.")
        case 1060:
            return GeminiError(kind: .ipRegion, code: code,
                               message: "Gemini недоступен: включите VPN (1060).")
        default:
            return GeminiError(kind: .unknown, code: code,
                               message: "Ошибка Gemini: код \(code).")
        }
    }

    public static let unauthenticated = GeminiError(
        kind: .unauthenticated, message: "Нужно войти в Gemini.")

    public static let unavailable = GeminiError(
        kind: .unavailable, message: "Нет связи с Gemini. Проверьте интернет и VPN.")

    public var isRetryableImmediately: Bool {
        kind == .temporary || kind == .unknown
    }
}

// MARK: - Frame parsing

public enum GeminiResponseParser {
    /// Strips the `)]}'` anti-hijacking prefix the backend prepends.
    public static func stripPrefix(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: ")]}'") , range.lowerBound == text.startIndex {
            text = String(text[range.upperBound...])
        }
        while let first = text.first, first == "\n" || first == "\r" {
            text.removeFirst()
        }
        return text
    }

    /// Splits a chunked body into frames.
    ///
    /// Each frame is `<length>\n<json>\n` where `length` counts **UTF-16 code
    /// units** (JavaScript's `String.length`), not characters and not bytes.
    /// `String.utf16.count` gives the same number, so this is exact even when
    /// the payload contains surrogate pairs.
    public static func parseFrames(_ raw: String) -> [GeminiFrame] {
        let text = stripPrefix(raw)
        var frames: [GeminiFrame] = []
        var index = text.startIndex

        while index < text.endIndex {
            // Skip separators between frames.
            while index < text.endIndex, text[index] == "\n" || text[index] == "\r" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            // Length prefix.
            var digits = ""
            while index < text.endIndex, text[index].isNumber {
                digits.append(text[index])
                index = text.index(after: index)
            }
            guard !digits.isEmpty, let length = Int(digits) else { break }
            // A frame is separated from its length by exactly one newline.
            guard index < text.endIndex, text[index] == "\n" else { break }
            index = text.index(after: index)

            // Consume exactly `length` UTF-16 code units.
            var remaining = length
            let start = index
            while remaining > 0, index < text.endIndex {
                let character = text[index]
                remaining -= character.utf16.count
                index = text.index(after: index)
            }
            let payload = String(text[start..<index])
            if let frame = parseFrame(payload) {
                frames.append(frame)
            }
        }
        return frames
    }

    static func parseFrame(_ payload: String) -> GeminiFrame? {
        guard let root = JSONPayload.parse(payload), let entries = root.arrayValue else { return nil }
        var parts: [GeminiPart] = []
        for entry in entries {
            // A frame may also contain bare `[rpcid, payload]` tuples; only
            // array entries carrying a string id are parts we understand.
            guard let fields = entry.arrayValue, fields.count > 1 else { continue }
            guard let rpcId = fields[1].stringValue else { continue }

            var rejected = false
            var errorCode: Int?
            if let meta = fields.count > 5 ? fields[5].arrayValue : nil {
                if meta.first?.intValue == 7 { rejected = true }
                if let detail = meta.count > 2 ? meta[2].arrayValue : nil,
                   let first = detail.first?.arrayValue,
                   let retry = first.count > 1 ? first[1].arrayValue : nil,
                   let code = retry.first?.intValue {
                    errorCode = code
                }
            }
            parts.append(GeminiPart(
                rpcId: rpcId,
                payloadText: fields.count > 2 ? fields[2].stringValue : nil,
                rejected: rejected,
                errorCode: errorCode,
                raw: entry))
        }
        guard !parts.isEmpty else { return nil }
        return GeminiFrame(parts: parts, payloadJSON: payload)
    }

    /// Payload of the first part answering `rpcId`, preferring frames with an
    /// actual payload over error frames.
    public static func payload(
        for rpcId: String, in frames: [GeminiFrame]
    ) -> (value: JSONValue, error: GeminiError?)? {
        var failure: GeminiError?
        for frame in frames {
            for part in frame.parts where part.rpcId == rpcId {
                if part.rejected {
                    failure = failure ?? .unauthenticated
                    continue
                }
                if let code = part.errorCode {
                    failure = failure ?? GeminiError.forCode(code)
                    continue
                }
                guard let text = part.payloadText, let value = JSONPayload.parse(text) else { continue }
                return (value, nil)
            }
        }
        if let failure { return (JSONValue.null, failure) }
        return nil
    }

    /// HTTP-level classification, used before looking at the body.
    public static func error(forHTTPStatus status: Int) -> GeminiError? {
        switch status {
        // The transport reports 0 when the page could not reach the server at
        // all; that is connectivity, not a protocol answer.
        case 0: return .unavailable
        case 200...299: return nil
        case 401, 403: return .unauthenticated
        case 429: return GeminiError(kind: .usageLimit, code: 429,
                                     message: "Слишком много запросов. Повторим автоматически.")
        case 500...599: return GeminiError(kind: .temporary, code: status,
                                           message: "Сервер Gemini недоступен (\(status)). Повторим автоматически.")
        default: return GeminiError(kind: .unknown, code: status,
                                    message: "Неожиданный ответ Gemini (\(status)).")
        }
    }
}

// MARK: - StreamGenerate

public struct StreamGenerateResponse: Sendable {
    public var text: String?
    public var conversationId: String?
    public var responseId: String?
    /// The answer carried extended-thinking output, which we discard.
    public var hadReasoning: Bool
    public var error: GeminiError?
    public var frameCount: Int

    public init(text: String?, conversationId: String? = nil, responseId: String? = nil,
                hadReasoning: Bool = false, error: GeminiError? = nil, frameCount: Int = 0) {
        self.text = text
        self.conversationId = conversationId
        self.responseId = responseId
        self.hadReasoning = hadReasoning
        self.error = error
        self.frameCount = frameCount
    }
}

public extension GeminiResponseParser {
    /// The answer text is the last candidate of the last frame that produced
    /// one, per the streaming protocol.
    static func parseStreamGenerate(_ raw: String) -> StreamGenerateResponse {
        let frames = parseFrames(raw)
        var text: String?
        var conversationId: String?
        var responseId: String?
        var hadReasoning = false
        var failure: GeminiError?

        for frame in frames {
            for part in frame.parts {
                if part.rejected {
                    failure = failure ?? .unauthenticated
                    continue
                }
                if let code = part.errorCode {
                    failure = failure ?? GeminiError.forCode(code)
                    continue
                }
                guard let payloadText = part.payloadText,
                      let body = JSONPayload.parse(payloadText)
                else { continue }

                if let pair = body[1]?.arrayValue {
                    if let cid = pair.first?.stringValue { conversationId = cid }
                    if pair.count > 1, let rid = pair[1].stringValue { responseId = rid }
                }
                guard let candidates = body[4]?.arrayValue, let candidate = candidates.last else { continue }
                if let reasonings = candidate[37]?.arrayValue, !reasonings.isEmpty {
                    hadReasoning = true
                }
                if let value = candidate[1]?[0]?.stringValue, !value.isEmpty {
                    text = value
                }
            }
        }
        return StreamGenerateResponse(
            text: text, conversationId: conversationId, responseId: responseId,
            hadReasoning: hadReasoning, error: text == nil ? (failure ?? nil) : nil,
            frameCount: frames.count)
    }
}

// MARK: - Account status (otAQ7b)

public struct GeminiAccountStatus: Sendable {
    /// `body[14]`: 1000 ok, 1016 not signed in, 1060 region blocked.
    public var statusCode: Int?
    public var models: [GeminiModel]
    public var tierRaw: Int?
    /// Kept verbatim so the debug screen can show what the backend really sent.
    public var raw: JSONValue

    public var isSignedIn: Bool { statusCode.map { $0 != 1016 } ?? true }

    public var error: GeminiError? {
        switch statusCode {
        case 1000: return nil
        case 1016: return .unauthenticated
        case 1060: return GeminiError.forCode(1060)
        case .some(let code): return GeminiError.forCode(code)
        case nil: return nil
        }
    }
}

public extension GeminiResponseParser {
    static func parseAccountStatus(_ value: JSONValue, presets: [GeminiModel] = []) -> GeminiAccountStatus {
        let statusCode = value[14]?.intValue
        let tier = value[16]?.intValue ?? value[17]?.intValue
        let models = modelList(from: value[15] ?? .null, presets: presets)
        return GeminiAccountStatus(statusCode: statusCode, models: models, tierRaw: tier, raw: value)
    }

    /// Best-effort extraction of the model list.
    ///
    /// The exact shape of `body[15]` is not documented by any capture we have, so
    /// this walks the tree and treats any array that contains a 16-hex-character
    /// id as one model entry. `capacity` and `number` are positional and cannot
    /// be guessed, so they come from the matching preset; the label from the RPC
    /// wins because it is what the account actually calls the model.
    static func modelList(from value: JSONValue, presets: [GeminiModel]) -> [GeminiModel] {
        var models: [GeminiModel] = []
        var seen = Set<String>()

        func visit(_ node: JSONValue) {
            guard let entries = node.arrayValue else { return }

            let strings = entries.compactMap { $0.stringValue }
            if let id = strings.first(where: isModelId) {
                guard seen.insert(id).inserted else { return }
                let label = strings.first { $0 != id && isPlausibleLabel($0) }
                let ints = entries.compactMap { entry -> Int? in
                    guard case .int(let number) = entry, (1...64).contains(number) else { return nil }
                    return number
                }
                let preset = presets.first { $0.id == id }
                models.append(GeminiModel(
                    id: id,
                    label: label ?? preset?.label ?? id,
                    capacity: preset?.capacity ?? ints.first ?? 12,
                    number: preset?.number ?? (ints.count > 1 ? ints[1] : ints.first ?? 1)))
                return
            }

            for entry in entries { visit(entry) }
        }

        visit(value)
        return models
    }

    /// Model ids are 16 lowercase hex characters, e.g. `56fdd199312815e2`.
    static func isModelId(_ text: String) -> Bool {
        text.count == 16 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isPlausibleLabel(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 40 else { return false }
        return text.contains { $0.isLetter } && !isModelId(text)
    }
}

// MARK: - Usage / quota (jSf9Qc)

public struct GeminiUsageWindow: Sendable, Equatable {
    /// Fraction of the window already consumed, 0...1.
    public var usedFraction: Double
    public var subtitle: String

    public init(usedFraction: Double, subtitle: String = "") {
        self.usedFraction = usedFraction
        self.subtitle = subtitle
    }
}

public struct GeminiUsage: Sendable {
    public enum Tier: Int, Sendable {
        case free = 1
        case pro = 2
        case ultra = 3
        case plus = 4

        public var label: String {
            switch self {
            case .free: return "Free"
            case .pro: return "Pro"
            case .ultra: return "Ultra"
            case .plus: return "Plus"
            }
        }
    }

    public var tier: Tier?
    /// Short rolling window (about five hours).
    public var shortWindow: GeminiUsageWindow?
    /// Long rolling window (about a week).
    public var longWindow: GeminiUsageWindow?
    public var raw: JSONValue

    public var tierLabel: String { tier?.label ?? "неизвестно" }
}

public extension GeminiResponseParser {
    static func parseUsage(_ value: JSONValue) -> GeminiUsage {
        var fractions: [Double] = []
        var ratios: [Double] = []
        collectNumbers(value, fractions: &fractions, ratios: &ratios)

        let tierCode = firstTierCode(in: value)
        let windows = fractions.sorted(by: >)
        return GeminiUsage(
            tier: tierCode.flatMap(GeminiUsage.Tier.init(rawValue:)),
            shortWindow: windows.count > 1 ? GeminiUsageWindow(usedFraction: windows[1]) : windows.first.map { GeminiUsageWindow(usedFraction: $0) },
            longWindow: windows.first.map { GeminiUsageWindow(usedFraction: $0) },
            raw: value)
    }

    private static func collect(asDouble: Double, fractions: inout [Double], ratios: inout [Double]) {
        if asDouble > 0, asDouble <= 1 {
            fractions.append(asDouble)
        } else if asDouble > 1, asDouble <= 100 {
            ratios.append(asDouble)
        }
    }

    private static func collectNumbers(_ value: JSONValue, fractions: inout [Double], ratios: inout [Double]) {
        switch value {
        case .int(let number):
            collect(asDouble: Double(number), fractions: &fractions, ratios: &ratios)
        case .double(let number):
            collect(asDouble: number, fractions: &fractions, ratios: &ratios)
        case .array(let values):
            for child in values { collectNumbers(child, fractions: &fractions, ratios: &ratios) }
        default:
            break
        }
    }

    /// The tier code sits in a small integer range; take the first value that
    /// maps onto a known tier.
    private static func firstTierCode(in value: JSONValue) -> Int? {
        if let found = JSONPayload.firstInt(in: value, matching: { (1...4).contains($0) }) {
            return found
        }
        return nil
    }
}
