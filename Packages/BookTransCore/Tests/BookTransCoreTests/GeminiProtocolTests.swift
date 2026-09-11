import XCTest
@testable import BookTransCore

/// The Gemini web protocol is the one part of the app that cannot be debugged on
/// a device without burning account limits, so every literal from docs/SPEC.md
/// §7 and every frame shape from §7.4 is pinned here.
final class GeminiProtocolTests: XCTestCase {
    private let model = GeminiModel(id: "56fdd199312815e2", label: "Flash", capacity: 4, number: 1)
    private let sessionUUID = GeminiRequestBuilder.newSessionUUID()

    private func decode(_ text: String) throws -> JSONValue {
        try JSONValue.decode(from: Data(text.utf8))
    }

    // MARK: - Session ids and request ids

    func testSessionUUIDIsUppercase() {
        XCTAssertEqual(sessionUUID, sessionUUID.uppercased())
        XCTAssertEqual(sessionUUID.count, 36)
        XCTAssertNotEqual(GeminiRequestBuilder.newSessionUUID(), sessionUUID)
    }

    func testReqidStartsAtTheFirstValueAndStepsByOneHundredThousand() {
        var generator = ReqidGenerator(start: 12345)
        XCTAssertEqual(generator.next(), 12345, "the current value is used, then advanced")
        XCTAssertEqual(generator.next(), 112345)
        XCTAssertEqual(generator.next(), 212345)
    }

    func testRandomReqidIsFiveDigits() {
        for _ in 0..<200 {
            var generator = ReqidGenerator()
            let value = generator.next()
            XCTAssertTrue((10000...99999).contains(value), "\(value)")
        }
    }

    // MARK: - Form encoding

    func testFormEncodingMatchesURLSearchParams() {
        // Unreserved set per the urlencoded byte serializer.
        XCTAssertEqual(GeminiRequestBuilder.formEncode("aZ09*-._"), "aZ09*-._")
        XCTAssertEqual(GeminiRequestBuilder.formEncode("a b"), "a+b", "space becomes plus")
        XCTAssertEqual(GeminiRequestBuilder.formEncode("100%"), "100%25")
        XCTAssertEqual(GeminiRequestBuilder.formEncode("a&b=c"), "a%26b%3Dc")
        XCTAssertEqual(GeminiRequestBuilder.formEncode("\"quoted\""), "%22quoted%22")
        XCTAssertEqual(GeminiRequestBuilder.formEncode("Привет"), "%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82")
        XCTAssertEqual(GeminiRequestBuilder.formEncode("[1,2]"), "%5B1%2C2%5D")
    }

    // MARK: - Generate payload

    func testPayloadHasExactlyEightyOnePositionalElements() throws {
        let payload = GeminiRequestBuilder.generatePayload(
            prompt: "Hello", model: model, sessionUUID: sessionUUID)
        XCTAssertEqual(payload.count, 81)

        // Every documented index from §7.2.
        XCTAssertEqual(payload[0], .array([.string("Hello"), .int(0), .null, .null, .null, .null, .int(0)]))
        XCTAssertEqual(payload[1], .array([.string("ru")]))
        XCTAssertEqual(payload[2], .array([.string(""), .string(""), .string(""),
                                            .null, .null, .null, .null, .null, .null, .string("")]))
        XCTAssertEqual(payload[6], .array([.int(1)]))
        XCTAssertEqual(payload[7], .int(1), "streaming")
        XCTAssertEqual(payload[10], .int(1))
        XCTAssertEqual(payload[11], .int(0))
        XCTAssertEqual(payload[17], .array([.array([.int(0)])]))
        XCTAssertEqual(payload[18], .int(0))
        XCTAssertEqual(payload[27], .int(1))
        XCTAssertEqual(payload[30], .array([.int(4)]))
        XCTAssertEqual(payload[41], .array([.int(1)]))
        XCTAssertEqual(payload[53], .int(0))
        XCTAssertEqual(payload[59], .string(sessionUUID))
        XCTAssertEqual(payload[61], .array([]))
        XCTAssertEqual(payload[68], .int(1))
        XCTAssertEqual(payload[79], .int(model.number))
        XCTAssertEqual(payload[80], .int(1), "no extended thinking")
    }

    func testUndocumentedIndicesStayNull() throws {
        let payload = GeminiRequestBuilder.generatePayload(
            prompt: "x", model: model, sessionUUID: sessionUUID)
        let documented: Set<Int> = [0, 1, 2, 6, 7, 10, 11, 17, 18, 27, 30, 41, 53, 59, 61, 68, 79, 80]
        for index in 0..<81 where !documented.contains(index) {
            XCTAssertTrue(payload[index].isNull, "index \(index) must remain null")
        }
    }

    func testFReqWrapsThePayloadAsAFreshConversation() throws {
        let fReq = GeminiRequestBuilder.generateFReq(
            prompt: "Hello", model: model, sessionUUID: sessionUUID)
        let outer = try decode(fReq)
        XCTAssertEqual(outer.arrayValue?.count, 2)
        XCTAssertTrue(outer[0]?.isNull == true, "a fresh conversation sends null history")
        let innerText = try XCTUnwrap(outer[1]?.stringValue)
        let inner = try decode(innerText)
        XCTAssertEqual(inner.arrayValue?.count, 81)
        XCTAssertEqual(inner[0]?[0]?.stringValue, "Hello")
        XCTAssertEqual(inner[59]?.stringValue, sessionUUID)
    }

    // MARK: - Headers

    func testGenerateHeadersCarryTheModelSelection() throws {
        let headers = GeminiRequestBuilder.generateHeaders(model: model, sessionUUID: sessionUUID)
        XCTAssertEqual(headers["Content-Type"], "application/x-www-form-urlencoded;charset=utf-8")
        XCTAssertEqual(headers["Origin"], "https://gemini.google.com")
        XCTAssertEqual(headers["Referer"], "https://gemini.google.com/")
        XCTAssertEqual(headers["X-Same-Domain"], "1")
        XCTAssertEqual(headers[GeminiProtocol.extraHeaderName89], "[0]")
        XCTAssertEqual(headers[GeminiProtocol.extraHeaderName90], "[0,0,0]")

        let modelHeader = try decode(try XCTUnwrap(headers[GeminiProtocol.modelHeaderName]))
        XCTAssertEqual(modelHeader.arrayValue?.count, 17,
                       "the literal from §7.2 has 17 elements, indices 0...16")
        XCTAssertEqual(modelHeader[0], .int(1))
        XCTAssertEqual(modelHeader[4], .string(model.id))
        XCTAssertEqual(modelHeader[7], .int(0))
        XCTAssertEqual(modelHeader[8], .array([.int(4), .int(5), .int(6), .int(8)]))
        XCTAssertEqual(modelHeader[11], .int(model.capacity))
        XCTAssertEqual(modelHeader[14], .int(model.number))
        XCTAssertEqual(modelHeader[15], .int(1))
        XCTAssertEqual(modelHeader[16], .string(sessionUUID))

        let sessionHeader = try decode(try XCTUnwrap(headers[GeminiProtocol.sessionHeaderName]))
        XCTAssertEqual(sessionHeader, .array([.string(sessionUUID), .int(1)]))
    }

    func testBatchExecModelHeaderHasNoModel() throws {
        let headers = GeminiRequestBuilder.batchExecHeaders(sessionUUID: sessionUUID)
        let modelHeader = try decode(try XCTUnwrap(headers[GeminiProtocol.modelHeaderName]))
        XCTAssertEqual(modelHeader.arrayValue?.count, 17)
        XCTAssertTrue(modelHeader[4]?.isNull == true, "status and usage RPCs carry no model id")
        XCTAssertEqual(modelHeader[8], .array([.int(4), .int(5), .int(6), .int(8)]))
        XCTAssertEqual(modelHeader[16]?.stringValue, sessionUUID)
    }

    // MARK: - Request bodies and URLs

    func testGenerateBody() {
        let body = GeminiRequestBuilder.generateBody(at: "AT+TOKEN", fReq: "[null,\"x y\"]")
        XCTAssertEqual(body, "at=AT%2BTOKEN&f.req=%5Bnull%2C%22x+y%22%5D")
    }

    func testGenerateURLCarriesEveryRequiredQueryParameter() throws {
        let config = GeminiConfig.lastResort
        let url = try XCTUnwrap(URL(string: GeminiRequestBuilder.generateURL(
            config: config, bl: "boq_build", sessionId: "1234567890", reqid: 10000)))
        XCTAssertEqual(url.path, GeminiProtocol.streamGeneratePath)
        let items = Dictionary(uniqueKeysWithValues:
            URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["hl"], "ru")
        XCTAssertEqual(items["_reqid"], "10000")
        XCTAssertEqual(items["rt"], "c")
        XCTAssertEqual(items["bl"], "boq_build")
        XCTAssertEqual(items["f.sid"], "1234567890")
    }

    func testBatchExecFReqShape() throws {
        // Shape: [[[rpcid, payload, null, "generic"]]]
        let fReq = GeminiRequestBuilder.batchExecFReq(rpcId: "otAQ7b", payload: "[]")
        let outer = try decode(fReq)
        let rpc = try XCTUnwrap(outer[0]?[0])
        XCTAssertEqual(rpc.arrayValue?.count, 4)
        XCTAssertEqual(rpc[0], .string("otAQ7b"))
        XCTAssertEqual(rpc[1], .string("[]"), "the payload is carried as a JSON string")
        XCTAssertTrue(rpc[2]?.isNull == true)
        XCTAssertEqual(rpc[3], .string("generic"))
    }

    func testBatchExecURLSourcePathSelectsTheBackend() throws {
        let config = GeminiConfig.lastResort
        let status = try XCTUnwrap(URL(string: GeminiRequestBuilder.batchExecURL(
            config: config, rpcId: "otAQ7b", sourcePath: .app,
            bl: "b", sessionId: "s", reqid: 1)))
        let usage = try XCTUnwrap(URL(string: GeminiRequestBuilder.batchExecURL(
            config: config, rpcId: "jSf9Qc", sourcePath: .usage,
            bl: "b", sessionId: "s", reqid: 1)))
        XCTAssertEqual(status.path, GeminiProtocol.batchexecutePath)

        func queryItems(_ url: URL) -> [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queryItems(status)["rpcids"], "otAQ7b")
        XCTAssertEqual(queryItems(status)["source-path"], "/app")
        XCTAssertEqual(queryItems(status)["source-path"], "/app")
        XCTAssertEqual(queryItems(usage)["source-path"], "/usage")
        XCTAssertEqual(queryItems(usage)["rpcids"], "jSf9Qc")
        XCTAssertEqual(queryItems(status)["rt"], "c")
        XCTAssertEqual(queryItems(status)["hl"], "ru")
    }

    func testQuotaPayloadLiterals() {
        XCTAssertEqual(GeminiRequestBuilder.QuotaPayload.flash, "[[[1,11],[2,11],[6,11]]]")
        XCTAssertEqual(GeminiRequestBuilder.QuotaPayload.pro, "[[[1,4],[6,6],[1,15]]]")
        XCTAssertEqual(GeminiRequestBuilder.QuotaPayload.empty, "[]")
    }

    func testRotateCookiesRequestMatchesTheWebClient() {
        XCTAssertEqual(GeminiRequestBuilder.rotateCookiesBody, "[000,\"-0000000000000000000\"]")
        let headers = GeminiRequestBuilder.rotateCookiesHeaders()
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Origin"], "https://accounts.google.com")
        XCTAssertEqual(GeminiConfig.lastResort.rotateCookiesURL,
                       "https://accounts.google.com/RotateCookies")
    }

    // MARK: - Configuration loading

    func testBundledConfigIsReadable() throws {
        let config = try XCTUnwrap(GeminiConfigLoader.bundled(),
                                   "gemini-web.json must ship inside the package")
        XCTAssertEqual(config.rpcStatus, "otAQ7b")
        XCTAssertEqual(config.rpcUsage, "jSf9Qc")
        XCTAssertEqual(config.rpcQuota, "qpEbW")
        XCTAssertEqual(config.wizAt, "SNlM0e")
        XCTAssertEqual(config.wizBuild, "cfb2h")
        XCTAssertEqual(config.wizSession, "FdrFJe")
        XCTAssertEqual(config.wizLang, "TuX5cc")
        XCTAssertEqual(config.models.count, 4)
        XCTAssertEqual(config.defaultModel, "56fdd199312815e2")
        XCTAssertTrue(config.generateURL.hasSuffix(GeminiProtocol.streamGeneratePath))
        XCTAssertTrue(config.batchexecuteURL.hasSuffix(GeminiProtocol.batchexecutePath))
    }

    func testLastResortLiteralMatchesTheBundledResource() throws {
        let bundled = try XCTUnwrap(GeminiConfigLoader.bundled())
        XCTAssertEqual(GeminiConfig.lastResort, bundled,
                       "the fallback literal and gemini-web.json must not drift apart")
    }

    func testOverrideReplacesTheBundledDefaults() throws {
        let json = """
        {"init":"https://gemini.google.com/app","generate":"https://gemini.google.com/gen",
         "batchexecute":"https://gemini.google.com/batch",
         "rotateCookies":"https://accounts.google.com/RotateCookies",
         "rpc":{"status":"AAA111","usage":"BBB222","quota":"CCC333"},
         "wizKeys":{"at":"AT","build":"BL","session":"SID","lang":"HL"},
         "models":[{"id":"deadbeefdeadbeef","label":"Custom","capacity":7,"number":2}],
         "defaultModel":"deadbeefdeadbeef","prompts":{"version":2}}
        """
        let config = try XCTUnwrap(GeminiConfigLoader.resolve(override: Data(json.utf8)))
        XCTAssertEqual(config.rpcStatus, "AAA111")
        XCTAssertEqual(config.wizLang, "HL")
        XCTAssertEqual(config.models.first?.capacity, 7)
        XCTAssertEqual(config.promptVersion, 2)
    }

    func testMalformedOverrideFallsBackToTheBundledDefaults() throws {
        let config = try XCTUnwrap(GeminiConfigLoader.resolve(override: Data("{ nope".utf8)))
        XCTAssertEqual(config.rpcStatus, "otAQ7b", "a bad override must not break translation")
    }

    func testModelLookupFallsBackToTheDefault() {
        let config = GeminiConfig.lastResort
        XCTAssertEqual(config.model(id: "e6fa609c3fa255c0")?.label, "Pro (подписка)")
        XCTAssertEqual(config.model(id: "unknown-id")?.id, config.defaultModel)
        XCTAssertEqual(config.model(id: nil)?.id, config.defaultModel)
    }
}

/// Frame-level parsing of the `batchexecute` and `StreamGenerate` responses.
final class GeminiResponseTests: XCTestCase {
    // MARK: - Frame construction helpers

    /// Wraps a JSON document in the `<length>\n<json>\n` framing, where the
    /// length counts UTF-16 code units exactly like JavaScript's `String.length`.
    private func frame(_ json: String) -> String {
        "\(json.utf16.count)\n\(json)\n"
    }

    private func jsonStringLiteral(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    /// A part tuple shaped like the real thing: `[_, rpcid, payload, _, _, meta]`.
    private func part(rpcId: String, payload: String?, meta: String = "null") -> String {
        "[null,\(jsonStringLiteral(rpcId)),"
            + (payload.map(jsonStringLiteral) ?? "null") + ",null,null,\(meta)]"
    }

    private func response(frames: [String], withPrefix: Bool = true) -> String {
        (withPrefix ? ")]}'\n\n" : "") + frames.joined()
    }

    /// Builds a StreamGenerate payload array: `[_, [cid, rid], _, _, candidates]`.
    private func streamPayload(candidates: String, conversationId: String = "c_1",
                               responseId: String = "r_1") -> String {
        "[null,[\(jsonStringLiteral(conversationId)),\(jsonStringLiteral(responseId))],null,null,\(candidates)]"
    }

    // MARK: - Prefix and framing

    func testAntiHijackingPrefixIsStripped() {
        XCTAssertEqual(GeminiResponseParser.stripPrefix(")]}'\n\n123\n[]\n"), "123\n[]\n")
        XCTAssertEqual(GeminiResponseParser.stripPrefix(")]}'123"), "123")
        XCTAssertEqual(GeminiResponseParser.stripPrefix("\n\nabc"), "abc")
        XCTAssertEqual(GeminiResponseParser.stripPrefix("abc"), "abc")
    }

    func testSingleFrameIsParsed() {
        let body = response(frames: [frame("[\(part(rpcId: "otAQ7b", payload: "[1,2]"))]")])
        let frames = GeminiResponseParser.parseFrames(body)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].parts.count, 1)
        XCTAssertEqual(frames[0].parts[0].rpcId, "otAQ7b")
        XCTAssertEqual(frames[0].parts[0].payloadText, "[1,2]")
    }

    func testMultipleFramesAndMultiplePartsPerFrameAreKeptInOrder() {
        let body = response(frames: [
            frame("[\(part(rpcId: "rpc1", payload: "[]")),\(part(rpcId: "rpc2", payload: "[1]"))]"),
            frame("[\(part(rpcId: "rpc3", payload: "[2]"))]"),
        ])
        let frames = GeminiResponseParser.parseFrames(body)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.flatMap { $0.parts.map(\.rpcId) }, ["rpc1", "rpc2", "rpc3"])
    }

    func testLengthPrefixCountsUTF16UnitsNotGraphemes() {
        // An emoji is 2 UTF-16 units but 1 Character, and Cyrillic is 1 unit but
        // 1 Character: using `String.count` would desynchronise the reader.
        let payload = #"[["Привет 😀 мир"]]"#
        XCTAssertNotEqual(payload.count, payload.utf16.count,
                          "the fixture must actually distinguish the two")
        let body = response(frames: [
            frame("[\(part(rpcId: "rpc", payload: payload))]"),
            frame("[\(part(rpcId: "second", payload: "[]"))]"),
        ])
        let frames = GeminiResponseParser.parseFrames(body)
        XCTAssertEqual(frames.count, 2, "a mistimed frame boundary would lose the second frame")
        XCTAssertEqual(frames[0].parts[0].payloadText, payload)
        XCTAssertEqual(frames[1].parts[0].rpcId, "second")
    }

    func testFrameWithTrailingNewlineInsideThePayloadIsNotTruncated() {
        let payload = "[\"line one\\nline two\"]"
        let body = response(frames: [frame("[\(part(rpcId: "rpc", payload: payload))]")])
        XCTAssertEqual(GeminiResponseParser.parseFrames(body).first?.parts.first?.payloadText, payload)
    }

    func testGarbageAfterTheLastFrameIsIgnored() {
        let body = response(frames: [frame("[\(part(rpcId: "rpc", payload: "[]"))]")])
            + "trailing junk that is not a frame"
        XCTAssertEqual(GeminiResponseParser.parseFrames(body).count, 1)
    }

    func testObjectWithoutArrayIsNotAFrame() {
        XCTAssertTrue(GeminiResponseParser.parseFrames(response(frames: [frame("{\"a\":1}")])).isEmpty)
        XCTAssertTrue(GeminiResponseParser.parseFrames("").isEmpty)
        XCTAssertTrue(GeminiResponseParser.parseFrames(")]}'").isEmpty)
    }

    // MARK: - Errors

    func testRejectCodeSevenMeansNotAuthorised() {
        let body = response(frames: [frame("[\(part(rpcId: "rpc", payload: "[]", meta: "[7]"))]")])
        let frames = GeminiResponseParser.parseFrames(body)
        XCTAssertEqual(frames.first?.parts.first?.rejected, true)
        let result = GeminiResponseParser.payload(for: "rpc", in: frames)
        XCTAssertEqual(result?.error, .unauthenticated)
    }

    func testErrorCodesAreExtractedFromTheNestedMetaPath() {
        for code in [1013, 1037, 1050, 1052, 1060] {
            let meta = "[0,null,[[null,[\(code)]]]]"
            let body = response(frames: [frame("[\(part(rpcId: "rpc", payload: "[]", meta: meta))]")])
            let frames = GeminiResponseParser.parseFrames(body)
            XCTAssertEqual(frames.first?.parts.first?.errorCode, code, "code \(code)")
            let result = GeminiResponseParser.payload(for: "rpc", in: frames)
            XCTAssertEqual(result?.error?.code, code, "code \(code)")
        }
    }

    func testErrorCodeClassification() {
        XCTAssertEqual(GeminiError.forCode(1037).kind, .usageLimit)
        XCTAssertEqual(GeminiError.forCode(1060).kind, .ipRegion)
        XCTAssertEqual(GeminiError.forCode(1013).kind, .temporary)
        XCTAssertEqual(GeminiError.forCode(1050).kind, .modelMismatch)
        XCTAssertEqual(GeminiError.forCode(1052).kind, .badModelHeader)
        XCTAssertEqual(GeminiError.forCode(9999).kind, .unknown)
        XCTAssertEqual(GeminiError.forCode(1037).message, "Лимит Gemini исчерпан, продолжаем автоматически.")
        XCTAssertEqual(GeminiError.forCode(1060).message, "Gemini недоступен: включите VPN (1060).")
        XCTAssertTrue(GeminiError.forCode(1013).isRetryableImmediately)
        XCTAssertFalse(GeminiError.forCode(1037).isRetryableImmediately)
    }

    func testHTTPStatusClassification() {
        XCTAssertNil(GeminiResponseParser.error(forHTTPStatus: 200))
        XCTAssertNil(GeminiResponseParser.error(forHTTPStatus: 204))
        XCTAssertEqual(GeminiResponseParser.error(forHTTPStatus: 401)?.kind, .unauthenticated)
        XCTAssertEqual(GeminiResponseParser.error(forHTTPStatus: 403)?.kind, .unauthenticated)
        XCTAssertEqual(GeminiResponseParser.error(forHTTPStatus: 429)?.kind, .usageLimit)
        XCTAssertEqual(GeminiResponseParser.error(forHTTPStatus: 503)?.kind, .temporary)
        XCTAssertEqual(GeminiResponseParser.error(forHTTPStatus: 418)?.kind, .unknown)
    }

    func testNoConnectionIsConnectivityNotAProtocolAnswer() {
        // The transport reports status 0 for a failed fetch (offline, VPN off,
        // timeout). Callers must not treat that as a malformed protocol reply:
        // the queue waits instead of spending the batch's retry budget.
        let offline = GeminiResponseParser.error(forHTTPStatus: 0)
        XCTAssertEqual(offline?.kind, .unavailable)
        XCTAssertFalse(offline?.isRetryableImmediately ?? true)
        XCTAssertEqual(GeminiError.unavailable.kind, .unavailable)
        XCTAssertTrue(GeminiError.unavailable.message.contains("VPN"))
    }

    func testSuccessfulPayloadWinsOverAnEarlierErrorFrame() {
        let errorFrame = frame("[\(part(rpcId: "rpc", payload: "[]", meta: "[0,null,[[null,[1013]]]]"))]")
        let goodFrame = frame("[\(part(rpcId: "rpc", payload: "[42]"))]")
        let result = GeminiResponseParser.payload(for: "rpc", in: GeminiResponseParser.parseFrames(
            response(frames: [errorFrame, goodFrame])))
        XCTAssertEqual(result?.value[0], .int(42))
        XCTAssertNil(result?.error)
    }

    func testUnknownRpcIdReturnsNothing() {
        let body = response(frames: [frame("[\(part(rpcId: "rpc", payload: "[]"))]")])
        XCTAssertNil(GeminiResponseParser.payload(for: "other", in: GeminiResponseParser.parseFrames(body)))
    }

    // MARK: - StreamGenerate

    /// One frame carrying a StreamGenerate answer.
    private func streamFrame(candidates: String, conversationId: String = "c_1",
                             responseId: String = "r_1") -> String {
        let payload = streamPayload(candidates: candidates,
                                    conversationId: conversationId, responseId: responseId)
        return frame("[\(part(rpcId: "StreamGenerate", payload: payload))]")
    }

    /// A candidate array with the answer at index 1 and optional reasoning at
    /// index 37, the two positions the protocol uses.
    private func candidate(answer: String, reasoning: String? = nil) -> String {
        var fields = [String](repeating: "null", count: 38)
        fields[0] = "null"
        fields[1] = "[\(jsonStringLiteral(answer))]"
        if let reasoning {
            fields[37] = "[[\(jsonStringLiteral(reasoning))]]"
        }
        return "[" + fields.joined(separator: ",") + "]"
    }

    func testAnswerIsTheLastCandidateOfTheLastFrame() {
        let first = streamFrame(candidates: "[\(candidate(answer: "первый"))]")
        let second = streamFrame(candidates: "[\(candidate(answer: "второй")),\(candidate(answer: "третий"))]")
        let result = GeminiResponseParser.parseStreamGenerate(response(frames: [first, second]))
        XCTAssertEqual(result.text, "третий", "the last candidate of the last frame is the answer")
        XCTAssertEqual(result.conversationId, "c_1")
        XCTAssertEqual(result.responseId, "r_1")
        XCTAssertEqual(result.frameCount, 2)
        XCTAssertNil(result.error)
    }

    func testEarlierFrameTextIsSupersededByTheCompletedAnswer() {
        let partial = streamFrame(candidates: "[\(candidate(answer: "The quick"))]")
        let complete = streamFrame(candidates: "[\(candidate(answer: "The quick brown fox"))]")
        XCTAssertEqual(
            GeminiResponseParser.parseStreamGenerate(response(frames: [partial, complete])).text,
            "The quick brown fox")
    }

    func testReasoningPresenceIsNotedButNotReturned() {
        let frame1 = streamFrame(candidates: "[\(candidate(answer: "ответ", reasoning: "thinking…"))]")
        let result = GeminiResponseParser.parseStreamGenerate(response(frames: [frame1]))
        XCTAssertEqual(result.text, "ответ", "extended thinking is discarded, not returned")
        XCTAssertTrue(result.hadReasoning)
    }

    func testEmptyCandidateListFallsThroughToTheNextFrame() {
        let empty = streamFrame(candidates: "[]")
        let filled = streamFrame(candidates: "[\(candidate(answer: "после пустого"))]")
        XCTAssertEqual(
            GeminiResponseParser.parseStreamGenerate(response(frames: [empty, filled])).text,
            "после пустого")
    }

    func testEmptyAnswerTextFallsThroughToTheNextFrame() {
        let emptyText = streamFrame(candidates: "[\(candidate(answer: ""))]")
        let filled = streamFrame(candidates: "[\(candidate(answer: "готово"))]")
        XCTAssertEqual(
            GeminiResponseParser.parseStreamGenerate(response(frames: [emptyText, filled])).text,
            "готово")
    }

    func testErrorFrameYieldsAnErrorInsteadOfText() {
        let errorFrame = frame("[\(part(rpcId: "StreamGenerate", payload: nil, meta: "[0,null,[[null,[1037]]]]"))]")
        let result = GeminiResponseParser.parseStreamGenerate(response(frames: [errorFrame]))
        XCTAssertNil(result.text)
        XCTAssertEqual(result.error?.kind, .usageLimit)
    }

    func testRejectedStreamGenerateIsUnauthenticated() {
        let rejected = frame("[\(part(rpcId: "StreamGenerate", payload: nil, meta: "[7]"))]")
        let result = GeminiResponseParser.parseStreamGenerate(response(frames: [rejected]))
        XCTAssertNil(result.text)
        XCTAssertEqual(result.error?.kind, .unauthenticated)
    }

    func testResponseWithoutAnyFrameIsEmptyNotCrashing() {
        let result = GeminiResponseParser.parseStreamGenerate(")]}'\n\n")
        XCTAssertNil(result.text)
        XCTAssertNil(result.error, "no frames means no answer, and the caller reports it")
        XCTAssertEqual(result.frameCount, 0)
    }

    func testTextIsNotTakenFromAStringThatIsNotACandidate() {
        // A payload whose shape does not match must not be mistaken for an answer.
        let weird = frame("[\(part(rpcId: "StreamGenerate", payload: "[null,null,null,null,[]]"))]")
        XCTAssertNil(GeminiResponseParser.parseStreamGenerate(response(frames: [weird])).text)
    }

    func testConversationIdsSurviveWhenTheTextComesFromALaterFrame() {
        let intro = streamFrame(candidates: "[]", conversationId: "c_9", responseId: "r_9")
        let answer = streamFrame(candidates: "[\(candidate(answer: "ok"))]", conversationId: "c_9", responseId: "r_10")
        let result = GeminiResponseParser.parseStreamGenerate(response(frames: [intro, answer]))
        XCTAssertEqual(result.conversationId, "c_9")
        XCTAssertEqual(result.responseId, "r_10", "the newest ids win")
        XCTAssertEqual(result.text, "ok")
    }

    // MARK: - Account status and usage

    func testAccountStatusCodes() {
        let ok = GeminiResponseParser.parseAccountStatus(try! JSONValue.decode(from: Data("[0,0,0,0,0,0,0,0,0,0,0,0,0,0,1000]".utf8)))
        XCTAssertEqual(ok.statusCode, 1000)
        XCTAssertNil(ok.error)
        XCTAssertTrue(ok.isSignedIn)

        let signedOut = GeminiResponseParser.parseAccountStatus(try! JSONValue.decode(from: Data("[0,0,0,0,0,0,0,0,0,0,0,0,0,0,1016]".utf8)))
        XCTAssertEqual(signedOut.error?.kind, .unauthenticated)
        XCTAssertFalse(signedOut.isSignedIn)

        let blocked = GeminiResponseParser.parseAccountStatus(try! JSONValue.decode(from: Data("[0,0,0,0,0,0,0,0,0,0,0,0,0,0,1060]".utf8)))
        XCTAssertEqual(blocked.error?.kind, .ipRegion)
    }

    func testModelListIsExtractedFromTheStatusPayload() {
        let json = """
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,1000,
         [[["56fdd199312815e2","Flash",1],[ "e6fa609c3fa255c0","Pro",3]],["group"]],
         2]
        """
        let status = GeminiResponseParser.parseAccountStatus(
            try! JSONValue.decode(from: Data(json.utf8)))
        XCTAssertEqual(status.models.map(\.id), ["56fdd199312815e2", "e6fa609c3fa255c0"])
        XCTAssertEqual(status.models.map(\.label), ["Flash", "Pro"])
        XCTAssertEqual(status.tierRaw, 2)
    }

    func testModelListInheritsCapacityAndNumberFromPresets() {
        let json = """
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,1000,[["56fdd199312815e2","Flash"]]]
        """
        let preset = GeminiModel(id: "56fdd199312815e2", label: "Flash (подписка)",
                                 capacity: 4, number: 1)
        let status = GeminiResponseParser.parseAccountStatus(
            try! JSONValue.decode(from: Data(json.utf8)), presets: [preset])
        XCTAssertEqual(status.models.first?.capacity, 4,
                       "positional fields cannot be guessed, so presets fill them in")
        XCTAssertEqual(status.models.first?.number, 1)
        XCTAssertEqual(status.models.first?.label, "Flash",
                       "the label the account actually uses wins over the preset")
    }

    func testModelIdRecognition() {
        XCTAssertTrue(GeminiResponseParser.isModelId("56fdd199312815e2"))
        XCTAssertFalse(GeminiResponseParser.isModelId("56FDD199312815E2"), "ids are lowercase")
        XCTAssertFalse(GeminiResponseParser.isModelId("56fdd199312815e"), "too short")
        XCTAssertFalse(GeminiResponseParser.isModelId("Flash"))
    }

    func testUsageTierIsRecognized() {
        let usage = GeminiResponseParser.parseUsage(
            try! JSONValue.decode(from: Data("[2,0.4,0.7]".utf8)))
        XCTAssertEqual(usage.tier, .pro)
        XCTAssertEqual(usage.tierLabel, "Pro")
        XCTAssertEqual(usage.raw.jsonText, "[2,0.4,0.7]")
    }

    func testUsageTierLabelsCoverAllKnownTiers() {
        XCTAssertEqual(GeminiUsage.Tier(rawValue: 1)?.label, "Free")
        XCTAssertEqual(GeminiUsage.Tier(rawValue: 2)?.label, "Pro")
        XCTAssertEqual(GeminiUsage.Tier(rawValue: 3)?.label, "Ultra")
        XCTAssertEqual(GeminiUsage.Tier(rawValue: 4)?.label, "Plus")
    }
}

/// The positional JSON container the protocol is built on.
final class JSONValueTests: XCTestCase {
    private func decode(_ text: String) throws -> JSONValue {
        try JSONValue.decode(from: Data(text.utf8))
    }

    func testRoundTripPreservesNullHolesAndOrder() throws {
        let value = JSONValue.array([.null, .string("a"), .int(1), .array([.int(2)]), .bool(true)])
        let text = value.jsonText
        XCTAssertEqual(text, "[null,\"a\",1,[2],true]")
        XCTAssertEqual(try decode(text), value)
    }

    func testSubscriptAndAccessors() throws {
        let value = try decode("{\"a\":[10,\"b\"]}")
        XCTAssertNil(value[0], "an object has no positional elements")
        let array = try decode("[10,\"b\",null]")
        XCTAssertEqual(array[0]?.intValue, 10)
        XCTAssertEqual(array[1]?.stringValue, "b")
        XCTAssertTrue(array[2]?.isNull == true)
        XCTAssertNil(array[5])
        XCTAssertEqual(array.arrayValue?.count, 3)
    }

    func testNonIntegerNumbersDegradeToNullRatherThanCrashing() throws {
        XCTAssertNil(try decode("[1.5]")[0]?.intValue)
    }

    func testEncodedJSONIsStable() throws {
        let value = try decode("{\"b\":1,\"a\":2}")
        XCTAssertEqual(value.jsonText, "{\"a\":2,\"b\":1}", "keys are sorted for reproducible prompts")
    }

    func testDepthFirstStringSearch() throws {
        let value = try decode("[null,[\"c_1\",\"r_1\"],[[\"deep\"]]]")
        XCTAssertEqual(JSONPayload.firstString(in: value, matching: { $0.hasPrefix("r_") }), "r_1")
        XCTAssertEqual(JSONPayload.firstString(in: value, matching: { $0 == "deep" }), "deep")
        XCTAssertNil(JSONPayload.firstString(in: value, matching: { $0 == "absent" }))
    }
}
