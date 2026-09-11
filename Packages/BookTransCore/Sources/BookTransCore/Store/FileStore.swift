import Foundation

/// Atomic JSON read/write.
///
/// Writes go to a sibling `.tmp` file which is then `rename(2)`-ed over the
/// destination, so a crash or kill mid-write can never leave a half-written
/// file. Reads never throw for missing/corrupt content: the caller gets `nil`
/// (and a logged warning) because every file here is a cache that can be
/// rebuilt from the original book.
public enum FileStore {
    // MARK: - Raw data

    public static func writeAtomic(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            // `replaceItemAt` keeps the destination's identity and is atomic on
            // both APFS and ext4 when the temp file is a sibling.
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    @discardableResult
    public static func writeData(_ data: Data, to url: URL) -> Bool {
        do {
            try writeAtomic(data, to: url)
            return true
        } catch {
            CoreLog.error("FileStore write failed \(url.lastPathComponent): \(error)")
            return false
        }
    }

    public static func readData(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    // MARK: - JSON

    @discardableResult
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let data = try JSONCoders.encode(value)
            try writeAtomic(data, to: url)
            return true
        } catch {
            CoreLog.error("FileStore json-encode failed \(url.lastPathComponent): \(error)")
            return false
        }
    }

    /// Returns `nil` for missing, unreadable, or corrupt files; corrupt content
    /// is logged and left on disk for post-mortem rather than deleted.
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = readData(url) else { return nil }
        if data.isEmpty { return nil }
        do {
            return try JSONCoders.decode(type, from: data)
        } catch {
            CoreLog.warn("FileStore json-decode failed \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Throwing variant for callers that must distinguish "absent" from "bad".
    public static func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONCoders.decode(type, from: data)
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Byte size of a file, or 0 when absent.
    public static func size(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
}
