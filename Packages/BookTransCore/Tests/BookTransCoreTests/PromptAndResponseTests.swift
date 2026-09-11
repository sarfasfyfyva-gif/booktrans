import XCTest
@testable import BookTransCore

final class PromptAndResponseTests: XCTestCase {
    // MARK: - PromptBuilder helpers

    private func units(_ texts: String...) -> [PlanUnit] {
        texts.enumerated().map { PlanUnit(block: $0.offset, part: 0, text: $0.element) }
    }

    /// The JSON array on the line after the `[БЛОКИ]` header, decoded back.
    private func blocksJSON(in prompt: String) -> [String] {
        let lines = prompt.components(separatedBy: "\n")
        guard let header = lines.firstIndex(of: "[БЛОКИ]"),
              header + 1 < lines.count,
              let data = lines[header + 1].data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            XCTFail("prompt has no decodable JSON array after [БЛОКИ]")
            return []
        }
        return decoded
    }

    // MARK: - translationPrompt

    func testTranslationPromptStatesCountAndCarriesBlocks() {
        let prompt = PromptBuilder.translationPrompt(
            units: units("First block.", "Second block."),
            glossary: Glossary()
        )
        XCTAssertTrue(prompt.contains("Переведи 2 блоков ниже."))
        XCTAssertTrue(prompt.contains("- В translations ровно 2 строк, порядок совпадает с порядком входных блоков."))
        XCTAssertTrue(prompt.contains("- Пустой блок переводи как пустую строку."))
        XCTAssertTrue(prompt.contains("- glossary: только новые термины"))
        XCTAssertEqual(blocksJSON(in: prompt), ["First block.", "Second block."])
    }

    func testTranslationPromptEscapesQuotesAndNewlines() {
        let tricky = "He said \"hi\"\nbye"
        let prompt = PromptBuilder.translationPrompt(units: units(tricky, "plain"), glossary: Glossary())
        XCTAssertEqual(blocksJSON(in: prompt), [tricky, "plain"])
        // The raw prompt line must not contain a literal newline inside the array.
        let lines = prompt.components(separatedBy: "\n")
        let header = lines.firstIndex(of: "[БЛОКИ]")!
        XCTAssertTrue(lines[header + 1].contains("\\\"hi\\\""))
        XCTAssertTrue(lines[header + 1].contains("\\n"))
    }

    func testTranslationPromptShapeLiteral() {
        let prompt = PromptBuilder.translationPrompt(units: units("a"), glossary: Glossary())
        XCTAssertTrue(prompt.contains("{\"translations\": [\"<перевод блока 1>\", \"<перевод блока 2>\", …], \"glossary\": [{\"term\": \"<термин>\", \"translation\": \"<перевод>\", \"note\": \"<необязательно>\"}]}"))
        XCTAssertTrue(prompt.contains("- Перенос строки внутри блока экранируй как \\n, кавычки — как \\\"."))
    }

    func testTranslationPromptInstructionRules() {
        let prompt = PromptBuilder.translationPrompt(units: units("a"), glossary: Glossary())
        XCTAssertTrue(prompt.hasPrefix("[ИНСТРУКЦИЯ]\nТы профессиональный переводчик деловой и нон-фикшн литературы."))
        XCTAssertTrue(prompt.contains("1. Переводи смысл, а не слова;"))
        XCTAssertTrue(prompt.contains("7. Регистр деловой, без обращения «ты»."))
    }

    func testEmptyGlossarySection() {
        XCTAssertEqual(PromptBuilder.glossarySection(Glossary(), currentText: "x", previousText: "y"), "")
        let prompt = PromptBuilder.translationPrompt(units: units("a"), glossary: Glossary())
        XCTAssertTrue(prompt.contains("[ГЛОССАРИЙ]\n\n[ЗАДАЧА]"))
    }

    func testGlossaryPairRendering() {
        let glossary = Glossary(terms: [
            GlossaryTerm(term: "ROI", translation: "рентабельность инвестиций (ROI)"),
        ])
        let section = PromptBuilder.glossarySection(glossary, currentText: "", previousText: "")
        XCTAssertEqual(section, "ROI → рентабельность инвестиций (ROI)")
        let prompt = PromptBuilder.translationPrompt(units: units("The ROI grew."), glossary: glossary)
        XCTAssertTrue(prompt.contains("[ГЛОССАРИЙ]\nROI → рентабельность инвестиций (ROI)\n\n[ЗАДАЧА]"))
    }

    func testGlossarySectionUnderLimitIsUnchanged() {
        let glossary = Glossary(terms: [
            GlossaryTerm(term: "KPI", translation: "ключевой показатель эффективности"),
            GlossaryTerm(term: "OKR", translation: "цели и ключевые результаты"),
        ])
        XCTAssertEqual(
            PromptBuilder.glossarySection(glossary, currentText: "", previousText: ""),
            "KPI → ключевой показатель эффективности\nOKR → цели и ключевые результаты"
        )
    }

    func testGlossaryTruncationKeepsTermsPresentInCurrentText() {
        // ~600 terms × ~110 chars per pair → well over the 20 000 limit.
        var terms: [GlossaryTerm] = []
        for i in 0..<600 {
            let name = "ZZZTerm\(i)Padded\(String(repeating: "q", count: 60))"
            terms.append(GlossaryTerm(term: name, translation: "перевод \(i) \(String(repeating: "п", count: 20))"))
        }
        let glossary = Glossary(terms: terms)
        let present = terms[7].term
        let current = "In this chapter \(present) matters a lot."
        let section = PromptBuilder.glossarySection(glossary, currentText: current, previousText: "")
        XCTAssertGreaterThan(
            terms.map { "\($0.term) → \($0.translation)" }.joined(separator: "\n").count, 20_000,
            "fixture must actually exceed the limit or the test proves nothing"
        )
        XCTAssertLessThan(section.count, 5_000, "truncated section must be much shorter than the full text")
        XCTAssertTrue(section.contains("\(present) →"), "term present in currentText must survive truncation")
        XCTAssertFalse(section.contains("\(terms[42].term) →"), "unmentioned terms must be dropped")
    }

    func testGlossaryTruncationMatchesPreviousTextToo() {
        var terms: [GlossaryTerm] = []
        for i in 0..<600 {
            terms.append(GlossaryTerm(term: "QQQTerm\(i)R\(String(repeating: "z", count: 60))", translation: "т\(i)"))
        }
        let glossary = Glossary(terms: terms)
        let section = PromptBuilder.glossarySection(
            glossary, currentText: "nothing relevant here",
            previousText: "Earlier we saw \(terms[3].term) once."
        )
        XCTAssertTrue(section.contains("\(terms[3].term) →"))
    }
    func testGlossaryTruncationFallbackWithoutAnyMatch() {
        // Full pair text exceeds the limit, but nothing matches: fall back to
        // top terms by count descending.
        var terms: [GlossaryTerm] = []
        for i in 0..<700 {
            terms.append(GlossaryTerm(
                term: "BBBTerm\(i)",
                translation: "перевод \(String(repeating: "п", count: 20))",
                count: i
            ))
        }
        let glossary = Glossary(terms: terms)
        let full = terms.map { "\($0.term) → \($0.translation)" }.joined(separator: "\n")
        XCTAssertGreaterThan(full.count, 20_000, "fixture must actually exceed the limit")
        let section = PromptBuilder.glossarySection(glossary, currentText: "no term here", previousText: "")
        XCTAssertFalse(section.isEmpty)
        // Highest count first.
        XCTAssertTrue(section.components(separatedBy: "\n").first == "BBBTerm699 → перевод \(String(repeating: "п", count: 20))")
    }

    // MARK: - termExtractionPrompt

    func testTermExtractionPrompt() {
        let prompt = PromptBuilder.termExtractionPrompt(units: units("Alpha text.", "Beta text."))
        XCTAssertTrue(prompt.contains("Ты терминологический редактор деловой литературы."))
        XCTAssertTrue(prompt.contains("{\"glossary\": [{\"term\": \"<термин>\", \"translation\": \"<рекомендуемый перевод>\", \"note\": \"<необязательно>\"}]}"))
        XCTAssertTrue(prompt.contains("- 10–25 записей, отсортированных по важности."))
        XCTAssertTrue(prompt.hasSuffix("[ФРАГМЕНТ]\nAlpha text.\n\nBeta text."))
    }

    // MARK: - retry

    func testRetryAppendsSuffix() {
        let base = "prompt body"
        XCTAssertEqual(PromptBuilder.retry(base), base + PromptBuilder.retrySuffix)
        XCTAssertTrue(PromptBuilder.retrySuffix.contains("[ВАЖНО]"))
    }

    // MARK: - ResponseParser: clean object

    func testParseCleanObject() {
        let raw = """
        {"translations": ["Привет", "Мир"], "glossary": [{"term": "ROI", "translation": "рентабельность", "note": ""}]}
        """
        let result = ResponseParser.parse(raw, expectedCount: 2)
        switch result {
        case .success(let answer):
            XCTAssertEqual(answer.shape, .object)
            XCTAssertEqual(answer.translations, ["Привет", "Мир"])
            XCTAssertEqual(answer.glossary, [GlossaryAddition(term: "ROI", translation: "рентабельность")])
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParseObjectWithoutGlossaryTreatsItAsEmpty() {
        let result = ResponseParser.parse("{\"translations\": [\"А\"]}", expectedCount: 1)
        switch result {
        case .success(let answer):
            XCTAssertEqual(answer.shape, .object)
            XCTAssertEqual(answer.translations, ["А"])
            XCTAssertEqual(answer.glossary, [])
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParseFencedObject() {
        let raw = "```json\n{\"translations\": [\"Раз\", \"Два\"], \"glossary\": []}\n```"
        let result = ResponseParser.parse(raw, expectedCount: 2)
        switch result {
        case .success(let answer):
            XCTAssertEqual(answer.shape, .object)
            XCTAssertEqual(answer.translations, ["Раз", "Два"])
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParseObjectSurroundedByProse() {
        let raw = "Вот перевод:\n{\"translations\": [\"Один\"], \"glossary\": []}\nНадеюсь, поможет!"
        let result = ResponseParser.parse(raw, expectedCount: 1)
        switch result {
        case .success(let answer):
            XCTAssertEqual(answer.translations, ["Один"])
            XCTAssertEqual(answer.shape, .object)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParseBareArray() {
        let result = ResponseParser.parse("[\"первый\", \"второй\"]", expectedCount: 2)
        switch result {
        case .success(let answer):
            XCTAssertEqual(answer.shape, .array)
            XCTAssertEqual(answer.translations, ["первый", "второй"])
            XCTAssertEqual(answer.glossary, [])
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParseGarbageFails() {
        let result = ResponseParser.parse("this is not json at all ((((", expectedCount: 2)
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error, .unparsable)
        }
    }

    func testParseObjectWithWrongCount() {
        let result = ResponseParser.parse(
            "{\"translations\": [\"a\", \"b\", \"c\"], \"glossary\": []}", expectedCount: 2
        )
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error, .wrongTranslationCount(expected: 2, got: 3))
        }
    }

    func testParseArrayWithWrongCount() {
        let result = ResponseParser.parse("[\"only\"]", expectedCount: 2)
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error, .wrongTranslationCount(expected: 2, got: 1))
        }
    }

    func testParseArrayWithBracketInsideString() {
        // A naive first-[ / first-] scan would cut the array after "a]".
        let result = ResponseParser.parse("[\"a]b\", \"c[d\"]", expectedCount: 2)
        switch result {
        case .success(let answer):
            XCTAssertEqual(answer.shape, .array)
            XCTAssertEqual(answer.translations, ["a]b", "c[d"])
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParseNonStringTranslationsFailsCleanly() {
        let result = ResponseParser.parse("{\"translations\": [1, 2], \"glossary\": []}", expectedCount: 2)
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertTrue(error == .unparsable || error == .wrongTranslationCount(expected: 2, got: 2))
        }
    }
}
