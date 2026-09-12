import Foundation
import BookTransCore

/// Finds book files that were placed in the app's own folder rather than chosen
/// through the picker.
///
/// This is the only way to get a book onto the phone without the picker, and it is
/// what the empty-state hint promises: the Files app can copy straight into
/// `Documents/`, and iOS delivers "Open in BookTrans" into `Documents/Inbox/`.
/// Both are scanned.
enum DroppedBookScanner {
    /// Extensions we can act on unambiguously. A plain `.zip` is left alone: it
    /// may be an EPUB, but it may just as well be anything else, and guessing
    /// would turn a stray archive into an import error.
    static let acceptedExtensions: Set<String> = ["fb2", "epub"]

    /// Directories scanned, relative to the app's Documents folder.
    static let scannedDirectories = ["", "Inbox"]

    /// The folder imported files are moved into, so a file is imported once.
    static let importedDirectoryName = "Imported"

    static func isBookLike(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".fb2.zip") { return true }
        return acceptedExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Book-like files sitting in the scanned directories, shallowest first and
    /// then alphabetically, so the import order is deterministic.
    static func candidates(docsRoot: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for relative in scannedDirectories {
            let directory = relative.isEmpty
                ? docsRoot
                : docsRoot.appendingPathComponent(relative, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { continue }
            for entry in entries {
                let isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                guard isFile == true, isBookLike(entry.lastPathComponent) else { continue }
                found.append(entry)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Moves a handled file out of the scan path so it is never imported twice.
    static func retire(_ file: URL, docsRoot: URL) {
        let fm = FileManager.default
        let target = docsRoot
            .appendingPathComponent(importedDirectoryName, isDirectory: true)
            .appendingPathComponent(file.lastPathComponent)
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: file, to: target)
        } catch {
            CoreLog.warn("could not retire \(file.lastPathComponent): \(error)")
        }
    }
}
