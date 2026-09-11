import Foundation

public struct FB2Image: Sendable, Hashable {
    public var id: String
    public var contentType: String
    public var base64: String
}

public struct FB2ParseResult: Sendable {
    public var title: String
    public var author: String
    public var language: String
    /// Id of the `<binary>` referenced by `<coverpage>`, when present.
    public var coverImageID: String?
    public var chapters: [Chapter]
    public var images: [FB2Image]
    public var warnings: [String]
    public var encodingName: String
}

public enum FB2ParserError: LocalizedError {
    case undecodable
    case notFB2(reason: String)

    public var errorDescription: String? {
        switch self {
        case .undecodable:
            return "Не удалось определить кодировку файла FB2."
        case .notFB2(let reason):
            return "Файл не похож на FB2: \(reason)"
        }
    }
}

/// Parses FictionBook 2.
///
/// Uses the tolerant `MarkupTokenizer` rather than `XMLParser`: FB2 libraries are
/// full of files that are not well-formed (a raw `&` in text, unclosed tags,
/// windows-1251 declared as UTF-8) yet perfectly readable. Structure is validated
/// instead — a file with no chapter containing translatable text is rejected as
/// "not FB2".
///
/// Images are the one ordering trap: `<binary>` elements follow `<body>`, so
/// `<image>` references are recorded by binary id during the body pass and
/// resolved once the binaries have been read.
public enum FB2Parser {
    /// Elements inside `<body>` that produce a translated block.
    private static let blockKinds: [String: BlockKind] = [
        "p": .paragraph,
        "v": .paragraph,
        "cite": .paragraph,
        "text-author": .paragraph,
        "subtitle": .heading,
        "title": .heading,
    ]

    private static let inlineElements: [String: String] = [
        "emphasis": "em", "strong": "strong", "strikethrough": "s",
        "code": "code", "sup": "sup", "sub": "sub", "a": "a", "style": "span",
    ]

    // MARK: - Entry points

    public static func parse(data: Data) throws -> FB2ParseResult {
        guard let decoded = EncodingDetect.decode(data) else {
            throw FB2ParserError.undecodable
        }
        var result = try parse(text: decoded.text, encodingName: decoded.encodingName)
        result.warnings.insert("кодировка: \(decoded.encodingName)", at: 0)
        return result
    }

    public static func parse(text: String, encodingName: String = "utf-8") throws -> FB2ParseResult {
        var state = State()
        var tokenizer = MarkupTokenizer(text)
        while let token = tokenizer.next() {
            state.handle(token)
        }
        state.finish()
        return try state.result(encodingName: encodingName)
    }

    // MARK: - State machine

    private struct BlockContext {
        var element: String
        var kind: BlockKind
        var html: String = ""
        var text: String = ""
    }

    private struct ChapterAccumulator {
        var blocks: [Block] = []
        var isNotes: Bool = false
    }

    private struct State {
        // Results
        var warnings: [String] = []
        var images: [FB2Image] = []
        var chapters: [Chapter] = []
        var notesChapters: [Chapter] = []

        // Description
        var descriptionDepth = 0
        var titleInfoDepth = 0
        var coverpageDepth = 0
        var bookTitle = ""
        var language = ""
        var authors: [String] = []
        var currentAuthor: [String] = []
        var textBuffer = ""
        var currentField: String?
        var coverImageID: String?

        // Bodies
        var bodyDepth = 0
        var sectionDepth = 0
        var inNotesBody = false
        var currentChapter: ChapterAccumulator?

        // Blocks
        var contexts: [BlockContext] = []
        var elementStack: [String] = []
        var nextBlockID = 0
        /// block id → `<binary>` id, resolved in `finish()`.
        var pendingImageIDs: [Int: String] = [:]

        // Tables
        var tableDepth = 0
        var tableRaw = ""

        // Binaries
        var binaryID: String?
        var binaryType = ""
        var binaryBuffer = ""

        // MARK: Dispatch

        mutating func handle(_ token: MarkupToken) {
            if binaryID != nil {
                handleBinary(token)
                return
            }
            if tableDepth > 0 {
                handleTable(token)
                return
            }
            if titleInfoDepth > 0 || descriptionDepth > 0 {
                handleMetadata(token)
                return
            }

            switch token.kind {
            case .start(let tag):
                handleStart(tag, raw: token.raw)
            case .end(let name):
                handleEnd(name)
            case .text(let value), .cdata(let value):
                handleText(value)
            case .comment, .processingInstruction, .doctype:
                break
            }
        }

        // MARK: Binaries

        private mutating func handleBinary(_ token: MarkupToken) {
            switch token.kind {
            case .text(let value):
                binaryBuffer += value.filter { !$0.isWhitespace }
            case .end(let name):
                guard name == "binary" else { return }
                if let id = binaryID, !binaryBuffer.isEmpty {
                    images.append(FB2Image(id: id, contentType: binaryType, base64: binaryBuffer))
                } else if let id = binaryID {
                    warn("binary \(id) is empty")
                }
                binaryID = nil
                binaryBuffer = ""
                binaryType = ""
            default:
                break
            }
        }

        // MARK: Tables

        private mutating func handleTable(_ token: MarkupToken) {
            if case .end(let name) = token.kind, name == "table" {
                tableDepth -= 1
                tableRaw += token.raw
                if tableDepth == 0 {
                    let raw = tableRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    tableRaw = ""
                    if !raw.isEmpty {
                        closeBlock()
                        appendBlock(Block(id: nextBlockID, kind: .table, text: "", html: "",
                                          rawHTML: raw, imageRef: nil))
                    }
                }
                return
            }
            if case .start(let tag) = token.kind, tag.name == "table" {
                tableDepth += 1
            }
            tableRaw += token.raw
        }

        // MARK: Metadata

        private mutating func handleMetadata(_ token: MarkupToken) {
            switch token.kind {
            case .start(let tag):
                handleMetadataStart(tag)
            case .end(let name):
                handleMetadataEnd(name)
            case .text(let value), .cdata(let value):
                if currentField != nil { textBuffer += value }
            case .comment, .processingInstruction, .doctype:
                break
            }
        }

        private mutating func handleMetadataStart(_ tag: MarkupTag) {
            switch tag.name {
            case "description":
                descriptionDepth += 1
            case "title-info":
                titleInfoDepth += 1
                pushElement(tag)
            case "coverpage":
                coverpageDepth += 1
                pushElement(tag)
            case "cover-image", "image":
                if coverpageDepth > 0, let href = tag.attributes["href"] {
                    coverImageID = FB2Parser.stripHash(href)
                }
            case "author":
                currentAuthor = []
                pushElement(tag)
            case "book-title", "lang", "first-name", "middle-name", "last-name", "nickname":
                textBuffer = ""
                currentField = tag.name
            default:
                pushElement(tag)
            }
        }

        private mutating func handleMetadataEnd(_ name: String) {
            switch name {
            case "description":
                descriptionDepth = max(0, descriptionDepth - 1)
            case "title-info":
                titleInfoDepth = max(0, titleInfoDepth - 1)
            case "coverpage":
                coverpageDepth = max(0, coverpageDepth - 1)
            case "author":
                let parts = currentAuthor.filter { !$0.isEmpty }
                if !parts.isEmpty, titleInfoDepth > 0 {
                    authors.append(parts.joined(separator: " "))
                }
                currentAuthor = []
            case "book-title":
                if titleInfoDepth > 0 { bookTitle = textBuffer }
                textBuffer = ""
                currentField = nil
            case "lang":
                if titleInfoDepth > 0 { language = textBuffer }
                textBuffer = ""
                currentField = nil
            case "first-name", "middle-name", "last-name", "nickname":
                if titleInfoDepth > 0, !textBuffer.isEmpty { currentAuthor.append(textBuffer) }
                textBuffer = ""
                currentField = nil
            default:
                break
            }
            popElement(name)
        }

        // MARK: Body

        private mutating func handleStart(_ tag: MarkupTag, raw: String) {
            let name = tag.name

            if name == "binary" {
                binaryID = tag.attributes["id"] ?? ""
                binaryType = tag.attributes["content-type"] ?? ""
                binaryBuffer = ""
                return
            }

            if name == "description" || name == "title-info" {
                handleMetadataStart(tag)
                return
            }

            switch name {
            case "body":
                bodyDepth += 1
                inNotesBody = (tag.attributes["name"]?.lowercased() == "notes")
                pushElement(tag)
                return
            case "section":
                if sectionDepth == 0, bodyDepth > 0 { startChapter() }
                sectionDepth += 1
                pushElement(tag)
                return
            case "table":
                guard !tag.selfClosing else { return }
                closeBlock()
                tableDepth = 1
                tableRaw = raw
                return
            case "empty-line":
                return
            case "image":
                closeBlock()
                handleImage(tag)
                return
            case "hr":
                closeBlock()
                appendBlock(Block(id: nextBlockID, kind: .hr, text: "", html: ""))
                return
            default:
                break
            }

            if let kind = FB2Parser.blockKinds[name] {
                guard !tag.selfClosing else { return }
                // A heading often wraps its lines in <p>, and those paragraphs
                // are part of the heading rather than body text.
                let inherited = inheritedKind(for: name)
                // A new block ends the previous one, which keeps the block list
                // in document order for shapes like <title><p>…</p></title>.
                closeBlock()
                ensureChapter()
                contexts.append(BlockContext(element: name, kind: inherited ?? kind))
                elementStack.append(name)
                return
            }

            if let inlineName = FB2Parser.inlineElements[name] {
                guard !tag.selfClosing else { return }
                var markup = "<\(inlineName)"
                if inlineName == "a", let href = tag.attributes["href"] {
                    markup += " href=\"\(escapeAttribute(href))\""
                }
                markup += ">"
                appendInline(markup)
                elementStack.append(name)
                return
            }

            // Containers: epigraph, poem, stanza, annotation body, unknown tags.
            pushElement(tag)
        }

        private mutating func handleEnd(_ name: String) {
            if let inlineName = FB2Parser.inlineElements[name] {
                appendInline("</\(inlineName)>")
                popElement(name)
                return
            }

            if FB2Parser.blockKinds[name] != nil {
                if let index = contexts.lastIndex(where: { $0.element == name }) {
                    while contexts.count > index { closeBlock() }
                }
                popElement(name)
                return
            }

            switch name {
            case "section":
                while !contexts.isEmpty { closeBlock() }
                sectionDepth = max(0, sectionDepth - 1)
                if sectionDepth == 0 { finishChapter() }
            case "body":
                while !contexts.isEmpty { closeBlock() }
                bodyDepth = max(0, bodyDepth - 1)
                finishChapter()
            default:
                break
            }
            popElement(name)
        }

        private mutating func handleText(_ value: String) {
            if !contexts.isEmpty {
                contexts[contexts.count - 1].text += value
                contexts[contexts.count - 1].html += Block.escape(value)
                return
            }
            guard bodyDepth > 0, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            // Bare text directly inside <body>: keep it as a paragraph.
            ensureChapter()
            contexts.append(BlockContext(element: "", kind: .paragraph))
            contexts[contexts.count - 1].text += value
            contexts[contexts.count - 1].html += Block.escape(value)
        }

        /// `<p>` and `<v>` inside a `<title>` or `<subtitle>` continue that heading.
        private func inheritedKind(for element: String) -> BlockKind? {
            guard element == "p" || element == "v" else { return nil }
            guard let parent = contexts.last else { return nil }
            guard parent.element == "title" || parent.element == "subtitle" else { return nil }
            return parent.kind
        }

        private mutating func handleImage(_ tag: MarkupTag) {
            guard let href = tag.attributes["href"] else { return }
            let binaryID = FB2Parser.stripHash(href)
            ensureChapter()
            let blockID = nextBlockID
            appendBlock(Block(id: blockID, kind: .image, text: "", html: "", imageRef: nil))
            pendingImageIDs[blockID] = binaryID
        }

        // MARK: Chapter lifecycle

        private mutating func startChapter() {
            if let existing = currentChapter {
                // A body-level <title> belongs to the section that follows it, so
                // a chapter holding nothing but that heading is reused rather
                // than finished.
                let onlyHeading = existing.blocks.count == 1 && existing.blocks[0].kind == .heading
                if !onlyHeading { finishChapter() }
                return
            }
            currentChapter = ChapterAccumulator(isNotes: inNotesBody)
        }

        private mutating func ensureChapter() {
            if currentChapter == nil, bodyDepth > 0 {
                currentChapter = ChapterAccumulator(isNotes: inNotesBody)
            }
        }

        private mutating func finishChapter() {
            guard let chapter = currentChapter else { return }
            currentChapter = nil
            guard !chapter.blocks.isEmpty else { return }
            let heading = chapter.blocks.first { $0.kind == .heading }?.text
            let title = heading.flatMap { $0.isEmpty ? nil : $0 }
                ?? (chapter.isNotes ? "Примечания" : "Без названия")
            let result = Chapter(index: 0, title: title, docHref: "", blocks: chapter.blocks)
            if chapter.isNotes {
                notesChapters.append(result)
            } else {
                chapters.append(result)
            }
        }

        private mutating func appendBlock(_ block: Block) {
            guard currentChapter != nil else { return }
            currentChapter?.blocks.append(block)
            nextBlockID += 1
        }

        private mutating func closeBlock() {
            guard let context = contexts.popLast() else { return }
            let text = collapse(context.text)
            let html = context.html.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !html.isEmpty else { return }
            appendBlock(Block(id: nextBlockID, kind: context.kind, text: text,
                              html: html.isEmpty ? Block.escape(text) : html))
        }

        private mutating func appendInline(_ markup: String) {
            guard !contexts.isEmpty else { return }
            contexts[contexts.count - 1].html += markup
        }

        // MARK: Finish

        mutating func finish() {
            while !contexts.isEmpty { closeBlock() }
            finishChapter()
            resolveImageReferences()
            for index in chapters.indices {
                chapters[index].index = index
            }
            let base = chapters.count
            for offset in notesChapters.indices {
                notesChapters[offset].index = base + offset
            }
        }

        /// `<binary>` elements come after `<body>`, so image blocks can only be
        /// pointed at real files once the whole document has been read.
        private mutating func resolveImageReferences() {
            guard !pendingImageIDs.isEmpty else { return }

            func resolve(_ blocks: inout [Block], images: [FB2Image], warn: (String) -> Void) {
                for index in blocks.indices where blocks[index].kind == .image {
                    guard let binaryID = pendingImageIDs[blocks[index].id] else { continue }
                    guard let image = images.first(where: { $0.id == binaryID }) else {
                        warn("missing image \(binaryID)")
                        continue
                    }
                    blocks[index].imageRef = BookPaths.imageRef(fileName: FB2Parser.fileName(for: image))
                }
            }

            var warnings = self.warnings
            for index in chapters.indices {
                resolve(&chapters[index].blocks, images: images) { warnings.append($0) }
            }
            for index in notesChapters.indices {
                resolve(&notesChapters[index].blocks, images: images) { warnings.append($0) }
            }
            self.warnings = warnings
        }

        func result(encodingName: String) throws -> FB2ParseResult {
            let allChapters = chapters + notesChapters
            let hasTranslatableText = allChapters.contains { chapter in
                chapter.blocks.contains { $0.kind.isTranslatable && !$0.text.isEmpty }
            }
            guard !allChapters.isEmpty, hasTranslatableText else {
                throw FB2ParserError.notFB2(reason: "не найдено ни одной главы с переводимым текстом")
            }
            let title = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return FB2ParseResult(
                title: title.isEmpty ? "Без названия" : title,
                author: authors.joined(separator: ", "),
                language: language.lowercased(),
                coverImageID: coverImageID,
                chapters: allChapters,
                images: images,
                warnings: warnings,
                encodingName: encodingName)
        }

        // MARK: Utilities

        private mutating func pushElement(_ tag: MarkupTag) {
            guard !(tag.selfClosing || MarkupTokenizer.voidElements.contains(tag.name)) else { return }
            elementStack.append(tag.name)
        }

        private mutating func popElement(_ name: String) {
            if let index = elementStack.lastIndex(of: name) {
                elementStack.removeSubrange(index...)
            }
        }

        private mutating func warn(_ message: String) {
            warnings.append(message)
        }

        private func collapse(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.count)
            var pendingSpace = false
            for character in text {
                if character.isWhitespace || character == "\u{00A0}" {
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

        private func escapeAttribute(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    // MARK: - Helpers

    public static func stripHash(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()) : value
    }

    /// File name for a `<binary>` in `parsed/images`.
    public static func fileName(for image: FB2Image) -> String {
        let extensionName = fileExtension(for: image)
        let base = sanitize(image.id)
        let stem = base.lowercased().hasSuffix(".\(extensionName)")
            ? String(base.dropLast(extensionName.count + 1))
            : base
        return "\(stem).\(extensionName)"
    }

    public static func fileExtension(for image: FB2Image) -> String {
        switch image.contentType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/bmp": return "bmp"
        default:
            let fromID = (image.id as NSString).pathExtension.lowercased()
            return fromID.isEmpty ? "jpg" : fromID
        }
    }

    /// Keeps ids that are used as file names from escaping the images directory.
    public static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var out = ""
        for character in name {
            out.append(allowed.contains(character) ? character : "_")
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "image" : trimmed
    }
}
