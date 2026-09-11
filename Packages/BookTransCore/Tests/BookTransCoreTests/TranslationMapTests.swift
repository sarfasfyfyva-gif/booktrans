import XCTest
@testable import BookTransCore

/// `TranslationMap` decides what the reader shows as Russian. The rule from the
/// spec is that a block is only translated once *all* of its units are in, so
/// that a partly translated paragraph never renders as a half-Russian mix.
final class TranslationMapTests: XCTestCase {
    private func plan(_ batches: [(Int, [PlanUnit])], done: Set<Int> = []) -> BatchPlan {
        BatchPlan(target: 4000, totalChars: 0, batches: batches.map { index, units in
            Batch(index: index,
                  chars: units.reduce(0) { $0 + $1.text.count },
                  status: done.contains(index) ? .done : .pending,
                  units: units)
        })
    }

    func testSingleUnitBlockUsesTranslation() {
        let plan = plan([(0, [PlanUnit(block: 5, part: 0, text: "hello")])], done: [0])
        let map = TranslationMap(plan: plan, results: [0: BatchResult(index: 0, modelId: "m",
                                                                     translations: ["привет"])])
        XCTAssertEqual(map.translatedText(for: 5), "привет")
    }

    func testSplitBlockJoinsPartsInPartOrderWithSpace() {
        // Units deliberately listed out of `part` order to prove sorting is by part.
        let plan = plan([(0, [
            PlanUnit(block: 9, part: 1, text: "second half"),
            PlanUnit(block: 9, part: 0, text: "first half"),
        ])], done: [0])
        let map = TranslationMap(plan: plan, results: [
            0: BatchResult(index: 0, modelId: "m", translations: ["вторая часть", "первая часть"])
        ])
        XCTAssertEqual(map.translatedText(for: 9), "первая часть вторая часть")
    }

    func testPartiallyTranslatedBlockFallsBackToNil() {
        let plan = plan([
            (0, [PlanUnit(block: 3, part: 0, text: "a")]),
            (1, [PlanUnit(block: 3, part: 1, text: "b")]),
        ], done: [0])
        let map = TranslationMap(plan: plan, results: [
            0: BatchResult(index: 0, modelId: "m", translations: ["А"]),
        ])
        XCTAssertNil(map.translatedText(for: 3), "half a block must not render as translation")
        XCTAssertTrue(map.hasAnyTranslation(for: 3))
        XCTAssertEqual(map.untranslatedBlockIds, [3])
    }

    func testResultWithWrongTranslationCountIsIgnored() {
        let plan = plan([(0, [PlanUnit(block: 1, part: 0, text: "a"),
                              PlanUnit(block: 2, part: 0, text: "b")])], done: [0])
        let map = TranslationMap(plan: plan, results: [
            0: BatchResult(index: 0, modelId: "m", translations: ["only one"]),
        ])
        XCTAssertNil(map.translatedText(for: 1))
        XCTAssertNil(map.translatedText(for: 2))
        XCTAssertTrue(map.isEmpty)
    }

    func testBlocksAbsentFromPlanHaveNoTranslation() {
        let map = TranslationMap(plan: plan([]), results: [:])
        XCTAssertNil(map.translatedText(for: 42))
        XCTAssertFalse(map.hasAnyTranslation(for: 42))
    }

    func testUntranslatedBlockIdsAreAscendingAndOnlyCoverPlan() {
        let plan = plan([(0, [PlanUnit(block: 7, part: 0, text: "x"),
                              PlanUnit(block: 2, part: 0, text: "y")]),
                         (1, [PlanUnit(block: 5, part: 0, text: "z")])], done: [0])
        let map = TranslationMap(plan: plan, results: [
            0: BatchResult(index: 0, modelId: "m", translations: ["X", "Y"]),
        ])
        XCTAssertEqual(map.untranslatedBlockIds, [5])
        XCTAssertEqual(map.doneBatchCount, 1)
        XCTAssertEqual(map.totalBatchCount, 2)
    }
}
