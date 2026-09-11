import XCTest
import BookTransCore
@testable import BookTrans

/// The sandbox layout is a contract the whole app depends on, and `AppState`
/// bootstrap is the only thing that creates it. These tests pin the observable
/// behaviour: after a fresh launch the directories exist, and library contents
/// on disk are what the home screen shows.
@MainActor
final class AppStateLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("booktrans-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBootstrapCreatesSandboxDirectories() throws {
        let app = AppState(docsRoot: root)
        let fm = FileManager.default
        for dir in [app.paths.booksDir, app.paths.configDir, app.paths.logsDir] {
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: dir.path, isDirectory: &isDir), "missing \(dir.path)")
            XCTAssertTrue(isDir.boolValue)
        }
    }

    func testLibraryReflectsEntriesWrittenToDisk() throws {
        let app = AppState(docsRoot: root)
        XCTAssertTrue(app.entries.isEmpty)

        let entry = LibraryEntry(
            id: "b1", title: "Dune", author: "Frank Herbert",
            batchesDone: 3, batchesTotal: 20, status: .running, lastOpenedAt: Date())
        app.library.upsert(entry)
        app.reloadLibrary()

        XCTAssertEqual(app.entries.map(\.id), ["b1"])
        XCTAssertEqual(app.entries.first?.title, "Dune")
        XCTAssertEqual(app.entries.first?.batchesDone, 3)
    }

    func testLibrarySortsNewestOpenedFirst() throws {
        let app = AppState(docsRoot: root)
        let old = LibraryEntry(id: "old", title: "Old", author: "",
                               lastOpenedAt: Date(timeIntervalSince1970: 1_000))
        let new = LibraryEntry(id: "new", title: "New", author: "",
                               lastOpenedAt: Date(timeIntervalSince1970: 2_000))
        app.library.upsert(old)
        app.library.upsert(new)
        app.reloadLibrary()

        XCTAssertEqual(app.entries.map(\.id), ["new", "old"])
    }

    func testCorruptLibraryFileDoesNotBlockLaunch() throws {
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("library.json"))
        let app = AppState(docsRoot: root)
        XCTAssertTrue(app.entries.isEmpty)
    }
}
