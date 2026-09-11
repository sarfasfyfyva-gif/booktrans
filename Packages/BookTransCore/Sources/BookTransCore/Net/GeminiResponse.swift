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
    /// The exact shape of `body[15]` is not documented by any capture we have,
    /// so this scans for the stable parts — a 16-hex-character id and a nearby
    /// human label — and inherits `capacity`/`number` from the matching preset
    /// because those two fields are positional and cannot be guessed. Anything
    /// the scan cannot resolve is left for the manual override in Settings.
    static func modelList(from value: JSONValue, presets: [GeminiModel]) -> [GeminiModel] {
        var models: [GeminiModel] = []
        var seen = Set<String>()

        func visit(_ node: JSONValue) {
            guard let entries = node.arrayValue else { return }
            for entry in entries {
                guard let fields = entry.arrayValue else { continue }
                var id: String?
                var label: String?
                var capacity: Int?
                var number: Int?
                for field in fields {
                    switch field {
                    case .string(let text):
                        if id == nil, isModelId(text) {
                            id = text
                        } else if label == nil, isPlausibleLabel(text) {
                            label = text
                        }
                    case .int(let numberValue):
                        // Positional guesses, replaced by preset values below.
                        if capacity == nil, numberValue > 0, numberValue <= 64 {
                            capacity = numberValue
                        } else if number == nil, numberValue > 0, numberValue <= 64 {
                            number = numberValue
                        }
                    case .array(let nested):
                        if id == nil, let found = firstModelId(in: nested) { id = found }
                    case .null, .bool:
                        break
                    }
                }
                if let id, !seen.contains(id) {
                    seen.insert(id)
                    let preset = presets.first { $0.id == id }
                    models.append(GeminiModel(
                        id: id,
                        label: label ?? preset?.label ?? id,
                        capacity: preset?.capacity ?? capacity ?? 12,
                        number: preset?.number ?? number ?? 1))
                } else if id == nil {
                    // Grouping arrays: recurse one level.
                    for field in fields where field.arrayValue != nil {
                        visit(field)
                    }
                }
            }
        }

        func firstModelId(in values: [JSONValue]) -> String? {
            for field in values {
                if case .string(let text) = field, isModelId(text) { return text }
                if let nested = field.arrayValue, let found = firstModelId(in: nested) { return found }
            }
            return nil
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

    private static func collectNumbers(_ value: JSONValue, fractions: inout [Double], ratios: inout [Double]) {
        switch value {
        case .int(let number):
            let asDouble = Double(number)
            if asDouble > 0, asDouble <= 1 {
                fractions.append(asDouble)
            } else if asDouble > 1, asDouble <= 100 {
                ratios.append(asDouble)
            }
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
