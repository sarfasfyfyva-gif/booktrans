import Foundation

public struct BlockExtractionResult: Sendable {
    public var blocks: [Block]
    /// First heading found, used as a chapter title when the table of contents
    /// does not name the document.
    public var firstHeading: String?
    public var warnings: [String]

    public init(blocks: [Block] = [], firstHeading: String? = nil, warnings: [String] = []) {
        self.blocks = blocks
        self.firstHeading = firstHeading
        self.warnings = warnings
    }
}

/// Turns an XHTML/HTML document into ordered `Block`s.
///
/// The model is deliberately flat: the reader renders a list of paragraphs, so
/// nesting is resolved here rather than in the WebView. Two rules make the
/// result usable:
///
/// * blocking elements open a context; text accumulates in the innermost one;
///   opening a nested block flushes the parent's pending text first, which keeps
///   blocks in document order for shapes like `<li>a<ul><li>b</li></ul></li>`;
/// * `<table>` is captured verbatim as raw markup and never translated, because
///   cell text without structure is meaningless to both the model and the reader.
public struct HTMLBlockExtractor {
    public struct Options {
        /// Maps an `<img src>` (as written in the document) to a stored image
        /// reference such as `images/ab12.jpg`. Nil result means "skip".
        public var imageResolver: (@Sendable (String) -> String?)?
        /// Id assigned to the first emitted block.
        public var firstBlockID: Int = 0
        /// Receives non-fatal problems (missing images, unknown encodings).
        public var onWarning: (@Sendable (String) -> Void)?

        public init(
            imageResolver: (@Sendable (String) -> String?)? = nil,
            firstBlockID: Int = 0,
            onWarning: (@Sendable (String) -> Void)? = nil
        ) {
            self.imageResolver = imageResolver
            self.firstBlockID = firstBlockID
            self.onWarning = onWarning
        }
    }

    /// Elements that start a block and therefore end the previous one.
    public static let blockingElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote",
        "dd", "dt", "pre", "figcaption", "section", "article", "aside",
        "header", "footer", "figure", "address", "caption",
    ]

    /// Elements whose content is discarded entirely.
    private static let skippedElements: Set<String> = ["script", "style", "head", "noscript", "template"]

    /// Elements kept inside a block, with the tag name emitted to the reader.
    private static let inlineElements: [String: String] = [
        "em": "em", "i": "em", "strong": "strong", "b": "strong",
        "s": "s", "del": "s", "strike": "s",
        "code": "code", "kbd": "code", "samp": "code", "tt": "code", "var": "code",
        "sup": "sup", "sub": "sub",
        "a": "a", "span": "span", "u": "u", "ins": "u", "mark": "mark",
        "small": "small", "big": "big", "cite": "cite", "q": "q", "abbr": "abbr",
    ]

    /// Attributes worth keeping on inline elements.
    private static let keptAttributes: [String: Set<String>] = [
        "a": ["href", "title"],
    ]

    public static func extract(_ markup: String, options: Options = Options()) -> BlockExtractionResult {
        var state = State(options: options)
        var tokenizer = MarkupTokenizer(markup)
        while let token = tokenizer.next() {
            state.handle(token)
        }
        state.finish()
        return BlockExtractionResult(
            blocks: state.blocks,
            firstHeading: state.firstHeading,
            warnings: state.warnings)
    }

    // MARK: - State machine

    private struct BlockContext {
        var element: String
        var kind: BlockKind
        var html: String = ""
        var text: String = ""
        /// True when the context came from a bare text run rather than an element.
        var isImplicit: Bool = false
    }

    private struct State {
        let options: Options
        var blocks: [Block] = []
        var warnings: [String] = []
        var firstHeading: String?
        var nextBlockID: Int

        private var contexts: [BlockContext] = []
        private var elementStack: [String] = []
        private var skipStack: [String] = []
        private var tableDepth = 0
        private var tableRaw = ""

        init(options: Options) {
            self.options = options
            self.nextBlockID = options.firstBlockID
        }

        mutating func handle(_ token: MarkupToken) {
            // Inside a table everything is captured verbatim.
            if tableDepth > 0 {
                captureTable(token)
                return
            }
            // Inside script/style/head nothing is kept.
            if !skipStack.isEmpty {
                handleSkipped(token)
                return
            }

            switch token.kind {
            case .start(let tag):
                handleStart(tag, raw: token.raw)
            case .end(let name):
                handleEnd(name)
            case .text(let value):
                if contexts.isEmpty {
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contexts.append(BlockContext(element: "", kind: .paragraph, isImplicit: true))
                        appendText(value)
                    }
                } else {
                    appendText(value)
                }
            case .cdata(let value):
                appendText(value)
            case .comment, .processingInstruction, .doctype:
                break
            }
        }

        // MARK: Tables

        private mutating func captureTable(_ token: MarkupToken) {
            switch token.kind {
            case .start(let tag):
                if tag.name == "table" { tableDepth += 1 }
                tableRaw += token.raw
            case .end(let name):
                if name == "table" {
                    tableDepth -= 1
                    tableRaw += token.raw
                    if tableDepth == 0 {
                        emitTable()
                    }
                    return
                }
                tableRaw += token.raw
            default:
                tableRaw += token.raw
            }
        }

        // MARK: Skipped content

        private mutating func handleSkipped(_ token: MarkupToken) {
            switch token.kind {
            case .start(let tag):
                if MarkupTokenizer.voidElements.contains(tag.name) { return }
                if !tag.selfClosing { skipStack.append(tag.name) }
            case .end(let name):
                if let index = skipStack.lastIndex(of: name) {
                    skipStack.removeSubrange(index...)
                }
            default:
                break
            }
        }

        // MARK: Start tags

        private mutating func handleStart(_ tag: MarkupTag, raw: String) {
            if HTMLBlockExtractor.skippedElements.contains(tag.name) {
                if !tag.selfClosing, !MarkupTokenizer.voidElements.contains(tag.name) {
                    skipStack.append(tag.name)
                }
                return
            }
            if tag.name == "table" {
                if isVoidSelfClosing(tag) { return }
                tableDepth = 1
                tableRaw = raw
                return
            }
            if tag.name == "hr" {
                flushContext()
                emit(kind: .hr, html: "", text: "")
                return
            }
            if tag.name == "img" {
                flushContext()
                handleImage(tag)
                return
            }
            if let inlineName = HTMLBlockExtractor.inlineElements[tag.name] {
                elementStack.append(tag.name)
                if !tag.selfClosing, !MarkupTokenizer.voidElements.contains(tag.name) {
                    appendInlineOpen(tag, emittedName: inlineName)
                }
                return
            }
            if HTMLBlockExtractor.blockingElements.contains(tag.name) {
                if isVoidSelfClosing(tag) { return }
                // Preserve document order: a nested block ends the parent's text.
                flushContext()
                contexts.append(BlockContext(element: tag.name, kind: kind(for: tag.name)))
                elementStack.append(tag.name)
                return
            }
            if tag.name == "br" {
                appendInline("<br/>")
                return
            }
            // Containers (body, ul, ol, table wrappers, unknown tags) are
            // transparent: they are tracked only so end tags can be matched.
            if !(tag.selfClosing || MarkupTokenizer.voidElements.contains(tag.name)) {
                elementStack.append(tag.name)
            }
        }

        // MARK: End tags

        private mutating func handleEnd(_ name: String) {
            if HTMLBlockExtractor.inlineElements[name] != nil {
                let emitted = HTMLBlockExtractor.inlineElements[name]!
                appendInline("</\(emitted)>")
                if let index = elementStack.lastIndex(of: name) {
                    elementStack.removeSubrange(index...)
                }
                return
            }
            if let index = contexts.lastIndex(where: { $0.element == name }) {
                // Close this context and anything nested inside it.
                while contexts.count > index {
                    flushContext()
                }
            }
            if let index = elementStack.lastIndex(of: name) {
                elementStack.removeSubrange(index...)
            }
        }

        // MARK: Text

        private mutating func appendText(_ value: String) {
            guard !contexts.isEmpty else { return }
            contexts[contexts.count - 1].text += value
            contexts[contexts.count - 1].html += Block.escape(value)
        }

        private mutating func appendInline(_ markup: String) {
            guard !contexts.isEmpty else { return }
            contexts[contexts.count - 1].html += markup
        }

        private mutating func appendInlineOpen(_ tag: MarkupTag, emittedName: String) {
            var markup = "<\(emittedName)"
            let allowed = HTMLBlockExtractor.keptAttributes[tag.name] ?? []
            for key in allowed.sorted() {
                guard let value = tag.attributes[key] else { continue }
                markup += " \(key)=\"\(escapeAttribute(value))\""
            }
            markup += ">"
            appendInline(markup)
        }

        private func escapeAttribute(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        // MARK: Images

        private mutating func handleImage(_ tag: MarkupTag) {
            guard let source = tag.attributes["src"] ?? tag.attributes["xlink:href"] else { return }
            guard let resolver = options.imageResolver else { return }
            guard let reference = resolver(source) else {
                warn("missing image \(source)")
                return
            }
            emit(kind: .image, html: "", text: "", imageRef: reference)
        }

        // MARK: Emission

        private mutating func flushContext() {
            guard let context = contexts.popLast() else { return }
            let text = Self.collapseWhitespace(HTMLEntities.decode(context.text))
            let html = context.html.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !html.isEmpty else { return }
            if context.kind == .heading, firstHeading == nil, !text.isEmpty {
                firstHeading = text
            }
            emit(kind: context.kind, html: html.isEmpty ? Block.escape(text) : html, text: text)
        }

        mutating func finish() {
            while !contexts.isEmpty {
                flushContext()
            }
        }

        private mutating func emit(kind: BlockKind, html: String, text: String, imageRef: String? = nil) {
            if kind == .hr && blocks.last?.kind == .hr { return }
            let block = Block(id: nextBlockID, kind: kind, text: text,
                              html: html, rawHTML: nil, imageRef: imageRef)
            nextBlockID += 1
            blocks.append(block)
        }

        private mutating func emitTable() {
            let raw = tableRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            tableRaw = ""
            guard !raw.isEmpty else { return }
            flushContext()
            let block = Block(id: nextBlockID, kind: .table, text: "",
                              html: "", rawHTML: raw, imageRef: nil)
            nextBlockID += 1
            blocks.append(block)
        }

        private func warn(_ message: String) {
            options.onWarning?(message)
        }

        // MARK: Helpers

        private func isVoidSelfClosing(_ tag: MarkupTag) -> Bool {
            tag.selfClosing || MarkupTokenizer.voidElements.contains(tag.name)
        }

        private func kind(for element: String) -> BlockKind {
            switch element {
            case "h1", "h2", "h3", "h4", "h5", "h6": return .heading
            case "li": return .listItem
            case "blockquote": return .blockquote
            default: return .paragraph
            }
        }

        /// Collapses every run of whitespace (including non-breaking spaces,
        /// which are only a typographic device in source markup) to one space.
        static func collapseWhitespace(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.count)
            var pendingSpace = false
            for character in text {
                if character.isWhitespace || character == "\u{00A0}" || character == "\u{200B}" {
                    pendingSpace = !out.isEmpty
                    continue
                }
                if pendingSpace {
                    out.append(" ")
                    pendingSpace = false
                }
                out.append(character)
            }
            return out
        }
    }
}
