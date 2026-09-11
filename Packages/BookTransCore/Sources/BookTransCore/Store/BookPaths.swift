import Foundation

/// On-disk layout of the app sandbox (see docs/SPEC.md §6).
///
/// ```
/// Documents/
///   library.json
///   Books/{bookId}/book.json
///   Books/{bookId}/original.fb2|.epub
///   Books/{bookId}/parsed/chapters.json
///   Books/{bookId}/parsed/images/*
///   Books/{bookId}/reader.html
///   Books/{bookId}/translation/plan.json
///   Books/{bookId}/translation/batches/000.json
///   Books/{bookId}/translation/glossary.json
///   Books/{bookId}/translation/state.json
///   Books/{bookId}/progress.json
///   Config/gemini-web.json
///   Logs/gemini.log
/// ```
public struct BookPaths: Sendable, Hashable {
    public let docsRoot: URL

    public init(docsRoot: URL) {
        self.docsRoot = docsRoot.standardizedFileURL
    }

    // MARK: - Library-level

    public var libraryJSON: URL { docsRoot.appendingPathComponent("library.json") }
    public var booksDir: URL { docsRoot.appendingPathComponent("Books", isDirectory: true) }
    public var configDir: URL { docsRoot.appendingPathComponent("Config", isDirectory: true) }
    public var logsDir: URL { docsRoot.appendingPathComponent("Logs", isDirectory: true) }
    public var geminiConfigOverride: URL { configDir.appendingPathComponent("gemini-web.json") }
    public var geminiLog: URL { logsDir.appendingPathComponent("gemini.log") }

    // MARK: - Per-book

    public func bookDir(_ bookId: String) -> URL {
        booksDir.appendingPathComponent(bookId, isDirectory: true)
    }

    /// Relative path of a book file inside `Documents`, used by the reader
    /// WebView (which is granted read access to the book directory only).
    public static func relativeBookPath(_ bookId: String, _ component: String) -> String {
        "Books/\(bookId)/\(component)"
    }

    public func meta(_ bookId: String) -> URL {
        bookDir(bookId).appendingPathComponent("book.json")
    }

    public func original(_ bookId: String, ext: String) -> URL {
        bookDir(bookId).appendingPathComponent("original.\(ext)")
    }

    /// Locates the stored source file regardless of its extension.
    public func existingOriginal(_ bookId: String) -> URL? {
        for ext in ["fb2", "epub", "xml"] {
            let url = original(bookId, ext: ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func parsedDir(_ bookId: String) -> URL {
        bookDir(bookId).appendingPathComponent("parsed", isDirectory: true)
    }

    public func chapters(_ bookId: String) -> URL {
        parsedDir(bookId).appendingPathComponent("chapters.json")
    }

    public func imagesDir(_ bookId: String) -> URL {
        parsedDir(bookId).appendingPathComponent("images", isDirectory: true)
    }

    /// Reader-facing relative image directory (resolved against the book dir).
    public static let imagesRelativeDir = "parsed/images"

    /// Relative reference stored in `Block.imageRef`, e.g. `images/abc.jpg`.
    public static func imageRef(fileName: String) -> String {
        "images/\(fileName)"
    }

    /// `reader.html` sits in the book directory and only that directory is
    /// granted read access, so a stored reference must be rewritten for the
    /// page: `images/abc.jpg` becomes `parsed/images/abc.jpg`.
    public static func readerImageSource(for reference: String) -> String {
        // Both importers write images flat into parsed/images, so only the file
        // name matters; taking just that also makes a malicious reference unable
        // to point anywhere else in the sandbox.
        "\(imagesRelativeDir)/\((reference as NSString).lastPathComponent)"
    }

    public func readerHTML(_ bookId: String) -> URL {
        bookDir(bookId).appendingPathComponent("reader.html")
    }

    public func translationDir(_ bookId: String) -> URL {
        bookDir(bookId).appendingPathComponent("translation", isDirectory: true)
    }

    public func plan(_ bookId: String) -> URL {
        translationDir(bookId).appendingPathComponent("plan.json")
    }

    public func batchesDir(_ bookId: String) -> URL {
        translationDir(bookId).appendingPathComponent("batches", isDirectory: true)
    }

    public static func batchFileName(_ index: Int) -> String {
        String(format: "%03d.json", index)
    }

    public func batch(_ bookId: String, index: Int) -> URL {
        batchesDir(bookId).appendingPathComponent(Self.batchFileName(index))
    }

    public func glossary(_ bookId: String) -> URL {
        translationDir(bookId).appendingPathComponent("glossary.json")
    }

    public func state(_ bookId: String) -> URL {
        translationDir(bookId).appendingPathComponent("state.json")
    }

    public func progress(_ bookId: String) -> URL {
        bookDir(bookId).appendingPathComponent("progress.json")
    }

    // MARK: - Directories

    /// Every directory that must exist for the app to operate.
    public var allDirectories: [URL] {
        [docsRoot, booksDir, configDir, logsDir]
    }

    public func allDirectories(forBook bookId: String) -> [URL] {
        [
            bookDir(bookId),
            parsedDir(bookId),
            imagesDir(bookId),
            translationDir(bookId),
            batchesDir(bookId),
        ]
    }

    public func createDirectories(forBook bookId: String) throws {
        try createAll(allDirectories + allDirectories(forBook: bookId))
    }

    public func createAll(_ directories: [URL]) throws {
        let fm = FileManager.default
        for dir in directories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
