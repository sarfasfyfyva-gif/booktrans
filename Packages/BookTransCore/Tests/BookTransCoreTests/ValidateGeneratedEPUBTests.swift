import XCTest
@testable import BookTransCore

/// Throwaway harness: parses a real EPUB through the shipping code path so the
/// app's own importer is the thing that validates it.
final class ValidateGeneratedEPUBTests: XCTestCase {
    func testGeneratedEPUBImportsCleanly() throws {
        let path = ProcessInfo.processInfo.environment["EPUB_TO_VALIDATE"] ?? ""
        try XCTSkipIf(path.isEmpty, "set EPUB_TO_VALIDATE")
        let source = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), source.path)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-validate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        let images = root.appendingPathComponent("images", isDirectory: true)

        try EPUBUnpacker.unpack(archive: source, to: unpacked)
        let result = try EPUBParser.parse(root: unpacked, imagesDirectory: images)

        print("VALIDATE title:    \(result.title)")
        print("VALIDATE author:   \(result.author)")
        print("VALIDATE language: \(result.language)")
        print("VALIDATE chapters: \(result.chapters.count)")
        print("VALIDATE warnings: \(result.warnings.count)")

        var blocks = 0
        var translatableChars = 0
        for chapter in result.chapters.prefix(30) {
            let kinds = Set(chapter.blocks.map(\.kind.rawValue)).sorted().joined(separator: ",")
            let chars = chapter.blocks.filter(\.kind.isTranslatable)
                .reduce(0) { $0 + $1.text.count }
            blocks += chapter.blocks.count
            translatableChars += chars
            print("VALIDATE  [\(chapter.index)] \(chapter.title.prefix(46)) "
                + "| blocks \(chapter.blocks.count) | chars \(chars) | \(kinds)")
        }
        print("VALIDATE total blocks: \(blocks), translatable chars: \(translatableChars)")

        // The plan makes the book's own structure the contract.
        XCTAssertGreaterThanOrEqual(result.chapters.count, 20)
        XCTAssertGreaterThan(translatableChars, 100_000, "a 385-page book must yield real text")

        // And the batch plan has to come out sensible, since that drives reading.
        let plan = Chunker.plan(chapters: result.chapters)
        print("VALIDATE batches: \(plan.batches.count), target \(plan.target)")
        XCTAssertGreaterThan(plan.batches.count, 5)
        let floor = Int(Double(plan.target) * Chunker.chapterCloseFactor)
        for batch in plan.batches.dropLast() {
            XCTAssertGreaterThanOrEqual(batch.chars, floor, "batch \(batch.index) below the floor")
        }

        // Every paragraph must be translatable-looking text, not stray markup.
        for chapter in result.chapters.prefix(5) {
            for block in chapter.blocks where block.kind == .paragraph {
                XCTAssertFalse(block.text.contains("<"), "markup leaked into '\(block.text.prefix(60))'")
            }
        }
    }
}
