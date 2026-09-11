import XCTest
@testable import BookTransCore

/// Merge rules and batch search of `GlossaryStore` (SPEC §8.6).
final class GlossaryStoreTests: XCTestCase {
    private func makePlan(_ textsByBatch: [[String]]) -> BatchPlan {
        BatchPlan(
            target: 4000,
            totalChars: 0,
            batches: textsByBatch.enumerated().map { batchIndex, texts in
                Batch(
                    index: batchIndex,
                    chars: texts.reduce(0) { $0 + $1.count },
                    units: texts.enumerated().map { unitIndex, text in
                        PlanUnit(block: batchIndex * 100 + unitIndex, part: 0, text: text)
                    }
                )
            }
        )
    }

    func testAutoMergeDoesNotOverwriteUserEntry() {
        var store = GlossaryStore()
        store.setUserTerm(term: "ROI", translation: "рентабельность инвестиций (ROI)")
        let before = store.term(key: "roi")!

        let outcome = store.merge([
            GlossaryAddition(term: "ROI", translation: "return on investment", note: "auto"),
        ])

        XCTAssertEqual(outcome.skippedUserOwned, 1)
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.incremented, 0)
        let after = store.term(key: "roi")!
        XCTAssertEqual(after.translation, "рентабельность инвестиций (ROI)")
        XCTAssertEqual(after.source, .user)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.note, before.note)
    }

    func testAutoMergeIncrementsCountWithoutChangingTranslation() {
        var store = GlossaryStore()
        let first = store.merge([GlossaryAddition(term: "leverage", translation: "рычаг")])
        XCTAssertEqual(first.added, 1)

        let second = store.merge([
            GlossaryAddition(term: "Leverage", translation: "кредитное плечо", note: "changed"),
        ])
        XCTAssertEqual(second.incremented, 1)
        XCTAssertEqual(second.added, 0)

        let entry = store.term(key: "leverage")!
        XCTAssertEqual(entry.count, 2)
        XCTAssertEqual(entry.translation, "рычаг")
        XCTAssertEqual(entry.note, "")
    }

    func testNewTermIsAddedWithFirstBlock() {
        var store = GlossaryStore()
        let outcome = store.merge(
            [GlossaryAddition(term: "KPI", translation: "ключевой показатель")],
            firstBlock: 42
        )
        XCTAssertEqual(outcome.added, 1)
        let entry = store.term(key: "kpi")!
        XCTAssertEqual(entry.firstBlock, 42)
        XCTAssertEqual(entry.count, 1)
        XCTAssertEqual(entry.source, .auto)
        XCTAssertEqual(entry.kind, .term)
    }

    func testDuplicateAdditionsInOneCallIncrementCount() {
        var store = GlossaryStore()
        let outcome = store.merge([
            GlossaryAddition(term: "churn", translation: "отток"),
            GlossaryAddition(term: "churn", translation: "отток"),
        ])
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.incremented, 1)
        XCTAssertEqual(store.term(key: "churn")!.count, 2)
    }

    func testEmptyTermOrTranslationIsIgnored() {
        var store = GlossaryStore()
        let outcome = store.merge([
            GlossaryAddition(term: "   ", translation: "нечто"),
            GlossaryAddition(term: "", translation: "нечто"),
            GlossaryAddition(term: "ok", translation: "   "),
            GlossaryAddition(term: "ok2", translation: ""),
        ])
        XCTAssertEqual(outcome, GlossaryMergeOutcome())
        XCTAssertTrue(store.glossary.isEmpty)
    }

    func testSetUserTermFlipsAutoEntryToUser() {
        var store = GlossaryStore()
        store.merge([GlossaryAddition(term: "roadmap", translation: "дорожная карта")])
        XCTAssertEqual(store.term(key: "roadmap")!.source, .auto)

        let updated = store.setUserTerm(
            term: "roadmap",
            translation: "план развития",
            note: "user note",
            kind: .name
        )
        XCTAssertEqual(updated.source, .user)
        XCTAssertEqual(updated.translation, "план развития")
        XCTAssertEqual(updated.note, "user note")
        XCTAssertEqual(updated.kind, .name)
        XCTAssertEqual(store.term(key: "roadmap")!.source, .user)
    }

    func testRemoveReturnsTrueThenFalse() {
        var store = GlossaryStore()
        store.merge([GlossaryAddition(term: "ROI", translation: "рент.")])
        XCTAssertTrue(store.remove(key: "roi"))
        XCTAssertNil(store.term(key: "roi"))
        XCTAssertFalse(store.remove(key: "roi"))
    }

    func testAffectedBatchesRequiresWholeWordMatch() {
        let plan = makePlan([
            ["The ROISTER club gathered at dawn"],
            ["Our ROI grew this quarter"],
            ["Net (ROI), adjusted for tax"],
        ])
        let store = GlossaryStore()
        XCTAssertEqual(store.affectedBatches(of: "ROI", in: plan), [1, 2])
    }

    func testAffectedBatchesIsCaseInsensitive() {
        let plan = makePlan([
            ["Nothing relevant here"],
            ["The ROI outlook is positive"],
        ])
        let store = GlossaryStore()
        XCTAssertEqual(store.affectedBatches(of: "roi", in: plan), [1])
        XCTAssertEqual(store.affectedBatches(of: "Roi", in: plan), [1])
    }

    func testAffectedBatchesRejectsBlankTerm() {
        let plan = makePlan([["ROI everywhere"]])
        let store = GlossaryStore()
        XCTAssertEqual(store.affectedBatches(of: "", in: plan), [])
        XCTAssertEqual(store.affectedBatches(of: "   ", in: plan), [])
    }

    func testBatchesContainingDedupesAcrossTerms() {
        let plan = makePlan([
            ["ROI and margin improved"],
            ["nothing relevant"],
            ["marginal gains"],
            ["a margin call"],
        ])
        let store = GlossaryStore()
        XCTAssertEqual(
            store.batchesContaining(anyOf: ["ROI", "roi", "margin"], in: plan),
            [0, 3]
        )
    }

    func testFirstBlockFillsInOnlyOnce() {
        var store = GlossaryStore()
        store.merge([GlossaryAddition(term: "alpha", translation: "альфа")])
        XCTAssertEqual(store.term(key: "alpha")!.firstBlock, -1)
        store.merge([GlossaryAddition(term: "alpha", translation: "альфа")], firstBlock: 7)
        XCTAssertEqual(store.term(key: "alpha")!.firstBlock, 7)
        store.merge([GlossaryAddition(term: "alpha", translation: "альфа")], firstBlock: 9)
        XCTAssertEqual(store.term(key: "alpha")!.firstBlock, 7)
    }

    func testSortedTermsOrdersByCountThenTerm() {
        var store = GlossaryStore()
        store.merge([GlossaryAddition(term: "b", translation: "б")])
        store.merge([GlossaryAddition(term: "a", translation: "а")])
        store.merge([GlossaryAddition(term: "a", translation: "а")])
        XCTAssertEqual(store.sortedTerms.map(\.term), ["a", "b"])
    }
}
