import Foundation

/// Joins the batch plan with finished batch results into per-block translated
/// text.
///
/// A block counts as translated only when **all** of its units are present; a
/// partially translated block is rendered as the original (see docs/SPEC.md
/// §8.3). That keeps the reader from showing a half-Russian paragraph.
public struct TranslationMap: Sendable {
    /// block id → part index → translated text
    private var parts: [Int: [Int: String]] = [:]
    /// block id → number of units the plan expects
    private var expectedParts: [Int: Int] = [:]
    /// block id → parts ordered as the plan lists them
    private var partOrder: [Int: [Int]] = [:]

    public let doneBatchCount: Int
    public let totalBatchCount: Int

    public init(plan: BatchPlan, results: [Int: BatchResult]) {
        doneBatchCount = plan.doneCount
        totalBatchCount = plan.batches.count

        for batch in plan.batches {
            guard let result = results[batch.index],
                  result.translations.count == batch.units.count
            else { continue }
            for (offset, unit) in batch.units.enumerated() {
                parts[unit.block, default: [:]][unit.part] = result.translations[offset]
                if partOrder[unit.block]?.contains(unit.part) != true {
                    partOrder[unit.block, default: []].append(unit.part)
                }
            }
        }

        for batch in plan.batches {
            for unit in batch.units {
                expectedParts[unit.block, default: 0] += 1
            }
        }
    }

    public init() {
        doneBatchCount = 0
        totalBatchCount = 0
    }

    /// Translation of a whole block, or `nil` when it is incomplete / untranslatable.
    public func translatedText(for blockId: Int) -> String? {
        guard let expected = expectedParts[blockId], expected > 0,
              let blockParts = parts[blockId],
              blockParts.count == expected
        else { return nil }

        let ordered = (partOrder[blockId] ?? Array(blockParts.keys)).sorted()
        let pieces = ordered.compactMap { blockParts[$0] }
        guard pieces.count == expected else { return nil }
        return pieces.joined(separator: " ")
    }

    /// True when at least one unit of the block came back, even if incomplete.
    public func hasAnyTranslation(for blockId: Int) -> Bool {
        parts[blockId]?.isEmpty == false
    }

    public var isEmpty: Bool { parts.isEmpty }

    /// Block ids that the plan expects to translate but that are not yet fully
    /// translated, in ascending order.
    public var untranslatedBlockIds: [Int] {
        expectedParts.keys.filter { translatedText(for: $0) == nil }.sorted()
    }

    /// True when every translatable block of the chapter is fully translated.
    /// A chapter with nothing to translate counts as complete.
    public func isTranslated(_ chapter: Chapter) -> Bool {
        let counts = blockCounts(in: chapter)
        return counts.total == 0 || counts.done == counts.total
    }

    /// Progress of one chapter, for the table of contents.
    public func blockCounts(in chapter: Chapter) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for block in chapter.blocks where block.kind.isTranslatable && !block.text.isEmpty {
            total += 1
            if translatedText(for: block.id) != nil { done += 1 }
        }
        return (done, total)
    }
}
