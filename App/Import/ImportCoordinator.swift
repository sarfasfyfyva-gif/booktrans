import Foundation
import BookTransCore

/// Turns a picked or shared file into a book on disk: original copy, parsed
/// chapters, images, batch plan and library entry.
@MainActor
struct ImportCoordinator {
    enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case unreadable(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return ext.isEmpty
                    ? "Не удалось определить формат файла. Поддерживаются FB2 и EPUB."
                    : "Формат «.\(ext)» не поддерживается. Нужен FB2 или EPUB."
            case .unreadable(let reason):
                return "Не удалось прочитать файл: \(reason)"
            case .noContent:
                return "В файле не найдено текста для чтения."
            }
        }
    }

    /// Imports one file and returns the new book id.
    @discardableResult
    static func importBook(from source: URL, into app: AppState) throws -> String {
        let needsScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { source.stopAccessingSecurityScopedResource() } }

        guard let data = FileStore.readData(source) else {
            throw ImportError.unreadable("файл недоступен")
        }
        let format = try detectFormat(fileName: source.lastPathComponent, data: data)

        let bookId = UUID().uuidString
        let paths = app.paths
        do {
            try paths.createDirectories(forBook: bookId)

            // 1. Keep the original next to everything derived from it.
            FileStore.writeData(data, to: paths.original(bookId, ext: format.fileExtension))

            // 2. Parse into chapters and images.
            let parsed = try parse(data: data, format: format, bookId: bookId, paths: paths)

            // 3. Persist chapters, then the plan derived from them.
            guard app.books.saveChapters(parsed.chapters, bookId: bookId) else {
                throw ImportError.unreadable("не удалось записать главы")
            }
            let plan = Chunker.plan(chapters: parsed.chapters)
            app.books.savePlan(plan, bookId: bookId)

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
            app.books.saveMeta(meta)

            _ = app.library.upsert(LibraryEntry(
                id: bookId,
                title: meta.title,
                author: meta.author,
                coverPath: meta.coverPath,
                batchesDone: 0,
                batchesTotal: plan.batches.count,
                status: .idle,
                lastOpenedAt: Date()))
            app.reloadLibrary()

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
            return bookId
        } catch {
            // A failed import must not leave a half-built book in the library.
            try? app.books.deleteBook(bookId)
            LogStore.shared.append(level: .error, event: "import.failed",
                                   fields: ["error": "\(error)"])
            throw error
        }
    }

    // MARK: - Format detection

    /// Extension first, then content: `.fb2` and `.epub` are the only names we
    /// accept, but a `.xml` file that is really FB2 is common enough to matter.
    static func detectFormat(fileName: String, data: Data) throws -> BookFormat {
        let extensionName = (fileName as NSString).pathExtension.lowercased()
        switch extensionName {
        case "fb2", "fb2.zip": return .fb2
        case "epub": return .epub
        default: break
        }
        // ZIP magic means EPUB; an XML prologue or a FictionBook root means FB2.
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .epub }
        if let head = String(data: data.prefix(4096), encoding: .utf8)?.lowercased()
            ?? EncodingDetect.decode(data).map({ String($0.text.prefix(4096)).lowercased() }) {
            if head.contains("<fictionbook") || (head.contains("<?xml") && head.contains("<body")) {
                return .fb2
            }
        }
        throw ImportError.unsupportedFormat(extensionName)
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
            guard ImageDownscaler.write(decoded, to: target) else {
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
