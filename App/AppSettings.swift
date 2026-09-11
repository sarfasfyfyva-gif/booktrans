import Foundation
import Observation
import BookTransCore

/// User-facing preferences. Persisted individually in `UserDefaults` so that a
/// missing or corrupt entry falls back to its default instead of losing the
/// whole set.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let keepScreenAwake = "com.gennadiy.booktrans.keepScreenAwake"
        static let readerFontSize = "com.gennadiy.booktrans.readerFontSize"
        static let readerLineHeight = "com.gennadiy.booktrans.readerLineHeight"
        static let readerMargin = "com.gennadiy.booktrans.readerMargin"
        static let useMockTranslator = "com.gennadiy.booktrans.useMockTranslator"
        static let retryLimitMinutes = "com.gennadiy.booktrans.retryLimitMinutes"
    }

    private let defaults: UserDefaults

    /// Keeps the display on while a batch is in flight. iOS sleeps the app
    /// otherwise, and translation only progresses while it is active.
    var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    /// Reader typography, mirroring the CSS variables in `reader.html`.
    var readerFontSize: Double {
        didSet { defaults.set(readerFontSize, forKey: Key.readerFontSize) }
    }

    var readerLineHeight: Double {
        didSet { defaults.set(readerLineHeight, forKey: Key.readerLineHeight) }
    }

    var readerMargin: Double {
        didSet { defaults.set(readerMargin, forKey: Key.readerMargin) }
    }

    /// Deterministic `[перевод] …` provider, so the reader and the queue can be
    /// exercised without touching the Gemini account.
    var useMockTranslator: Bool {
        didSet { defaults.set(useMockTranslator, forKey: Key.useMockTranslator) }
    }

    /// How long to wait before retrying after a usage-limit error.
    var retryLimitMinutes: Int {
        didSet { defaults.set(retryLimitMinutes, forKey: Key.retryLimitMinutes) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keepScreenAwake = defaults.object(forKey: Key.keepScreenAwake) as? Bool ?? true
        self.readerFontSize = defaults.object(forKey: Key.readerFontSize) as? Double ?? 19
        self.readerLineHeight = defaults.object(forKey: Key.readerLineHeight) as? Double ?? 1.55
        self.readerMargin = defaults.object(forKey: Key.readerMargin) as? Double ?? 20
        self.useMockTranslator = defaults.object(forKey: Key.useMockTranslator) as? Bool ?? false
        self.retryLimitMinutes = defaults.object(forKey: Key.retryLimitMinutes) as? Int ?? 30
    }
}
