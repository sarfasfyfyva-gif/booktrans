import XCTest
import BookTransCore
@testable import BookTrans

/// The empty-state hint promises that a file copied into the app's folder is
/// picked up on its own. These pin the discovery rules that make that true, and
/// the retirement that stops a file being imported twice.
final class DroppedBookScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("booktrans-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ name: String, in subdirectory: String = "") throws {
        let directory = subdirectory.isEmpty
            ? root!
            : root.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    // MARK: - Naming

    func testRecognisesBookFiles() {
        XCTAssertTrue(DroppedBookScanner.isBookLike("book.fb2"))
        XCTAssertTrue(DroppedBookScanner.isBookLike("book.FB2"))
        XCTAssertTrue(DroppedBookScanner.isBookLike("book.epub"))
        XCTAssertTrue(DroppedBookScanner.isBookLike("book.fb2.zip"),
                      "the common Russian distribution form")
        XCTAssertTrue(DroppedBookScanner.isBookLike("book.FB2.ZIP"))
    }

    func testIgnoresEverythingElse() {
        XCTAssertFalse(DroppedBookScanner.isBookLike("notes.txt"))
        XCTAssertFalse(DroppedBookScanner.isBookLike("archive.zip"),
                       "a bare zip is not guessed at: it would turn a stray archive into an error")
        XCTAssertFalse(DroppedBookScanner.isBookLike("book.pdf"),
                       "PDF is not a format this app reads")
        XCTAssertFalse(DroppedBookScanner.isBookLike("book.fb2.txt"))
        XCTAssertFalse(DroppedBookScanner.isBookLike("fb2"))
    }

    // MARK: - Discovery

    func testFindsBooksInBothScannedDirectories() throws {
        try put("a.epub")
        try put("b.fb2", in: "Inbox")
        try put("ignore.txt", in: "Inbox")
        try put("old.epub", in: "Imported")
        try put("nested.epub", in: "SomeFolder")

        let found = DroppedBookScanner.candidates(docsRoot: root).map(\.lastPathComponent)
        XCTAssertEqual(found, ["a.epub", "b.fb2"],
                       "Inbox is scanned, Imported and other folders are not")
    }

    func testHiddenFilesAreIgnored() throws {
        try put(".DS_Store")
        try put(".hidden.epub")
        try put("real.epub")
        XCTAssertEqual(DroppedBookScanner.candidates(docsRoot: root).map(\.lastPathComponent),
                       ["real.epub"])
    }

    func testDirectoriesThatLookLikeBooksAreNotFiles() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder.epub"), withIntermediateDirectories: true)
        XCTAssertTrue(DroppedBookScanner.candidates(docsRoot: root).isEmpty)
    }

    func testOrderIsDeterministic() throws {
        try put("c.epub")
        try put("a.epub")
        try put("b.fb2")
        XCTAssertEqual(DroppedBookScanner.candidates(docsRoot: root).map(\.lastPathComponent),
                       ["a.epub", "b.fb2", "c.epub"])
    }

    // MARK: - Retirement

    func testRetireMovesTheFileOutOfTheScanPath() throws {
        try put("book.epub")
        let original = root.appendingPathComponent("book.epub")

        DroppedBookScanner.retire(original, docsRoot: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Imported/book.epub").path))
        XCTAssertTrue(DroppedBookScanner.candidates(docsRoot: root).isEmpty,
                      "a handled file must never be imported twice")
    }

    func testRetireReplacesAnEarlierFileOfTheSameName() throws {
        try put("book.epub")
        try put("book.epub", in: "Imported")
        let original = root.appendingPathComponent("book.epub")

        DroppedBookScanner.retire(original, docsRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Imported/book.epub").path))
        XCTAssertTrue(DroppedBookScanner.candidates(docsRoot: root).isEmpty)
    }
}
