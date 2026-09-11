import Foundation

/// Splits a book into translation batches of roughly 5% of its text.
///
/// The size matters for the reader, not for the model: batches are the unit of
/// progress, and a reader opens a book once the first batches are back. Two
/// rules keep batches useful and the plan self-consistent (docs/SPEC.md §8.3):
///
/// * a batch closes as soon as it reaches `target` characters;
/// * a chapter whose text fits within `target` is never split, because a chapter
///   cut in half reads badly and, more importantly, the plan promises that a
///   fully translated block is shown as a unit.
///
/// Every batch except the last therefore holds at least 75% of `target`, which
/// is what the invariants in the test suite check.
public enum Chunker {
    public static let targetFraction = 0.05
    public static let minTarget = 4000
    public static let maxTarget = 14000
    /// A block longer than this multiple of `target` is split into units.
    public static let longBlockFactor = 1.5
    /// A batch may only be closed early once it holds this share of `target`.
    public static let chapterCloseFactor = 0.75

    // MARK: - Sizing

    /// Sum of the translatable text in a set of chapters.
    public static func totalCharacters(in chapters: [Chapter]) -> Int {
        var total = 0
        for chapter in chapters {
            for block in chapter.blocks where block.kind.isTranslatable {
                total += block.text.count
            }
        }
        return total
    }

    /// 5% of the book, clamped to a range where a batch is neither too small to
    /// make progress nor too large for one model answer.
    public static func target(forTotalChars totalChars: Int) -> Int {
        let raw = Int(Double(totalChars) * targetFraction)
        return min(maxTarget, max(minTarget, raw))
    }

    // MARK: - Planning

    public static func plan(chapters: [Chapter]) -> BatchPlan {
        let total = totalCharacters(in: chapters)
        let target = target(forTotalChars: total)

        var builder = Builder(target: target)
        for chapter in chapters {
            let units = units(for: chapter, target: target)
            guard !units.isEmpty else { continue }
            builder.add(chapterUnits: units)
        }
        builder.close()
        return BatchPlan(target: target, totalChars: total, batches: builder.batches)
    }

    /// Units of a single chapter, in block order.
    public static func units(for chapter: Chapter, target: Int) -> [PlanUnit] {
        var units: [PlanUnit] = []
        for block in chapter.blocks where block.kind.isTranslatable {
            let text = block.text
            guard !text.isEmpty else { continue }
            if text.count <= Int(Double(target) * longBlockFactor) {
                units.append(PlanUnit(block: block.id, part: 0, text: text))
            } else {
                for (part, piece) in splitBlockText(text, target: target).enumerated() {
                    units.append(PlanUnit(block: block.id, part: part, text: piece))
                }
            }
        }
        return units
    }

    private struct Builder {
        let target: Int
        var batches: [Batch] = []
        private var currentUnits: [PlanUnit] = []
        private var currentChars = 0

        init(target: Int) {
            self.target = target
        }

        var hasOpenBatch: Bool { currentChars > 0 }

        mutating func add(chapterUnits units: [PlanUnit]) {
            let chapterChars = units.reduce(0) { $0 + $1.text.count }

            if chapterChars <= target {
                // Atomic chapter: the batch boundary may fall before or after it,
                // never inside it.
                if hasOpenBatch,
                   currentChars + chapterChars > target,
                   currentChars >= Int(Double(target) * chapterCloseFactor) {
                    close()
                }
                for unit in units { append(unit) }
                if currentChars >= target { close() }
                return
            }

            // Long chapter: fill batches unit by unit.
            for unit in units {
                append(unit)
                if currentChars >= target { close() }
            }
            if currentChars >= Int(Double(target) * chapterCloseFactor) {
                close()
            }
        }

        private mutating func append(_ unit: PlanUnit) {
            currentUnits.append(unit)
            currentChars += unit.text.count
        }

        mutating func close() {
            guard !currentUnits.isEmpty else { return }
            batches.append(Batch(
                index: batches.count,
                chars: currentChars,
                status: .pending,
                attempts: 0,
                error: nil,
                finishedAt: nil,
                units: currentUnits))
            currentUnits = []
            currentChars = 0
        }
    }

    // MARK: - Splitting long blocks

    /// Splits a block that is too long for one answer line into pieces of at most
    /// `target` characters, preferring sentence boundaries.
    public static func splitBlockText(_ text: String, target: Int) -> [String] {
        guard text.count > target else { return [text] }

        let sentences = sentences(in: text)
        var pieces: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }

        for sentence in sentences {
            if sentence.count > target {
                flush()
                pieces.append(contentsOf: splitByWords(sentence, target: target))
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= target {
                current += " " + sentence
            } else {
                flush()
                current = sentence
            }
        }
        flush()
        return pieces.isEmpty ? [text] : pieces
    }

    /// Sentence boundaries are a terminator run followed by whitespace or the end
    /// of the text. Closing quotes and brackets stay with the sentence.
    public static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var start = 0
        var index = 0
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
        let closers: Set<Character> = ["\"", "\u{201D}", "\u{00BB}", ")", "]", "'"]

        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }
            // Consume the whole terminator run and any trailing closers.
            var end = index
            var run = ""
            while end < characters.count, terminators.contains(characters[end]) {
                run.append(characters[end])
                end += 1
            }
            while end < characters.count, closers.contains(characters[end]) { end += 1 }

            // A boundary needs whitespace or the end of the text.
            var boundary = end >= characters.count
            var next = end
            if !boundary, characters[end].isWhitespace {
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                boundary = next >= characters.count
                    || !isAbbreviation(run: run, following: characters[next])
            }
            guard boundary else {
                index = end
                continue
            }

            let sentence = String(characters[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            start = next
            index = start
        }

        if start < characters.count {
            let tail = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { result.append(tail) }
        }
        return result.isEmpty ? [text] : result
    }

    /// `e.g. the` and `Dr. smith` must not end a sentence, so a `.` only counts
    /// as a boundary when the next word starts with an uppercase letter or a
    /// digit. `!`, `?` and `…` always end a sentence.
    private static func isAbbreviation(run: String, following: Character) -> Bool {
        guard run.allSatisfy({ $0 == "." }) else { return false }
        return following.isLowercase
    }

    /// Fallback for a single sentence longer than `target`.
    static func splitByWords(_ text: String, target: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= target || current.isEmpty {
                // A single word longer than the target is emitted as-is: there is
                // no boundary to split on that would keep it meaningful.
                current = candidate
            } else {
                pieces.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
