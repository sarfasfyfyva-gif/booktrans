import Foundation

/// Builds the single user message sent to the model for batch translation,
/// plus the lookahead terminology-extraction prompt.
public enum PromptBuilder {
    public static let glossaryCharLimit = 20_000
    public static let maxGlossaryTerms = 800
    public static let maxGlossaryAdditions = 15
    public static let retrySuffix = "\n\n[ВАЖНО]\nВерни ТОЛЬКО корректный JSON без комментариев, без markdown, без переносов строк вне строковых значений."

    /// One user message containing the instruction, glossary, task and the blocks.
    public static func translationPrompt(units: [PlanUnit], glossary: Glossary, previousUnits: [PlanUnit] = []) -> String {
        let currentText = units.map(\.text).joined(separator: " \n")
        let previousText = previousUnits.map(\.text).joined(separator: " \n")
        let pairs = glossarySection(glossary, currentText: currentText, previousText: previousText)
        let pairLines: [String] = pairs.isEmpty ? [] : pairs.components(separatedBy: "\n")
        let blocksData = (try? JSONEncoder().encode(units.map(\.text))) ?? Data("[]".utf8)
        let blocksJSON = String(data: blocksData, encoding: .utf8) ?? "[]"
        let count = units.count
        var lines: [String] = [
            "[ИНСТРУКЦИЯ]",
            "Ты профессиональный переводчик деловой и нон-фикшн литературы. Переводишь с английского на русский.",
            "",
            "Правила:",
            "1. Переводи смысл, а не слова; предложения должны звучать естественно по-русски.",
            "2. Термины, аббревиатуры, названия методологий переводи строго так, как указано в ГЛОССАРИИ ниже. Если термин есть в глоссарии — используй ровно его перевод, без синонимов.",
            "3. Собственные имена, названия компаний и продуктов не переводи; при первом упоминании можно оставить оригинал в скобках.",
            "4. Числа, даты, единицы измерения, ссылки и обозначения сохраняй без изменений.",
            "5. Сохраняй разметку внутри блока: **жирный**, *курсив*, `код`, HTML-теги.",
            "6. Не добавляй пояснений, заголовков, вступлений, комментариев, маркеров «Перевод:».",
            "7. Регистр деловой, без обращения «ты».",
            "",
            "[ГЛОССАРИЙ]",
        ]
        lines.append(contentsOf: pairLines)
        lines.append("")
        lines.append(contentsOf: [
            "[ЗАДАЧА]",
            "Переведи \(count) блоков ниже. Верни ровно один JSON-объект, без markdown-обрамления и без текста вокруг:",
            "{\"translations\": [\"<перевод блока 1>\", \"<перевод блока 2>\", …], \"glossary\": [{\"term\": \"<термин>\", \"translation\": \"<перевод>\", \"note\": \"<необязательно>\"}]}",
            "",
            "Требования:",
            "- В translations ровно \(count) строк, порядок совпадает с порядком входных блоков.",
            "- Перенос строки внутри блока экранируй как \\n, кавычки — как \\\".",
            "- Пустой блок переводи как пустую строку.",
            "- glossary: только новые термины, аббревиатуры, названия методологий и устойчивые словосочетания из этих блоков, которых нет в глоссарии выше; максимум 15 записей; если новых нет — [].",
            "",
            "[БЛОКИ]",
            blocksJSON,
        ])
        return lines.joined(separator: "\n")
    }

    /// Reads the `[БЛОКИ]` array back out of a built prompt.
    ///
    /// The prompt layout is this type's contract, so its inverse lives here too:
    /// the mock translator and the integration tests both need it, and reading a
    /// prompt back is what proves the JSON escaping round-trips.
    ///
    /// The `[БЛОКИ]` marker is preferred, with a fall back to the last line that
    /// decodes as a string array — a retry prompt appends a reminder after the
    /// blocks, so "the last line" is not the blocks there.
    public static func blockTexts(in prompt: String) -> [String]? {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
        if let marker = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[БЛОКИ]"
        }) {
            let next = lines.index(after: marker)
            if next < lines.endIndex, let decoded = decodeBlockLine(String(lines[next])) {
                return decoded
            }
        }
        for line in lines.reversed() {
            if let decoded = decodeBlockLine(String(line)) { return decoded }
        }
        return nil
    }

    private static func decodeBlockLine(_ line: String) -> [String]? {
        guard line.hasPrefix("["), let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Lookahead terminology extraction for one batch.
    public static func termExtractionPrompt(units: [PlanUnit]) -> String {
        let fragment = units.map(\.text).joined(separator: "\n\n")
        return [
            "[ИНСТРУКЦИЯ]",
            "Ты терминологический редактор деловой литературы. Из фрагмента книги ниже выдели термины, аббревиатуры, названия методологий, метрик и устойчивых словосочетаний, для которых важно единообразие перевода на русский.",
            "",
            "[ЗАДАЧА]",
            "Верни ровно один JSON-объект, без markdown-обрамления:",
            "{\"glossary\": [{\"term\": \"<термин>\", \"translation\": \"<рекомендуемый перевод>\", \"note\": \"<необязательно>\"}]}",
            "",
            "Требования:",
            "- 10–25 записей, отсортированных по важности.",
            "- Только значимые для деловой литературы термины; бытовые слова не включай.",
            "- Перевод — в той форме, в которой он должен стоять в тексте.",
            "",
            "[ФРАГМЕНТ]",
            fragment,
        ].joined(separator: "\n")
    }

    /// Appends `retrySuffix`; used for the single retry after an unparsable answer.
    public static func retry(_ prompt: String) -> String {
        prompt + retrySuffix
    }

    /// Text rendered for the `[ГЛОССАРИЙ]` section, honouring `glossaryCharLimit`.
    ///
    /// Returns only the `<term> → <translation>` pair lines (no header); the
    /// caller places them under the `[ГЛОССАРИЙ]` header. Empty glossary → `""`.
    public static func glossarySection(_ glossary: Glossary, currentText: String, previousText: String) -> String {
        let full = pairText(for: glossary.terms)
        guard full.count > glossaryCharLimit else { return full }
        let matched = glossary.terms.filter {
            containsWholeWord($0.term, in: currentText) || containsWholeWord($0.term, in: previousText)
        }
        let chosen: [GlossaryTerm]
        if matched.isEmpty {
            chosen = Array(ranked(glossary.terms).prefix(maxGlossaryTerms))
        } else {
            chosen = Array(ranked(matched).prefix(maxGlossaryTerms))
        }
        return pairText(for: chosen)
    }

    // MARK: - Helpers

    private static func pairText(for terms: [GlossaryTerm]) -> String {
        terms.map { "\($0.term) → \($0.translation)" }.joined(separator: "\n")
    }

    private static func ranked(_ terms: [GlossaryTerm]) -> [GlossaryTerm] {
        terms.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.term < $1.term
        }
    }

    /// Case-insensitive substring search where the match must not be adjacent
    /// to another letter or digit on either side.
    private static func containsWholeWord(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        let needle = term.lowercased()
        let haystack = text.lowercased()
        var searchFrom = haystack.startIndex
        while searchFrom < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
            let beforeOK: Bool = {
                guard range.lowerBound != haystack.startIndex else { return true }
                return !isWordChar(haystack[haystack.index(before: range.lowerBound)])
            }()
            let afterOK: Bool = {
                guard range.upperBound != haystack.endIndex else { return true }
                return !isWordChar(haystack[range.upperBound])
            }()
            if beforeOK && afterOK { return true }
            searchFrom = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
