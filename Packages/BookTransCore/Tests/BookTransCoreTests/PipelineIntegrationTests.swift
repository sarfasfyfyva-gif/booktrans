import XCTest
@testable import BookTransCore

/// End-to-end coverage of the Core pipeline with no network and no device:
/// a real FB2 file goes in, a batch plan comes out, the plan is turned into
/// prompts, the prompts are answered in the exact JSON shape the model is asked
/// for, those answers are parsed back, and the reader page is built from them.
///
/// This is the closest thing to the on-device acceptance run that can be executed
/// on Linux, and it is what catches the seams between the pieces.
final class PipelineIntegrationTests: XCTestCase {
    /// A book large enough to produce several batches, with a glossary term
    /// repeated across chapters.
    private func makeBook(chapters: Int, paragraphsPerChapter: Int) -> String {
        let body = (0..<chapters).map { chapter in
            let paragraphs = (0..<paragraphsPerChapter).map { index in
                "<p>Paragraph \(index) of chapter \(chapter) discusses the ROI of the venture "
                    + "and explains why the payback period matters for the board. "
                    + String(repeating: "More prose follows here. ", count: 12)
                    + "</p>"
            }.joined()
            return "<section><title><p>Chapter \(chapter + 1)</p></title>\(paragraphs)</section>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
          <description><title-info>
            <author><first-name>Ada</first-name><last-name>Lovelace</last-name></author>
            <book-title>Notes on the Engine</book-title><lang>en</lang>
          </title-info></description>
          <body>\(body)</body>
        </FictionBook>
        """
    }

    /// Stands in for the model: the texts it was asked to translate, prefixed and
    /// returned in the required JSON envelope.
    private func answer(_ prompt: String) throws -> String {
        let blocks = MockShape.blocks(in: prompt)
        let payload: [String: Any] = [
            "translations": blocks.map { "[ru] \($0)" },
            "glossary": [["term": "ROI", "translation": "рентабельность инвестиций (ROI)"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private enum MockShape {
        /// Reads the `[БЛОКИ]` array back out of the prompt, using the same
        /// implementation the app's mock provider uses.
        static func blocks(in prompt: String) -> [String] {
            PromptBuilder.blockTexts(in: prompt) ?? []
        }
    }

    func testBookIsParsedPlannedTranslatedAndRendered() throws {
        // 1. Import.
        let parsed = try FB2Parser.parse(text: makeBook(chapters: 3, paragraphsPerChapter: 6))
        XCTAssertEqual(parsed.title, "Notes on the Engine")
        XCTAssertEqual(parsed.author, "Ada Lovelace")
        XCTAssertEqual(parsed.chapters.count, 3)

        // 2. Plan.
        let plan = Chunker.plan(chapters: parsed.chapters)
        XCTAssertFalse(plan.batches.isEmpty)
        XCTAssertEqual(plan.totalChars, Chunker.totalCharacters(in: parsed.chapters))
        for (index, batch) in plan.batches.enumerated() {
            XCTAssertEqual(batch.index, index)
            XCTAssertFalse(batch.units.isEmpty)
        }
        XCTAssertEqual(plan.batches.flatMap(\.units).count,
                       plan.batches.reduce(0) { $0 + $1.units.count })
        // The block sequence must be the book's order, with no repeats.
        var seenBlocks: [Int] = []
        for unit in plan.batches.flatMap(\.units) where seenBlocks.last != unit.block {
            seenBlocks.append(unit.block)
        }
        XCTAssertEqual(seenBlocks, seenBlocks.sorted(), "blocks must follow the book")
        XCTAssertEqual(Set(seenBlocks).count, seenBlocks.count)

        // 3. Translate every batch the way the queue does, growing the glossary.
        var glossary = Glossary()
        var results: [Int: BatchResult] = [:]
        for batch in plan.batches {
            if !batch.lookaheadDone {
                let lookahead = PromptBuilder.termExtractionPrompt(units: batch.units)
                XCTAssertTrue(lookahead.contains("[ФРАГМЕНТ]"))
                var store = GlossaryStore(glossary: glossary)
                store.merge(ResponseParser.parseGlossary(
                    #"{"glossary":[{"term":"ROI","translation":"рентабельность инвестиций (ROI)"}]}"#),
                            source: .auto, firstBlock: batch.units.first?.block ?? -1)
                glossary = store.glossary
            }

            let prompt = PromptBuilder.translationPrompt(units: batch.units, glossary: glossary)
            // The glossary must actually reach the prompt once it is known.
            if !glossary.terms.isEmpty {
                XCTAssertTrue(prompt.contains("ROI → рентабельность инвестиций (ROI)"),
                              "a known term must be sent to the model")
            }

            let raw = try answer(prompt)
            let decoded = try ResponseParser.parse(raw, expectedCount: batch.units.count).get()
            XCTAssertEqual(decoded.translations.count, batch.units.count)
            XCTAssertTrue(decoded.translations.allSatisfy { $0.hasPrefix("[ru] ") },
                          "every unit must come back translated")

            var store = GlossaryStore(glossary: glossary)
            store.merge(decoded.glossary, source: .auto, firstBlock: batch.units.first?.block ?? -1)
            glossary = store.glossary

            results[batch.index] = BatchResult(index: batch.index, modelId: "test",
                                               translations: decoded.translations)
        }
        XCTAssertEqual(results.count, plan.batches.count)
        XCTAssertEqual(glossary.terms.first?.key, "roi")

        // 4. Render.
        var translatedPlan = plan
        for index in translatedPlan.batches.indices {
            translatedPlan.batches[index].status = .done
        }
        let map = TranslationMap(plan: translatedPlan, results: results)
        XCTAssertTrue(map.isTranslated(parsed.chapters[0]), "every block came back")

        let html = ReaderHTMLBuilder.build(
            chapter: parsed.chapters[0], translations: map, configuration: .init(showTranslation: true))
        XCTAssertFalse(html.contains(ReaderHTMLBuilder.untranslatedMarker),
                       "nothing is untranslated, so the switch notice must be absent")
        XCTAssertTrue(html.contains("[ru] "), "the translation must be on the page")
        XCTAssertTrue(html.contains("Chapter 1"), "headings are translated too")
        XCTAssertTrue(html.contains("id=\"b0\""), "block ids stay stable for position restore")

        let original = ReaderHTMLBuilder.build(
            chapter: parsed.chapters[0], translations: map, configuration: .init(showTranslation: false))
        XCTAssertFalse(original.contains("[ru] "), "original mode must not leak translations")
        XCTAssertTrue(original.contains("Paragraph 0 of chapter 0"))

        // 5. A partially translated book renders the tail as the original.
        var partial = results
        partial.removeValue(forKey: translatedPlan.batches.last!.index)
        var partialPlan = plan
        for index in partialPlan.batches.indices {
            partialPlan.batches[index].status = partialPlan.batches[index].index == translatedPlan.batches.last!.index
                ? .pending : .done
        }
        let partialMap = TranslationMap(plan: partialPlan, results: partial)
        let partialHTML = ReaderHTMLBuilder.build(
            chapter: parsed.chapters.last!, translations: partialMap,
            configuration: .init(showTranslation: true))
        XCTAssertTrue(partialHTML.contains(ReaderHTMLBuilder.untranslatedMarker),
                      "the untranslated chapter must say so")
        XCTAssertTrue(partialHTML.contains("Paragraph 0 of chapter 2"),
                      "and fall back to the original text")
    }

    func testEveryUnitSurvivesPromptAndParseRoundTrip() throws {
        // Text chosen to stress JSON escaping: quotes, newlines, backslashes,
        // Cyrillic and an emoji.
        let nasty = "He said \"it's 100% \\ done\"\nand left — Привет 😀"
        let chapter = Chapter(index: 0, title: "T", blocks: [
            Block(id: 0, kind: .paragraph, text: nasty),
        ])
        let plan = Chunker.plan(chapters: [chapter])
        let units = plan.batches.flatMap(\.units)
        XCTAssertEqual(units.map(\.text), [nasty])

        let prompt = PromptBuilder.translationPrompt(units: units, glossary: Glossary())
        XCTAssertEqual(MockShape.blocks(in: prompt), [nasty],
                       "the prompt must carry the text verbatim through JSON encoding")

        let decoded = try ResponseParser.parse(try answer(prompt), expectedCount: 1).get()
        XCTAssertEqual(decoded.translations, ["[ru] \(nasty)"])
    }

    func testMalformedAnswerFailsWithoutLosingTheBatch() throws {
        let plan = Chunker.plan(chapters: [
            Chapter(index: 0, title: "T", blocks: [Block(id: 0, kind: .paragraph, text: "Hello")])
        ])
        let units = plan.batches.flatMap(\.units)
        let prompt = PromptBuilder.translationPrompt(units: units, glossary: Glossary())

        // Prose instead of JSON, then the retry prompt with a reminder.
        XCTAssertFailure(ResponseParser.parse("Sure! Here is the translation.", expectedCount: 1))
        let retry = PromptBuilder.retry(prompt)
        XCTAssertTrue(retry.hasSuffix(PromptBuilder.retrySuffix))
        XCTAssertEqual(MockShape.blocks(in: retry), units.map(\.text),
                       "the retry must ask for the same blocks, even though the reminder follows them")
        XCTAssertSuccess(ResponseParser.parse(try answer(retry), expectedCount: 1))
    }

    // MARK: - Helpers

    private func XCTAssertFailure<T>(
        _ result: Result<T, ResponseParserError>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .success = result {
            XCTFail("expected a failure", file: file, line: line)
        }
    }

    private func XCTAssertSuccess<T>(
        _ result: Result<T, ResponseParserError>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }
}
