import Foundation

public struct MarkupTag: Equatable, Sendable {
    /// Lowercased local name, with any namespace prefix stripped.
    public var name: String
    public var attributes: [String: String]
    public var selfClosing: Bool

    public init(name: String, attributes: [String: String] = [:], selfClosing: Bool = false) {
        self.name = name
        self.attributes = attributes
        self.selfClosing = selfClosing
    }
}

public struct MarkupToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case start(MarkupTag)
        case end(String)
        case text(String)
        case cdata(String)
        case comment
        case processingInstruction
        case doctype
    }

    public var kind: Kind
    /// Verbatim source slice, used to reproduce raw markup (tables).
    public var raw: String
}

/// A tolerant tokenizer for XML and HTML.
///
/// FB2 files in the wild are frequently not well-formed — unescaped ampersands,
/// mismatched tags, HTML-only void elements inside XML — and EPUB XHTML often
/// uses HTML entities that are not declared. A strict parser (XMLParser) rejects
/// those outright, which would turn a readable book into an import error. This
/// tokenizer accepts anything and reports what it saw; the callers decide what
/// to do with it.
public struct MarkupTokenizer: Sendable {
    /// Elements that never have a closing tag.
    public static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    private let text: String
    private var index: String.Index

    public init(_ text: String) {
        self.text = text
        self.index = text.startIndex
    }

    public mutating func next() -> MarkupToken? {
        guard index < text.endIndex else { return nil }
        if text[index] == "<" {
            return nextTag()
        }
        return nextText()
    }

    // MARK: - Text

    private mutating func nextText() -> MarkupToken? {
        let start = index
        while index < text.endIndex, text[index] != "<" {
            index = text.index(after: index)
        }
        guard start < index else { return nil }
        let raw = String(text[start..<index])
        return MarkupToken(kind: .text(HTMLEntities.decode(raw)), raw: raw)
    }

    // MARK: - Tags

    private mutating func nextTag() -> MarkupToken? {
        let start = index
        let rest = text[start...]

        if rest.hasPrefix("<!--") {
            let contentStart = text.index(start, offsetBy: 4)
            if let close = text.range(of: "-->", range: contentStart..<text.endIndex) {
                index = close.upperBound
            } else {
                index = text.endIndex
            }
            return MarkupToken(kind: .comment, raw: String(text[start..<index]))
        }
        if rest.hasPrefix("<![CDATA[") {
            let contentStart = text.index(start, offsetBy: 9)
            if let close = text.range(of: "]]>", range: contentStart..<text.endIndex) {
                let content = String(text[contentStart..<close.lowerBound])
                index = close.upperBound
                return MarkupToken(kind: .cdata(content), raw: String(text[start..<index]))
            }
            let content = String(text[contentStart...])
            index = text.endIndex
            return MarkupToken(kind: .cdata(content), raw: String(text[start...]))
        }
        if rest.hasPrefix("<?") {
            let contentStart = text.index(start, offsetBy: 2)
            if let close = text.range(of: "?>", range: contentStart..<text.endIndex) {
                index = close.upperBound
            } else {
                index = text.endIndex
            }
            return MarkupToken(kind: .processingInstruction, raw: String(text[start..<index]))
        }
        if rest.hasPrefix("<!") {
            let contentStart = text.index(start, offsetBy: 2)
            if let close = text.range(of: ">", range: contentStart..<text.endIndex) {
                index = close.upperBound
            } else {
                index = text.endIndex
            }
            return MarkupToken(kind: .doctype, raw: String(text[start..<index]))
        }

        // `<name ...>` or `</name>`
        var cursor = text.index(after: start)
        let isEnd = cursor < text.endIndex && text[cursor] == "/"
        if isEnd { cursor = text.index(after: cursor) }

        var name = ""
        while cursor < text.endIndex, isNameCharacter(text[cursor]) {
            name.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        guard !name.isEmpty else {
            // A stray `<` — report it as text and move on.
            index = text.index(after: start)
            return MarkupToken(kind: .text("<"), raw: "<")
        }

        if isEnd {
            if let close = text.range(of: ">", range: cursor..<text.endIndex) {
                index = close.upperBound
            } else {
                index = text.endIndex
            }
            return MarkupToken(kind: .end(normalize(name)), raw: String(text[start..<index]))
        }

        let (attributes, closed, tagEnd) = parseAttributes(from: cursor)
        index = tagEnd
        let tag = MarkupTag(name: normalize(name), attributes: attributes, selfClosing: closed)
        return MarkupToken(kind: .start(tag), raw: String(text[start..<index]))
    }

    /// Parses ` name="value"` pairs up to and including the closing `>`.
    private func parseAttributes(from start: String.Index) -> ([String: String], Bool, String.Index) {
        var attributes: [String: String] = [:]
        var cursor = start
        var selfClosing = false

        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }
            if text[cursor] == ">" {
                cursor = text.index(after: cursor)
                break
            }
            if text[cursor] == "/" {
                selfClosing = true
                cursor = text.index(after: cursor)
                continue
            }

            var name = ""
            while cursor < text.endIndex, !text[cursor].isWhitespace,
                  text[cursor] != "=", text[cursor] != ">", text[cursor] != "/" {
                name.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }

            var value = ""
            if cursor < text.endIndex, text[cursor] == "=" {
                cursor = text.index(after: cursor)
                while cursor < text.endIndex, text[cursor].isWhitespace {
                    cursor = text.index(after: cursor)
                }
                if cursor < text.endIndex, text[cursor] == "\"" || text[cursor] == "'" {
                    let quote = text[cursor]
                    cursor = text.index(after: cursor)
                    while cursor < text.endIndex, text[cursor] != quote {
                        value.append(text[cursor])
                        cursor = text.index(after: cursor)
                    }
                    if cursor < text.endIndex { cursor = text.index(after: cursor) }
                } else {
                    while cursor < text.endIndex, !text[cursor].isWhitespace, text[cursor] != ">" {
                        value.append(text[cursor])
                        cursor = text.index(after: cursor)
                    }
                }
            }

            if !name.isEmpty {
                // Keep the first occurrence: duplicated attributes are a
                // malformed-input case where the first one is the real value.
                let key = normalizeAttributeName(name)
                if attributes[key] == nil {
                    attributes[key] = HTMLEntities.decode(value)
                }
            }
        }
        return (attributes, selfClosing, cursor)
    }

    private func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
            || character == ":" || character == "."
    }

    /// `fb:book-title` → `book-title`; also lowercases, which is what both XML
    /// and HTML handling needs.
    private func normalize(_ name: String) -> String {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return local.lowercased()
    }

    private func normalizeAttributeName(_ name: String) -> String {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return local.lowercased()
    }
}
