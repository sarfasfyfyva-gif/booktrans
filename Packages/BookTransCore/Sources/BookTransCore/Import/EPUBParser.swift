import Foundation

public struct EPUBParseResult: Sendable {
    public var title: String
    public var author: String
    public var language: String
    public var chapters: [Chapter]
    /// Relative to the book directory, e.g. `parsed/images/cover.jpg`.
    public var coverPath: String?
    public var warnings: [String]
}

public enum EPUBParserError: LocalizedError {
    case missingContainer
    case missingRootfile(String)
    case manifestMissing(String)
    case noTextDocuments

    public var errorDescription: String? {
        switch self {
        case .missingContainer:
            return "В архиве нет META-INF/container.xml — это не EPUB."
        case .missingRootfile(let path):
            return "Не найден OPF-файл: \(path)"
        case .manifestMissing(let id):
            return "В OPF нет элемента manifest для id «\(id)»."
        case .noTextDocuments:
            return "В EPUB не найдено ни одного текстового документа."
        }
    }
}

/// Parses an unpacked EPUB 2/3 into chapters of blocks.
///
/// Operates on a directory rather than an archive so the whole parser is
/// testable without a zip implementation (docs/SPEC.md §11). Namespace prefixes
/// are stripped by the tokenizer, so `dc:title` and `title` are the same thing
/// here.
public enum EPUBParser {
    public struct Options {
        public var onWarning: ((String) -> Void)?
        public init(onWarning: ((String) -> Void)? = nil) {
            self.onWarning = onWarning
        }
    }

    public static func parse(
        root: URL,
        imagesDirectory: URL,
        options: Options = Options()
    ) throws -> EPUBParseResult {
        var warnings: [String] = []
        let warn: (String) -> Void = { message in
            warnings.append(message)
            options.onWarning?(message)
        }

        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let containerData = FileStore.readData(containerURL) else {
            throw EPUBParserError.missingContainer
        }
        let containerText = EncodingDetect.decode(containerData)?.text
            ?? String(data: containerData, encoding: .utf8) ?? ""
        guard let opfRelative = firstRootfilePath(in: containerText) else {
            throw EPUBParserError.missingRootfile("META-INF/container.xml")
        }
        let opfURL = root.appendingPathComponent(opfRelative).standardizedFileURL
        guard let opfData = FileStore.readData(opfURL) else {
            throw EPUBParserError.missingRootfile(opfRelative)
        }
        let opfText = EncodingDetect.decode(opfData)?.text
            ?? String(data: opfData, encoding: .utf8) ?? ""
        let opf = parseOPF(opfText)

        let opfDirectory = opfURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        // Table of contents: EPUB3 nav first, then EPUB2 NCX.
        var titles: [String: String] = [:]
        if let navItem = opf.manifest.values.first(where: {
            $0.properties.split(separator: " ").contains("nav")
        }) {
            let navURL = opfDirectory.appendingPathComponent(navItem.href).standardizedFileURL
            if let text = readText(navURL) {
                titles.merge(navTOC(text, documentDirectory: navURL.deletingLastPathComponent(),
                                    root: root)) { existing, _ in existing }
            } else {
                warn("nav document not found: \(navItem.href)")
            }
        }
        if let ncxItem = opf.manifest.values.first(where: {
            $0.mediaType == "application/x-dtbncx+xml"
        }) {
            let ncxURL = opfDirectory.appendingPathComponent(ncxItem.href).standardizedFileURL
            if let text = readText(ncxURL) {
                titles.merge(ncxTOC(text, documentDirectory: ncxURL.deletingLastPathComponent(),
                                    root: root)) { existing, _ in existing }
            }
        }

        var chapters: [Chapter] = []
        for (position, idref) in opf.spine.enumerated() {
            guard let item = opf.manifest[idref] else {
                warn("spine references unknown manifest id «\(idref)»")
                continue
            }
            guard isTextDocument(item) else { continue }
            let documentURL = opfDirectory.appendingPathComponent(item.href).standardizedFileURL
            guard let markup = readText(documentURL) else {
                warn("missing spine document \(item.href)")
                continue
            }
            let documentDirectory = documentURL.deletingLastPathComponent()
            let relative = relativePath(from: root, to: documentURL)

            let resolver: (String) -> String? = { source in
                resolveImage(source, documentDirectory: documentDirectory, root: root,
                             imagesDirectory: imagesDirectory, warn: warn)
            }
            let extraction = HTMLBlockExtractor.extract(markup, options: .init(
                imageResolver: resolver,
                firstBlockID: 0,
                onWarning: warn))

            let title = titles[normalizePath(relative)]
                ?? extraction.firstHeading.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Глава \(position + 1)"

            chapters.append(Chapter(index: 0, title: title, docHref: relative,
                                    blocks: extraction.blocks))
        }

        guard !chapters.isEmpty, chapters.contains(where: { chapter in
            chapter.blocks.contains { $0.kind.isTranslatable && !$0.text.isEmpty }
        }) else {
            throw EPUBParserError.noTextDocuments
        }
        for index in chapters.indices { chapters[index].index = index }

        let cover = extractCover(opf: opf, opfDirectory: opfDirectory, root: root,
                                 imagesDirectory: imagesDirectory, warn: warn)

        return EPUBParseResult(
            title: opf.title.isEmpty ? "Без названия" : opf.title,
            author: opf.creator,
            language: opf.language.lowercased(),
            chapters: chapters,
            coverPath: cover,
            warnings: warnings)
    }

    // MARK: - container.xml

    static func firstRootfilePath(in text: String) -> String? {
        var tokenizer = MarkupTokenizer(text)
        while let token = tokenizer.next() {
            if case .start(let tag) = token.kind, tag.name == "rootfile" {
                if let path = tag.attributes["full-path"], !path.isEmpty { return path }
            }
        }
        return nil
    }

    // MARK: - OPF

    struct ManifestItem {
        var id: String
        var href: String
        var mediaType: String
        var properties: String = ""
    }

    struct OPF {
        var title = ""
        var creator = ""
        var language = ""
        var coverItemID: String?
        var manifest: [String: ManifestItem] = [:]
        var spine: [String] = []
    }

    static func parseOPF(_ text: String) -> OPF {
        var opf = OPF()
        var section = ""
        var sectionStack: [String] = []
        var fieldName: String?
        var buffer = ""

        var tokenizer = MarkupTokenizer(text)
        while let token = tokenizer.next() {
            switch token.kind {
            case .start(let tag):
                switch tag.name {
                case "metadata", "manifest", "spine", "guide":
                    section = tag.name
                    if !tag.selfClosing { sectionStack.append(tag.name) }
                case "item":
                    guard section == "manifest" else { break }
                    let id = tag.attributes["id"] ?? ""
                    let href = tag.attributes["href"] ?? ""
                    guard !id.isEmpty, !href.isEmpty else { break }
                    opf.manifest[id] = ManifestItem(
                        id: id, href: href,
                        mediaType: tag.attributes["media-type"] ?? "",
                        properties: tag.attributes["properties"] ?? "")
                case "itemref":
                    guard section == "spine" else { break }
                    if let idref = tag.attributes["idref"], !idref.isEmpty {
                        opf.spine.append(idref)
                    }
                case "meta":
                    if let name = tag.attributes["name"]?.lowercased(), name == "cover",
                       let content = tag.attributes["content"] {
                        opf.coverItemID = content
                    }
                case "title", "creator", "language":
                    fieldName = tag.name
                    buffer = ""
                default:
                    if !(tag.selfClosing || MarkupTokenizer.voidElements.contains(tag.name)) {
                        sectionStack.append(tag.name)
                    }
                }
            case .end(let name):
                switch name {
                case "metadata", "manifest", "spine", "guide":
                    section = ""
                case "title", "creator", "language":
                    let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch name {
                    case "title": if opf.title.isEmpty { opf.title = value }
                    case "creator": if opf.creator.isEmpty { opf.creator = value }
                    case "language": if opf.language.isEmpty { opf.language = value }
                    default: break
                    }
                    fieldName = nil
                    buffer = ""
                default:
                    break
                }
                if let index = sectionStack.lastIndex(of: name) {
                    sectionStack.removeSubrange(index...)
                }
            case .text(let value), .cdata(let value):
                if fieldName != nil { buffer += value }
            case .comment, .processingInstruction, .doctype:
                break
            }
        }
        // EPUB3 marks the cover with `properties="cover-image"`.
        if opf.coverItemID == nil {
            opf.coverItemID = opf.manifest.values.first { item in
                item.properties.split(separator: " ").contains("cover-image")
            }?.id
        }
        return opf
    }

    // MARK: - Table of contents

    static func navTOC(_ text: String, documentDirectory: URL, root: URL) -> [String: String] {
        var titles: [String: String] = [:]
        var inTOC = false
        var navDepth = 0
        var currentHref: String?
        var buffer = ""

        var tokenizer = MarkupTokenizer(text)
        while let token = tokenizer.next() {
            switch token.kind {
            case .start(let tag):
                switch tag.name {
                case "nav":
                    let type = tag.attributes["type"] ?? tag.attributes["role"] ?? ""
                    inTOC = type.contains("toc") || type.isEmpty
                    if inTOC { navDepth = 1 }
                case "a":
                    guard inTOC else { break }
                    currentHref = tag.attributes["href"]
                    buffer = ""
                case "ol", "ul":
                    if inTOC { navDepth += 1 }
                default:
                    break
                }
            case .end(let name):
                switch name {
                case "nav":
                    inTOC = false
                    navDepth = 0
                case "a":
                    if inTOC, let href = currentHref {
                        let title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let key = resolveHref(href, documentDirectory: documentDirectory, root: root),
                           !title.isEmpty, titles[key] == nil {
                            titles[key] = title
                        }
                    }
                    currentHref = nil
                    buffer = ""
                case "ol", "ul":
                    if inTOC { navDepth = max(1, navDepth - 1) }
                default:
                    break
                }
            case .text(let value), .cdata(let value):
                if currentHref != nil { buffer += value }
            case .comment, .processingInstruction, .doctype:
                break
            }
        }
        return titles
    }

    static func ncxTOC(_ text: String, documentDirectory: URL, root: URL) -> [String: String] {
        var titles: [String: String] = [:]
        var inNavLabel = false
        var buffer = ""
        var pendingTitle: String?
        var pendingSrc: String?

        var tokenizer = MarkupTokenizer(text)
        while let token = tokenizer.next() {
            switch token.kind {
            case .start(let tag):
                switch tag.name {
                case "navlabel":
                    inNavLabel = true
                    buffer = ""
                case "content":
                    pendingSrc = tag.attributes["src"]
                case "navpoint":
                    pendingTitle = nil
                    pendingSrc = nil
                default:
                    break
                }
            case .end(let name):
                if name == "navlabel" {
                    inNavLabel = false
                    pendingTitle = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if name == "navpoint" {
                    if let src = pendingSrc, let title = pendingTitle, !title.isEmpty,
                       let key = resolveHref(src, documentDirectory: documentDirectory, root: root),
                       titles[key] == nil {
                        titles[key] = title
                    }
                    pendingTitle = nil
                    pendingSrc = nil
                }
            case .text(let value), .cdata(let value):
                if inNavLabel { buffer += value }
            case .comment, .processingInstruction, .doctype:
                break
            }
        }
        return titles
    }

    // MARK: - Images

    static func resolveImage(
        _ source: String,
        documentDirectory: URL,
        root: URL,
        imagesDirectory: URL,
        warn: (String) -> Void
    ) -> String? {
        let withoutFragment = source.split(separator: "#").first.map(String.init) ?? source
        let trimmed = withoutFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("data:"),
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://"),
              !trimmed.hasPrefix("//")
        else { return nil }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let fileURL = documentDirectory.appendingPathComponent(decoded).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard fileURL.path.hasPrefix(rootPath) else {
            warn("image escapes the book directory: \(trimmed)")
            return nil
        }
        let key = relativePath(from: root, to: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            warn("missing image \(key)")
            return nil
        }

        // Name after the archive path so two documents referencing the same
        // file share one copy, and different files never collide.
        let extensionName = fileURL.pathExtension.lowercased()
        let fileName = SHA1.hexDigest(key) + (extensionName.isEmpty ? "" : ".\(extensionName)")
        let target = imagesDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.copyItem(at: fileURL, to: target)
            } catch {
                warn("cannot copy image \(key): \(error.localizedDescription)")
                return nil
            }
        }
        return BookPaths.imageRef(fileName: fileName)
    }

    static func extractCover(
        opf: OPF, opfDirectory: URL, root: URL, imagesDirectory: URL, warn: (String) -> Void
    ) -> String? {
        var source: URL?
        if let coverID = opf.coverItemID, let item = opf.manifest[coverID] {
            source = opfDirectory.appendingPathComponent(item.href).standardizedFileURL
        }
        if source == nil {
            // Fall back to the first image declared in the manifest.
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
            source = opf.manifest.values
                .first { imageExtensions.contains(($0.href as NSString).pathExtension.lowercased()) }
                .map { opfDirectory.appendingPathComponent($0.href).standardizedFileURL }
        }
        guard let sourceURL = source else { return nil }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            warn("cover image not found: \(sourceURL.lastPathComponent)")
            return nil
        }
        let extensionName = sourceURL.pathExtension.lowercased()
        let fileName = extensionName.isEmpty ? "cover" : "cover.\(extensionName)"
        let target = imagesDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.copyItem(at: sourceURL, to: target)
            } catch {
                warn("cannot copy cover: \(error.localizedDescription)")
                return nil
            }
        }
        return "\(BookPaths.imagesRelativeDir)/\(fileName)"
    }

    // MARK: - Utilities

    static func isTextDocument(_ item: ManifestItem) -> Bool {
        switch item.mediaType {
        case "application/xhtml+xml", "text/html", "application/xml", "text/xml":
            return true
        default:
            let extensionName = (item.href as NSString).pathExtension.lowercased()
            return ["xhtml", "html", "htm"].contains(extensionName) && item.mediaType.isEmpty
        }
    }

    static func readText(_ url: URL) -> String? {
        guard let data = FileStore.readData(url) else { return nil }
        if let decoded = EncodingDetect.decode(data) { return decoded.text }
        return nil
    }

    static func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        var relative = String(filePath.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    /// Root-relative key for matching TOC entries against spine documents;
    /// fragments and percent-escapes are removed on both sides.
    static func resolveHref(_ href: String, documentDirectory: URL, root: URL) -> String? {
        let withoutFragment = href.split(separator: "#").first.map(String.init) ?? href
        let trimmed = withoutFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("http") else { return nil }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let url = documentDirectory.appendingPathComponent(decoded).standardizedFileURL
        return normalizePath(relativePath(from: root, to: url))
    }

    static func normalizePath(_ path: String) -> String {
        (path.removingPercentEncoding ?? path).lowercased()
    }
}
