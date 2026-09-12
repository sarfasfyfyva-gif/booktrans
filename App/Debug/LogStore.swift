import Foundation
import BookTransCore

/// JSONL log at `Documents/Logs/gemini.log`, rotated at 2 MB.
///
/// Protocol secrets (the `at` token, cookie values) are never written: every
/// component that learns a secret registers it here and the writer replaces
/// occurrences with `<redacted>`. This is what makes it safe to attach the log
/// to a bug report.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let queue = DispatchQueue(label: "com.gennadiy.booktrans.log")
    private let maxBytes = 2 * 1024 * 1024

    private var fileURL: URL?
    private var secrets: [String] = []
    private var installed = false

    private init() {}

    // MARK: - Setup

    /// Points the log at a file. Subsequent entries append to it.
    func configure(url: URL) {
        queue.sync {
            self.fileURL = url
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    /// Wires `CoreLog` into this store. Idempotent.
    func install() {
        queue.sync {
            guard !installed else { return }
            installed = true
        }
        CoreLog.sink = { level, message in
            LogStore.shared.append(level: level, event: message)
        }
    }

    /// Registers a value that must never appear verbatim in the log.
    func registerSecret(_ value: String) {
        guard value.count >= 8 else { return }
        queue.sync {
            if !secrets.contains(value) { secrets.append(value) }
        }
    }

    func registeredSecretCount() -> Int {
        queue.sync { secrets.count }
    }

    // MARK: - Writing

    func append(level: CoreLog.Level, event: String, fields: [String: String] = [:]) {
        queue.async { [weak self] in
            self?.write(level: level, event: event, fields: fields)
        }
    }

    /// Synchronous variant, for callers that must guarantee ordering (tests,
    /// crash-adjacent paths).
    func appendSync(level: CoreLog.Level, event: String, fields: [String: String] = [:]) {
        queue.sync { write(level: level, event: event, fields: fields) }
    }

    private func write(level: CoreLog.Level, event: String, fields: [String: String]) {
        guard let url = fileURL else { return }
        rotateIfNeeded(url)

        var object: [String: Any] = [
            "ts": LogStore.timestamp(),
            "level": level.rawValue,
            "event": redactLocked(event),
        ]
        if !fields.isEmpty {
            object["fields"] = fields.mapValues { redactLocked($0) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"

        guard let lineData = line.data(using: .utf8) else { return }
        appendBytes(lineData, to: url)
    }

    private func appendBytes(_ data: Data, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never take the app down.
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        guard FileStore.size(url) > maxBytes else { return }
        let backup = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    // MARK: - Reading

    /// The log file itself, for handing to a share sheet. The file is what makes the
    /// log reachable at all: it sits in `Documents`, which is exposed to the Files
    /// app, so a device with no cable attached can still send it.
    var shareURL: URL? {
        queue.sync { fileURL }
    }

    /// Last `count` lines, newest last. Used by the debug screen.
    func tail(_ count: Int = 200) -> [String] {
        queue.sync {
            guard let url = fileURL, let data = FileStore.readData(url),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return Array(lines.suffix(count))
        }
    }

    func fullText() -> String {
        queue.sync {
            guard let url = fileURL, let data = FileStore.readData(url),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
    }

    func clear() {
        queue.sync {
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
            let backup = url.deletingPathExtension().appendingPathExtension("log.1")
            try? FileManager.default.removeItem(at: backup)
        }
    }

    // MARK: - Redaction

    /// Logs only the host of a URL: paths and query strings can carry tokens.
    func redactedHost(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "(invalid url)" }
        return host
    }

    private func redactLocked(_ text: String) -> String {
        guard !secrets.isEmpty, !text.isEmpty else { return text }
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return result
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
