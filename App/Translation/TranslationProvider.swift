import Foundation
import BookTransCore

/// The seam between the translation queue and however text actually gets
/// translated, so the reader and the queue can be exercised without touching the
/// Gemini account.
@MainActor
protocol TranslationProvider: AnyObject {
    /// Identifies the provider in stored batch results.
    var modelIdentifier: String { get }
    /// Sends one prompt and returns the model's raw text answer.
    func complete(prompt: String) async throws -> String
}

/// The real provider: one prompt, one fresh Gemini conversation.
@MainActor
final class GeminiTranslationProvider: TranslationProvider {
    private let session: GeminiSession

    var modelIdentifier: String { session.selectedModelId }

    init(session: GeminiSession) {
        self.session = session
    }

    func complete(prompt: String) async throws -> String {
        try await session.generate(prompt: prompt)
    }
}

/// Deterministic stand-in that answers in the exact JSON shape the real model is
/// asked for, so the queue, the parser and the glossary all run unchanged.
///
/// It reads the `[БЛОКИ]` array back out of the prompt rather than being told what
/// to answer, which means a prompt-building regression shows up here too.
@MainActor
final class MockTranslationProvider: TranslationProvider {
    var modelIdentifier: String { "mock" }

    /// Artificial latency, so the queue's pause and resume paths are exercised.
    var delay: Duration = .milliseconds(120)
    /// When set, the first `failuresBeforeSuccess` calls throw instead of answering.
    var failuresBeforeSuccess = 0
    private var attempts = 0

    func complete(prompt: String) async throws -> String {
        if delay > .zero { try? await Task.sleep(for: delay) }

        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw MockError.simulatedFailure(attempt: attempts)
        }

        if prompt.contains("[ФРАГМЕНТ]") {
            return #"{"glossary": [{"term": "ROI", "translation": "рентабельность инвестиций (ROI)"}]}"#
        }

        let blocks = MockTranslationProvider.blocks(in: prompt)
        let translations = blocks.map { "[перевод] \($0)" }
        let payload: [String: Any] = [
            "translations": translations,
            "glossary": [["term": "MockTerm", "translation": "мок-термин"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    enum MockError: LocalizedError {
        case simulatedFailure(attempt: Int)

        var errorDescription: String? {
            switch self {
            case .simulatedFailure(let attempt):
                return "Мок-переводчик: смоделированный сбой №\(attempt)"
            }
        }
    }

    /// The last line of the prompt is the JSON array of block texts.
    static func blocks(in prompt: String) -> [String] {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last, let data = last.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
