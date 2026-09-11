import Foundation

public protocol ArchiveExtracting: Sendable {
    func extract(_ archiveURL: URL, to destination: URL) throws
}

public enum EPUBUnpackError: LocalizedError {
    case unsafeEntryPath(String)
    case extractionFailed(String)
    case emptyArchive

    public var errorDescription: String? {
        switch self {
        case .unsafeEntryPath(let path):
            return "Архив содержит небезопасный путь: \(path)"
        case .extractionFailed(let reason):
            return "Не удалось распаковать EPUB: \(reason)"
        case .emptyArchive:
            return "Архив EPUB пуст или повреждён."
        }
    }
}

#if canImport(ZIPFoundation)
import ZIPFoundation

/// The real extractor. ZIPFoundation is the project's only external dependency.
public struct ZIPFoundationExtractor: ArchiveExtracting {
    public init() {}

    public func extract(_ archiveURL: URL, to destination: URL) throws {
        guard let archive = Archive(url: archiveURL, accessMode: .read) else {
            throw EPUBUnpackError.extractionFailed("не удалось открыть архив")
        }
        // Reject entries that would escape the destination before writing
        // anything: some EPUBs in the wild carry `..` segments.
        for entry in archive where !EPUBUnpacker.isSafeEntryPath(entry.path) {
            throw EPUBUnpackError.unsafeEntryPath(entry.path)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try fileManager.unzipItem(at: archiveURL, to: destination)
        } catch {
            throw EPUBUnpackError.extractionFailed(error.localizedDescription)
        }
    }
}
#endif

/// Unpacks an EPUB into a directory.
///
/// `ArchiveExtracting` is injectable so the EPUB parser tests can run against a
/// directory fixture, which keeps them independent of the zip implementation
/// (docs/SPEC.md §11).
public enum EPUBUnpacker {
    /// True when an archive entry cannot write outside the destination
    /// directory. Absolute paths and any `..` segment are refused.
    public static func isSafeEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        // Windows-style separators appear in archives produced on Windows.
        let segments = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return !segments.contains("..")
    }

    public static func unpack(
        archive: URL,
        to destination: URL,
        using extractor: ArchiveExtracting = defaultExtractor()
    ) throws {
        try extractor.extract(archive, to: destination)
    }

    public static func defaultExtractor() -> ArchiveExtracting {
        #if canImport(ZIPFoundation)
        return ZIPFoundationExtractor()
        #else
        return UnavailableExtractor()
        #endif
    }
}

/// Used on platforms without ZIPFoundation; the app layer unpacks instead.
public struct UnavailableExtractor: ArchiveExtracting {
    public init() {}
    public func extract(_ archiveURL: URL, to destination: URL) throws {
        throw EPUBUnpackError.extractionFailed(
            "распаковка недоступна: передайте уже распакованный каталог")
    }
}
