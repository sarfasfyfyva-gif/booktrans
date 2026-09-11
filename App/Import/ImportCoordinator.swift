import Foundation
import BookTransCore

/// Turns a picked or shared file into a book on disk: original copy, parsed
/// chapters, images and batch plan.
///
/// Deliberately not main-actor isolated. Unzipping an EPUB, parsing XML,
/// base64-decoding `<binary>` elements and re-encoding images is seconds of work
/// for a large book; running it on the main thread would freeze the UI and can
/// trip the iOS watchdog. `AppState` runs `prepare` off the main actor and only
/// touches the library list afterwards.
enum ImportCoordinator {
    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case unreadable(String)
        case noContent
        case emptyArchive(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return ext.isEmpty
                    ? "Не удалось определить формат файла. Поддерживаются FB2 и EPUB."
                    : "Формат «.\(ext)» не поддерживается. Нужен FB2 (в том числе .fb2.zip) или EPUB."
            case .unreadable(let reason):
                return "Не удалось прочитать файл: \(reason)"
            case .noContent:
                return "В файле не найдено текста для чтения."
            case .emptyArchive(let name):
                return "В архиве «\(name)» не найден файл .fb2."
            }
        }
    }

    /// Everything the main actor needs to add the book to the library.
    struct Prepared: Sendable {
        var bookId: String
        var meta: BookMeta
        var plan: BatchPlan
        var entry: LibraryEntry
        var warnings: [String]
    }

    // MARK: - Entry point

    /// Reads, parses and writes one book. Safe to call off the main actor.
    static func prepare(source: URL, bookId: String, paths: BookPaths) throws -> Prepared {
        let needsScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { source.stopAccessingSecurityScopedResource() } }

        guard let data = FileStore.readData(source) else {
            throw ImportError.unreadable("файл недоступен")
        }
        let fileName = source.lastPathComponent
        var format = try detectFormat(fileName: fileName, data: data)
        var payload = data

        // A `.fb2.zip` holds exactly one book; unpack it once, up front, so the
        // rest of the pipeline only ever sees a plain FB2 document.
        if fileName.lowercased().hasSuffix(".fb2.zip") {
            payload = try unpackInnerFB2(data: data, bookId: bookId, paths: paths)
            format = .fb2
        }

        let books = BookStore(paths: paths)
        do {
            try paths.createDirectories(forBook: bookId)

            // 1. Keep the original next to everything derived from it.
            FileStore.writeData(payload, to: paths.original(bookId, ext: format.fileExtension))

            // 2. Parse into chapters and images.
            let parsed = try parse(data: payload, format: format, bookId: bookId, paths: paths)

            // 3. Persist chapters, then the plan derived from them.
            guard books.saveChapters(parsed.chapters, bookId: bookId) else {
                throw ImportError.unreadable("не удалось записать главы")
            }
            let plan = Chunker.plan(chapters: parsed.chapters)
            books.savePlan(plan, bookId: bookId)

            let meta = BookMeta(
                id: bookId,
                title: parsed.title,
                author: parsed.author,
                format: format,
                sourceLang: parsed.language.isEmpty ? "en" : parsed.language,
                targetLang: "ru",
                charCount: plan.totalChars,
                chapterCount: parsed.chapters.count,
                batchCount: plan.batches.count,
                coverPath: parsed.coverPath)
            books.saveMeta(meta)

            let entry = LibraryEntry(
                id: bookId,
                title: meta.title,
                author: meta.author,
                coverPath: meta.coverPath,
                batchesDone: 0,
                batchesTotal: plan.batches.count,
                status: .idle,
                lastOpenedAt: Date())

            LogStore.shared.append(level: .info, event: "import.ok", fields: [
                "id": bookId,
                "format": format.rawValue,
                "chapters": String(parsed.chapters.count),
                "batches": String(plan.batches.count),
                "chars": String(plan.totalChars),
                "warnings": String(parsed.warnings.count),
            ])
            for warning in parsed.warnings.prefix(20) {
                CoreLog.warn("import: \(warning)")
            }
            return Prepared(bookId: bookId, meta: meta, plan: plan, entry: entry,
                            warnings: parsed.warnings)
        } catch {
            // A failed import must not leave a half-built book on disk.
            try? books.deleteBook(bookId)
            LogStore.shared.append(level: .error, event: "import.failed",
                                   fields: ["error": "\(error)"])
            throw error
        }
    }

    // MARK: - Format detection

    /// Extension first, then content: `.fb2`, `.fb2.zip` and `.epub` are the
    /// names we accept, but a `.xml` file that is really FB2 is common enough to
    /// matter.
    static func detectFormat(fileName: String, data: Data) throws -> BookFormat {
        let lower = fileName.lowercased()
        let extensionName = (fileName as NSString).pathExtension.lowercased()

        switch extensionName {
        case "fb2": return .fb2
        case "epub": return .epub
        default: break
        }
        // `.fb2.zip` has to be tested against the whole name: `pathExtension`
        // only returns the part after the last dot, i.e. "zip".
        if lower.hasSuffix(".fb2.zip") { return .fb2 }

        // ZIP magic means EPUB; an XML prologue or a FictionBook root means FB2.
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .epub }
        let head = data.prefix(4096)
        if let text = String(data: head, encoding: .utf8)?.lowercased()
            ?? EncodingDetect.decode(head)?.text.lowercased() {
            if text.contains("<fictionbook") || (text.contains("<?xml") && text.contains("<body")) {
                return .fb2
            }
        }
        throw ImportError.unsupportedFormat(extensionName)
    }

    /// Reads the single `.fb2` out of a `.fb2.zip`.
    private static func unpackInnerFB2(data: Data, bookId: String, paths: BookPaths) throws -> Data {
        let archive = paths.bookDir(bookId).appendingPathComponent("book.fb2.zip")
        let destination = paths.bookDir(bookId).appendingPathComponent("fb2zip", isDirectory: true)
        defer {
            FileStore.remove(archive)
            try? FileManager.default.removeItem(at: destination)
        }
        guard FileStore.writeData(data, to: archive) else {
            throw ImportError.unreadable("не удалось записать архив")
        }
        try EPUBUnpacker.unpack(archive: archive, to: destination)

        let entries = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        guard let fb2 = entries.first(where: { $0.pathExtension.lowercased() == "fb2" }),
              let inner = FileStore.readData(fb2)
        else {
            throw ImportError.emptyArchive("книга.fb2.zip")
        }
        return inner
    }

    // MARK: - Parsing

    private struct Parsed {
        var title: String
        var author: String
        var language: String
        var chapters: [Chapter]
        var coverPath: String?
        var warnings: [String]
    }

    private static func parse(
        data: Data, format: BookFormat, bookId: String, paths: BookPaths
    ) throws -> Parsed {
        switch format {
        case .fb2:
            return try parseFB2(data: data, bookId: bookId, paths: paths)
        case .epub:
            return try parseEPUB(data: data, bookId: bookId, paths: paths)
        }
    }

    private static func parseFB2(data: Data, bookId: String, paths: BookPaths) throws -> Parsed {
        let result = try FB2Parser.parse(data: data)
        let imagesDirectory = paths.imagesDir(bookId)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        for image in result.images {
            guard let decoded = Data(base64Encoded: image.base64,
                                     options: .ignoreUnknownCharacters) else {
                CoreLog.warn("import: cannot decode binary \(image.id)")
                continue
            }
            let target = imagesDirectory.appendingPathComponent(FB2Parser.fileName(for: image))
            if !ImageDownscaler.write(decoded, to: target) {
                CoreLog.warn("import: cannot write image \(image.id)")
            }
        }

        var coverPath: String?
        if let coverID = result.coverImageID,
           let cover = result.images.first(where: { $0.id == coverID }) {
            coverPath = "\(BookPaths.imagesRelativeDir)/\(FB2Parser.fileName(for: cover))"
        }

        return Parsed(
            title: result.title,
            author: result.author,
            language: result.language,
            chapters: result.chapters,
            coverPath: coverPath,
            warnings: result.warnings)
    }

    private static func parseEPUB(data: Data, bookId: String, paths: BookPaths) throws -> Parsed {
        let unpacked = paths.bookDir(bookId).appendingPathComponent("epub", isDirectory: true)
        let archive = paths.bookDir(bookId).appendingPathComponent("archive.epub")
        guard FileStore.writeData(data, to: archive) else {
            throw ImportError.unreadable("не удалось записать архив")
        }
        defer { FileStore.remove(archive) }

        try EPUBUnpacker.unpack(archive: archive, to: unpacked)
        let result = try EPUBParser.parse(root: unpacked, imagesDirectory: paths.imagesDir(bookId))
        return Parsed(
            title: result.title,
            author: result.author,
            language: result.language,
            chapters: result.chapters,
            coverPath: result.coverPath,
            warnings: result.warnings)
    }
}
