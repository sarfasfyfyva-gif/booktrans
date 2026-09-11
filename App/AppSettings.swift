import Foundation
import Observation
import SwiftUI
import BookTransCore

/// User-facing preferences.
///
/// Properties are `private(set)` and every change goes through a setter that also
/// writes to `UserDefaults`. Property observers are avoided on purpose: this type
/// is `@Observable`, and mixing the macro's accessor rewriting with `didSet` is a
/// subtle way to end up with settings that look saved but are not.
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
    private(set) var keepScreenAwake: Bool
    /// Reader typography, mirroring the CSS variables in `reader.html`.
    private(set) var readerFontSize: Double
    private(set) var readerLineHeight: Double
    private(set) var readerMargin: Double
    /// Deterministic `[перевод] …` provider, so the reader and the queue can be
    /// exercised without touching the Gemini account.
    private(set) var useMockTranslator: Bool
    /// How long to wait before retrying after a usage-limit error.
    private(set) var retryLimitMinutes: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keepScreenAwake = defaults.object(forKey: Key.keepScreenAwake) as? Bool ?? true
        self.readerFontSize = defaults.object(forKey: Key.readerFontSize) as? Double ?? 19
        self.readerLineHeight = defaults.object(forKey: Key.readerLineHeight) as? Double ?? 1.55
        self.readerMargin = defaults.object(forKey: Key.readerMargin) as? Double ?? 20
        self.useMockTranslator = defaults.object(forKey: Key.useMockTranslator) as? Bool ?? false
        self.retryLimitMinutes = defaults.object(forKey: Key.retryLimitMinutes) as? Int ?? 30
    }

    // MARK: - Setters

    func setKeepScreenAwake(_ value: Bool) {
        keepScreenAwake = value
        defaults.set(value, forKey: Key.keepScreenAwake)
    }

    func setReaderFontSize(_ value: Double) {
        readerFontSize = min(max(13, value), 30)
        defaults.set(readerFontSize, forKey: Key.readerFontSize)
    }

    func setReaderLineHeight(_ value: Double) {
        readerLineHeight = min(max(1.2, value), 2.2)
        defaults.set(readerLineHeight, forKey: Key.readerLineHeight)
    }

    func setReaderMargin(_ value: Double) {
        readerMargin = min(max(8, value), 56)
        defaults.set(readerMargin, forKey: Key.readerMargin)
    }

    func setUseMockTranslator(_ value: Bool) {
        useMockTranslator = value
        defaults.set(value, forKey: Key.useMockTranslator)
    }

    func setRetryLimitMinutes(_ value: Int) {
        retryLimitMinutes = min(max(5, value), 240)
        defaults.set(retryLimitMinutes, forKey: Key.retryLimitMinutes)
    }

    // MARK: - Bindings

    /// Bindings for SwiftUI controls, so a control can never change a value
    /// without persisting it.
    var keepScreenAwakeBinding: Binding<Bool> {
        Binding(get: { self.keepScreenAwake }, set: { self.setKeepScreenAwake($0) })
    }

    var readerFontSizeBinding: Binding<Double> {
        Binding(get: { self.readerFontSize }, set: { self.setReaderFontSize($0) })
    }

    var readerLineHeightBinding: Binding<Double> {
        Binding(get: { self.readerLineHeight }, set: { self.setReaderLineHeight($0) })
    }

    var readerMarginBinding: Binding<Double> {
        Binding(get: { self.readerMargin }, set: { self.setReaderMargin($0) })
    }

    var useMockTranslatorBinding: Binding<Bool> {
        Binding(get: { self.useMockTranslator }, set: { self.setUseMockTranslator($0) })
    }

    var retryLimitMinutesBinding: Binding<Int> {
        Binding(get: { self.retryLimitMinutes }, set: { self.setRetryLimitMinutes($0) })
    }
}
