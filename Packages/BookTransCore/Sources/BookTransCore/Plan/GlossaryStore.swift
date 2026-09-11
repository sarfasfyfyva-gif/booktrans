import Foundation

/// Outcome of a single `GlossaryStore.merge` call.
public struct GlossaryMergeOutcome: Sendable, Equatable {
    public var added: Int
    public var incremented: Int
    /// Auto entries rejected because a user-owned entry has the same key.
    public var skippedUserOwned: Int

    public init(added: Int = 0, incremented: Int = 0, skippedUserOwned: Int = 0) {
        self.added = added
        self.incremented = incremented
        self.skippedUserOwned = skippedUserOwned
    }
}

/// In-memory editor over `Glossary` implementing the SPEC §8.6 merge rules.
///
/// The merge key is `GlossaryTerm.key(for:)` (trimmed + lowercased). An entry
/// owned by the user (`source == .user`) is never touched by an auto merge;
/// a merge with `source == .user` updates any existing entry instead.
public struct GlossaryStore: Sendable {
    public private(set) var glossary: Glossary

    public init(glossary: Glossary = Glossary()) {
        self.glossary = glossary
    }

    /// Merges model-produced terms. `firstBlock` is used for entries that are new.
    @discardableResult
    public mutating func merge(
        _ additions: [GlossaryAddition],
        source: TermSource = .auto,
        firstBlock: Int = -1
    ) -> GlossaryMergeOutcome {
        var outcome = GlossaryMergeOutcome()
        for addition in additions {
            let key = GlossaryTerm.key(for: addition.term)
            let translation = addition.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !translation.isEmpty else { continue }
            if let index = glossary.terms.firstIndex(where: { $0.key == key }) {
                if glossary.terms[index].source == .user, source == .auto {
                    outcome.skippedUserOwned += 1
                    continue
                }
                if source == .user {
                    glossary.terms[index].term = addition.term.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    glossary.terms[index].translation = translation
                    glossary.terms[index].note = addition.note
                    glossary.terms[index].source = .user
                    glossary.terms[index].updatedAt = Date()
                    fillFirstBlock(at: index, firstBlock: firstBlock)
                    continue
                }
                glossary.terms[index].count += 1
                glossary.terms[index].updatedAt = Date()
                fillFirstBlock(at: index, firstBlock: firstBlock)
                outcome.incremented += 1
            } else {
                glossary.terms.append(GlossaryTerm(
                    term: addition.term.trimmingCharacters(in: .whitespacesAndNewlines),
                    translation: translation,
                    note: addition.note,
                    kind: .term,
                    source: source,
                    count: 1,
                    firstBlock: firstBlock
                ))
                outcome.added += 1
            }
        }
        return outcome
    }

    /// Creates or updates a user-owned entry. User edits always mark `source = .user`.
    @discardableResult
    public mutating func setUserTerm(
        term: String,
        translation: String,
        note: String = "",
        kind: TermKind = .term
    ) -> GlossaryTerm {
        let key = GlossaryTerm.key(for: term)
        if let index = glossary.terms.firstIndex(where: { $0.key == key }) {
            glossary.terms[index].term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            glossary.terms[index].translation = translation
            glossary.terms[index].note = note
            glossary.terms[index].kind = kind
            glossary.terms[index].source = .user
            glossary.terms[index].updatedAt = Date()
            return glossary.terms[index]
        }
        let entry = GlossaryTerm(
            term: term.trimmingCharacters(in: .whitespacesAndNewlines),
            translation: translation,
            note: note,
            kind: kind,
            source: .user,
            count: 1,
            firstBlock: -1
        )
        glossary.terms.append(entry)
        return entry
    }

    /// Removes an entry by key. Returns true when something was removed.
    @discardableResult
    public mutating func remove(key: String) -> Bool {
        guard let index = glossary.terms.firstIndex(where: { $0.key == key }) else { return false }
        glossary.terms.remove(at: index)
        return true
    }

    public func term(key: String) -> GlossaryTerm? {
        glossary.terms.first(where: { $0.key == key })
    }

    /// Batch indices whose units contain `term` as a whole word, case-insensitively, ascending.
    public func affectedBatches(of term: String, in plan: BatchPlan) -> [Int] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var result: [Int] = []
        for batch in plan.batches where !result.contains(batch.index) {
            for unit in batch.units where containsWholeWord(unit.text, needle: needle) {
                result.append(batch.index)
                break
            }
        }
        return result.sorted()
    }

    /// Term-only quick check used by the UI before offering a re-translation.
    public func batchesContaining(anyOf terms: [String], in plan: BatchPlan) -> [Int] {
        var found = Set<Int>()
        for term in terms {
            found.formUnion(affectedBatches(of: term, in: plan))
        }
        return found.sorted()
    }

    public var sortedTerms: [GlossaryTerm] {
        glossary.terms.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.term < $1.term
        }
    }

    // MARK: - Private

    private mutating func fillFirstBlock(at index: Int, firstBlock: Int) {
        if glossary.terms[index].firstBlock == -1, firstBlock != -1 {
            glossary.terms[index].firstBlock = firstBlock
        }
    }
}

private func containsWholeWord(_ text: String, needle: String) -> Bool {
    var searchFrom = text.startIndex
    while searchFrom < text.endIndex,
        let range = text.range(
            of: needle,
            options: [.caseInsensitive],
            range: searchFrom..<text.endIndex
        )
    {
        let beforeOK: Bool
        if range.lowerBound == text.startIndex {
            beforeOK = true
        } else {
            beforeOK = !isWordCharacter(text[text.index(before: range.lowerBound)])
        }
        let afterOK: Bool
        if range.upperBound == text.endIndex {
            afterOK = true
        } else {
            afterOK = !isWordCharacter(text[range.upperBound])
        }
        if beforeOK, afterOK { return true }
        searchFrom = text.index(after: range.lowerBound)
    }
    return false
}

private func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}
