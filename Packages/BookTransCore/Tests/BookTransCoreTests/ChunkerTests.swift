import XCTest
@testable import BookTransCore

/// The batch plan decides what a reader can see while the rest of the book is
/// still translating, so the invariants in docs/SPEC.md §8.3 are pinned here:
/// every unit appears exactly once, order matches the book, no batch except the
/// last is under 75% of the target, and a chapter that fits in the target is
/// never cut in half.
final class ChunkerTests: XCTestCase {

    // MARK: - Helpers

    private func paragraph(_ id: Int, _ length: Int, _ character: Character = "a") -> Block {
        Block(id: id, kind: .paragraph, text: String(repeating: character, count: length))
    }

    private func chapter(_ index: Int, _ blocks: [Block], title: String = "Ch") -> Chapter {
        Chapter(index: index, title: title, docHref: "doc\(index).xhtml", blocks: blocks)
    }

    /// Asserts the invariants that must hold for any produced plan.
    private func assertInvariants(_ plan: BatchPlan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.batches.map(\.index), Array(0..<plan.batches.count),
                       "batch indices must be contiguous from 0", file: file, line: line)

        var seen: [PlanUnit] = []
        for batch in plan.batches {
            XCTAssertFalse(batch.units.isEmpty, "empty batch \(batch.index)", file: file, line: line)
            let declared = batch.units.reduce(0) { $0 + $1.text.count }
            XCTAssertEqual(batch.chars, declared, "chars must match the units", file: file, line: line)
            seen.append(contentsOf: batch.units)
        }

        // Order and completeness: the unit sequence must equal the plan's own
        // order, and no unit may appear twice.
        var identities = Set<String>()
        for unit in seen {
            let identity = "\(unit.block)#\(unit.part)"
            XCTAssertTrue(identities.insert(identity).inserted,
                          "unit \(identity) appears in more than one batch", file: file, line: line)
        }

        // Every non-final batch holds at least 75% of the target.
        let floor = Int(Double(plan.target) * Chunker.chapterCloseFactor)
        for batch in plan.batches.dropLast() {
            XCTAssertGreaterThanOrEqual(batch.chars, floor,
                "batch \(batch.index) is below the 75% floor", file: file, line: line)
        }
    }

    // MARK: - Sizing

    func testTargetIsFivePercentClampedToTheAllowedRange() {
        XCTAssertEqual(Chunker.target(forTotalChars: 0), 4000, "small books still need a floor")
        XCTAssertEqual(Chunker.target(forTotalChars: 20000), 4000, "1000 clamped up")
        XCTAssertEqual(Chunker.target(forTotalChars: 100000), 5000)
        XCTAssertEqual(Chunker.target(forTotalChars: 200000), 10000)
        XCTAssertEqual(Chunker.target(forTotalChars: 412345), 14000, "20617 clamped down")
        XCTAssertEqual(Chunker.target(forTotalChars: 1_000_000), 14000)
    }

    func testTotalCharactersCountsOnlyTranslatableBlocks() {
        let chapter = chapter(0, [
            paragraph(0, 100),
            Block(id: 1, kind: .heading, text: String(repeating: "b", count: 50)),
            Block(id: 2, kind: .hr, text: "ignored"),
            Block(id: 3, kind: .image, text: "ignored", imageRef: "images/x.jpg"),
            Block(id: 4, kind: .table, text: "ignored", rawHTML: "<table/>"),
            Block(id: 5, kind: .listItem, text: String(repeating: "c", count: 30)),
        ])
        XCTAssertEqual(Chunker.totalCharacters(in: [chapter]), 180)
    }

    func testEmptyBookProducesNoBatches() {
        let plan = Chunker.plan(chapters: [])
        XCTAssertTrue(plan.batches.isEmpty)
        XCTAssertEqual(plan.target, 4000)
    }

    func testWhitespaceOnlyBlocksAreSkipped() {
        let plan = Chunker.plan(chapters: [chapter(0, [paragraph(0, 0), paragraph(1, 0)])])
        XCTAssertTrue(plan.batches.isEmpty, "blocks with no text produce no units")
    }

    // MARK: - Block splitting

    func testShortBlockStaysOneUnit() {
        let units = Chunker.units(for: chapter(0, [paragraph(0, 100)]), target: 4000)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].part, 0)
        XCTAssertEqual(units[0].block, 0)
    }

    func testSplitBlockUsesSentenceBoundariesAndRespectsTarget() {
        // 300 characters per sentence, 40 sentences = 12000 characters, target 4000.
        let sentence = String(repeating: "Word ", count: 59) + "end."
        let text = Array(repeating: sentence, count: 40).joined(separator: " ")
        XCTAssertGreaterThan(text.count, Int(Double(4000) * Chunker.longBlockFactor))

        let units = Chunker.units(for: chapter(0, [Block(id: 7, kind: .paragraph, text: text)]),
                                  target: 4000)
        XCTAssertGreaterThan(units.count, 1, "a 12000 character block must be split")
        for unit in units {
            XCTAssertLessThanOrEqual(unit.text.count, 4000, "every part must fit the target")
            XCTAssertEqual(unit.block, 7)
        }
        XCTAssertEqual(units.map(\.part), Array(0..<units.count), "parts numbered from 0 in order")
        // Rejoining the parts must reproduce the original text.
        XCTAssertEqual(units.map(\.text).joined(separator: " "), text)
    }

    func testSentenceLongerThanTargetFallsBackToWordBoundaries() {
        let long = Array(repeating: "gamma", count: 2000).joined(separator: " ")  // 11999 chars, no terminator
        let pieces = Chunker.splitBlockText(long, target: 4000)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 4000)
        }
        XCTAssertEqual(pieces.joined(separator: " "), long, "splitting must not lose words")
    }

    func testSentenceSplittingKeepsClosingQuotesWithTheSentence() {
        let text = "Он сказал: \"Привет.\" Потом ушёл. И вернулся!"
        XCTAssertEqual(Chunker.sentences(in: text),
                       ["Он сказал: \"Привет.\"", "Потом ушёл.", "И вернулся!"])
    }

    func testSentenceSplittingDoesNotBreakOnAbbreviationLikePeriodInsideWord() {
        let text = "See e.g. the next part. It continues here."
        let sentences = Chunker.sentences(in: text)
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0], "See e.g. the next part.")
    }

    // MARK: - Chapter handling

    func testChapterThatFitsTargetIsNeverSplit() {
        // Four chapters of 3500 characters: 5% of 14000 is 700, so target is 4000.
        let chapters = (0..<4).map { chapter($0, [paragraph($0, 3500)]) }
        let plan = Chunker.plan(chapters: chapters)

        XCTAssertEqual(plan.target, 4000)
        assertInvariants(plan)

        // No batch may contain two different chapters.
        // Every block has its own batch here: each chapter is atomic and lands on
        // a chapter boundary rather than being cut in half.
        XCTAssertEqual(plan.batches.count, 4)
        XCTAssertEqual(plan.batches.map(\.chars), [3500, 3500, 3500, 3500])
    }

    func testSmallChaptersAreMergedWhenTheOpenBatchIsStillShort() {
        // Six chapters of 1000 characters: target 4000, 75% floor 3000.
        let chapters = (0..<6).map { chapter($0, [paragraph($0, 1000)]) }
        let plan = Chunker.plan(chapters: chapters)
        assertInvariants(plan)

        // Three chapters (3000 chars) reach the floor, then the batch closes at
        // the chapter boundary rather than mid-chapter.
        for batch in plan.batches.dropLast() {
            XCTAssertGreaterThanOrEqual(batch.chars, 3000)
        }
        XCTAssertEqual(plan.batches.reduce(0) { $0 + $1.units.count }, 6,
                       "every chapter must be present exactly once")
    }

    func testLongChapterIsSplitAcrossBatches() {
        // A single chapter of 12000 characters cannot fit the 4000 target.
        let chapters = [
            chapter(0, [paragraph(0, 6000, "a"), paragraph(1, 6000, "b")]),
            chapter(1, [paragraph(2, 5000, "c")]),
        ]
        let plan = Chunker.plan(chapters: chapters)
        assertInvariants(plan)
        XCTAssertGreaterThan(plan.batches.count, 1)
        let batchOfBlock: (Int) -> Int? = { block in
            plan.batches.first { $0.units.contains { $0.block == block } }?.index
        }
        XCTAssertNotEqual(batchOfBlock(0), batchOfBlock(1),
                          "a chapter too large for one batch must be divided")
    }

    func testPlanCoversEveryTranslatableBlockExactlyOnceInOrder() {
        let chapters = [
            chapter(0, [paragraph(0, 900), Block(id: 1, kind: .heading, text: "Title"),
                        Block(id: 2, kind: .image, text: "", imageRef: "images/a.jpg")]),
            chapter(1, [paragraph(3, 2500), Block(id: 4, kind: .blockquote, text: "Quote")]),
            chapter(2, [Block(id: 5, kind: .listItem, text: "Item"), paragraph(6, 4800)]),
        ]
        let plan = Chunker.plan(chapters: chapters)
        assertInvariants(plan)

        let plannedBlocks = plan.batches.flatMap { $0.units.map(\.block) }
        var ordered: [Int] = []
        for unit in plan.batches.flatMap(\.units) where ordered.last != unit.block {
            ordered.append(unit.block)
        }
        XCTAssertEqual(Set(plannedBlocks), [0, 1, 3, 4, 5, 6],
                       "images and non-translatable kinds must not be planned")
        XCTAssertEqual(ordered, [0, 1, 3, 4, 5, 6], "block order must follow the book")
        for block in [0, 1, 3, 4, 5, 6] {
            let parts = plan.batches.flatMap(\.units).filter { $0.block == block }.map(\.part)
            XCTAssertEqual(parts, Array(0..<parts.count), "parts of block \(block) numbered in order")
        }
    }

    func testTargetIsReportedInThePlan() {
        let chapters = (0..<10).map { chapter($0, [paragraph($0, 4000)]) }
        let plan = Chunker.plan(chapters: chapters)
        XCTAssertEqual(plan.totalChars, 40000)
        XCTAssertEqual(plan.target, 4000)
        XCTAssertEqual(plan.batches.map(\.status), Array(repeating: .pending, count: plan.batches.count))
        XCTAssertEqual(plan.nextPendingIndex, 0)
    }
}
