import Foundation

/// Logging hook so the app layer can persist Core diagnostics without Core
/// depending on UIKit/SwiftUI. Uninstalled sink is a no-op.
public enum CoreLog {
    public enum Level: String, Sendable {
        case info, warn, error
    }

    /// Installed once by the app at launch. Not thread-safe to reassign while
    /// requests are in flight; the app installs it before any work starts.
    public static var sink: ((Level, String) -> Void)?

    public static func info(_ message: String) { sink?(.info, message) }
    public static func warn(_ message: String) { sink?(.warn, message) }
    public static func error(_ message: String) { sink?(.error, message) }
}

/// Shared JSON coders. Dates are ISO-8601 UTC (`2026-09-11T10:00:00Z`), keys are
/// sorted so on-disk diffs stay readable.
public enum JSONCoders {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(T.self, from: data)
    }
}
