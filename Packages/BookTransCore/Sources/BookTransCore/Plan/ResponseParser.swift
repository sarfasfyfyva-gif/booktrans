import Foundation

public struct ParsedModelAnswer: Sendable, Equatable {
    public enum Shape: String, Sendable, Equatable { case object, array }
    public var translations: [String]
    public var glossary: [GlossaryAddition]
    public var shape: Shape
    public init(translations: [String], glossary: [GlossaryAddition], shape: Shape) {
        self.translations = translations
        self.glossary = glossary
        self.shape = shape
    }
}

public enum ResponseParserError: LocalizedError, Equatable {
    case wrongTranslationCount(expected: Int, got: Int)
    case unparsable

    public var errorDescription: String? {
        switch self {
        case .wrongTranslationCount(let expected, let got):
            return "Expected \(expected) translations, got \(got)."
        case .unparsable:
            return "unparsable response"
        }
    }
}

public enum ResponseParser {
    public static func parse(_ raw: String, expectedCount: Int) -> Result<ParsedModelAnswer, ResponseParserError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            } else {
                text = ""
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lastCount: Int?

        // Step 2: outermost { … } as {translations, glossary?}.
        if let open = text.firstIndex(of: "{"),
           let close = text.lastIndex(of: "}"),
           open <= close,
           let data = String(text[open...close]).data(using: .utf8),
           let object = try? JSONDecoder().decode(ObjectAnswer.self, from: data) {
            if object.translations.count == expectedCount {
                return .success(ParsedModelAnswer(
                    translations: object.translations,
                    glossary: object.glossary ?? [],
                    shape: .object
                ))
            }
            lastCount = object.translations.count
        }

        // Step 3: first [ … ] with its string-aware matching ].
        if let slice = balancedArraySlice(in: text),
           let data = slice.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            if array.count == expectedCount {
                return .success(ParsedModelAnswer(translations: array, glossary: [], shape: .array))
            }
            lastCount = array.count
        }

        if let got = lastCount {
            return .failure(.wrongTranslationCount(expected: expectedCount, got: got))
        }
        return .failure(.unparsable)
    }

    // MARK: - Helpers

    private struct ObjectAnswer: Decodable {
        var translations: [String]
        var glossary: [GlossaryAddition]?
    }

    /// Returns the substring from the first `[` through its matching `]`,
    /// ignoring brackets inside string literals (backslash escapes honoured).
    private static func balancedArraySlice(in text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
