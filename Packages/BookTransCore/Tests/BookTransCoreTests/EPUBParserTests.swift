import XCTest
@testable import BookTransCore
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

final class EPUBParserTests: XCTestCase {
    private var root: URL!
    private var images: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("booktrans-epub-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("unpacked", isDirectory: true)
        images = base.appendingPathComponent("parsed/images", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Fixture

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func writeBytes(_ relativePath: String, _ bytes: [UInt8]) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    /// A small but structurally complete EPUB 3 with a nav document, two spine
    /// items, an inline image, a table and a cover.
    private func buildFixture(includeNav: Bool = true, includeCover: Bool = true) throws {
        try write("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """)

        var manifestItems = [
            "<item id=\"ch1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/>",
            "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/>",
        ]
        if includeNav {
            manifestItems.insert(
                "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
                at: 0)
        }
        if includeCover {
            manifestItems.append(
                "<item id=\"cover-image\" href=\"images/cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
        }

        try write("OEBPS/content.opf", """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>The Lean Startup</dc:title>
            <dc:creator>Eric Ries</dc:creator>
            <dc:language>EN</dc:language>
            <meta name="cover" content="cover-image"/>
          </metadata>
          <manifest>
            \(manifestItems.joined(separator: "\n    "))
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """)

        if includeNav {
            try write("OEBPS/nav.xhtml", """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Contents</title></head>
            <body>
              <nav epub:type="toc">
                <ol>
                  <li><a href="ch1.xhtml">Глава первая</a></li>
                  <li><a href="ch2.xhtml#start">Глава вторая</a></li>
                </ol>
              </nav>
              <nav epub:type="landmarks"><ol><li><a href="ch1.xhtml">Start</a></li></ol></nav>
            </body>
            </html>
            """)
        }

        try write("OEBPS/ch1.xhtml", """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Should be skipped</title><style>p{color:red}</style></head>
        <body>
          <h1>CHAPTER ONE</h1>
          <p>Hello <em>world</em>, this is &amp; a test.</p>
          <p><img src="images/fig1.png" alt="figure"/></p>
          <table><tr><td>cell one</td></tr></table>
        </body>
        </html>
        """)

        try write("OEBPS/ch2.xhtml", """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body><p>Second chapter text.</p></body>
        </html>
        """)

        try writeBytes("OEBPS/images/fig1.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if includeCover {
            try writeBytes("OEBPS/images/cover.jpg", [0xFF, 0xD8, 0xFF, 0xE0])
        }
    }

    private func parse() throws -> EPUBParseResult {
        try EPUBParser.parse(root: root, imagesDirectory: images)
    }

    // MARK: - Container and metadata

    func testMissingContainerIsRejected() {
        XCTAssertThrowsError(try parse()) { error in
            guard case EPUBParserError.missingContainer = error else {
                return XCTFail("expected missingContainer, got \(error)")
            }
        }
    }

    func testMetadataIsReadAndLanguageLowercased() throws {
        try buildFixture()
        let result = try parse()
        XCTAssertEqual(result.title, "The Lean Startup")
        XCTAssertEqual(result.author, "Eric Ries")
        XCTAssertEqual(result.language, "en")
    }

    func testMissingRootfileIsReported() throws {
        try write("META-INF/container.xml", """
        <container><rootfiles><rootfile full-path="missing.opf"/></rootfiles></container>
        """)
        XCTAssertThrowsError(try parse()) { error in
            guard case EPUBParserError.missingRootfile(let path) = error else {
                return XCTFail("expected missingRootfile, got \(error)")
            }
            XCTAssertEqual(path, "missing.opf")
        }
    }

    // MARK: - Chapters

    func testSpineOrderDefinesChaptersAndNavProvidesTitles() throws {
        try buildFixture()
        let result = try parse()
        XCTAssertEqual(result.chapters.map(\.title), ["Глава первая", "Глава вторая"])
        XCTAssertEqual(result.chapters.map(\.docHref), ["OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml"])
        XCTAssertEqual(result.chapters.map(\.index), [0, 1])
    }

    func testNavFragmentIsIgnoredWhenMatchingSpineDocuments() throws {
        try buildFixture()
        let result = try parse()
        XCTAssertEqual(result.chapters[1].title, "Глава вторая",
                       "a TOC entry with a #fragment must still match its document")
    }

    func testLandmarksNavDoesNotOverrideTheTOC() throws {
        try buildFixture()
        let result = try parse()
        XCTAssertEqual(result.chapters[0].title, "Глава первая", "landmarks must not be read as the TOC")
    }

    func testWithoutNavTheFirstHeadingNamesTheChapter() throws {
        try buildFixture(includeNav: false)
        let result = try parse()
        XCTAssertEqual(result.chapters[0].title, "CHAPTER ONE")
        XCTAssertEqual(result.chapters[1].title, "Глава 2", "no heading and no TOC → positional title")
    }

    // MARK: - Blocks

    func testBlocksAreExtractedWithHeadingsImagesAndTables() throws {
        try buildFixture()
        let result = try parse()
        let blocks = result.chapters[0].blocks
        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph, .image, .table])
        XCTAssertEqual(blocks[0].text, "CHAPTER ONE")
        XCTAssertEqual(blocks[1].text, "Hello world, this is & a test.")
        XCTAssertEqual(blocks[1].html, "Hello <em>world</em>, this is &amp; a test.")
        XCTAssertEqual(blocks[3].rawHTML, "<table><tr><td>cell one</td></tr></table>")
    }

    func testHeadElementContentIsDropped() throws {
        try buildFixture()
        let result = try parse()
        XCTAssertFalse(result.chapters[0].blocks.contains { $0.text.contains("Should be skipped") })
    }

    func testImageIsCopiedAndNamedByArchivePathHash() throws {
        try buildFixture()
        let result = try parse()
        let image = try XCTUnwrap(result.chapters[0].blocks.first { $0.kind == .image })
        let expectedName = SHA1.hexDigest("OEBPS/images/fig1.png") + ".png"
        XCTAssertEqual(image.imageRef, "images/\(expectedName)")

        let copied = images.appendingPathComponent(expectedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(FileStore.readData(copied), FileStore.readData(root.appendingPathComponent("OEBPS/images/fig1.png")))
    }

    func testMissingImageIsWarnedAndProducesNoBlock() throws {
        try buildFixture()
        try write("OEBPS/ch2.xhtml", """
        <html><body><p>Text.</p><img src="images/nope.png"/></body></html>
        """)
        let result = try parse()
        XCTAssertFalse(result.chapters[1].blocks.contains { $0.kind == .image })
        XCTAssertTrue(result.warnings.contains { $0.contains("nope.png") }, "\(result.warnings)")
    }

    func testImagePointingOutsideTheBookIsRefused() throws {
        try buildFixture()
        try write("OEBPS/ch2.xhtml", """
        <html><body><p>Text.</p><img src="../../../../etc/passwd"/></body></html>
        """)
        let result = try parse()
        XCTAssertFalse(result.chapters[1].blocks.contains { $0.kind == .image })
        XCTAssertTrue(result.warnings.contains { $0.contains("escapes") }, "\(result.warnings)")
    }

    // MARK: - Cover

    func testCoverIsCopiedFromTheManifest() throws {
        try buildFixture()
        let result = try parse()
        XCTAssertEqual(result.coverPath, "parsed/images/cover.jpg")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: images.appendingPathComponent("cover.jpg").path))
    }

    func testWithoutACoverNothingIsInvented() throws {
        try buildFixture(includeCover: false)
        let result = try parse()
        XCTAssertNil(result.coverPath)
    }

    func testCoverFallsBackToTheFirstManifestImage() throws {
        try buildFixture(includeCover: false)
        // Drop the meta[name=cover] that the fixture writes and add a plain image item.
        let opfURL = root.appendingPathComponent("OEBPS/content.opf")
        var opf = String(data: try Data(contentsOf: opfURL), encoding: .utf8)!
        opf = opf.replacingOccurrences(
            of: "<meta name=\"cover\" content=\"cover-image\"/>", with: "")
        opf = opf.replacingOccurrences(
            of: "</manifest>",
            with: "<item id=\"fig\" href=\"images/fig1.png\" media-type=\"image/png\"/></manifest>")
        try Data(opf.utf8).write(to: opfURL)

        let result = try parse()
        XCTAssertEqual(result.coverPath, "parsed/images/cover.png",
                       "the first image in the manifest is the cover when none is declared")
    }

    // MARK: - Failure modes

    func testEpubWithoutTextDocumentsIsRejected() throws {
        try buildFixture()
        try write("OEBPS/ch1.xhtml", "<html><body></body></html>")
        try write("OEBPS/ch2.xhtml", "<html><body></body></html>")
        XCTAssertThrowsError(try parse()) { error in
            guard case EPUBParserError.noTextDocuments = error else {
                return XCTFail("expected noTextDocuments, got \(error)")
            }
        }
    }

    func testUnknownSpineIdrefIsWarnedAndSkipped() throws {
        try buildFixture()
        let opfURL = root.appendingPathComponent("OEBPS/content.opf")
        var opf = String(data: try Data(contentsOf: opfURL), encoding: .utf8)!
        opf = opf.replacingOccurrences(of: "<itemref idref=\"ch2\"/>",
                                       with: "<itemref idref=\"ch2\"/><itemref idref=\"ghost\"/>")
        try Data(opf.utf8).write(to: opfURL)

        let result = try parse()
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("ghost") }, "\(result.warnings)")
    }

    func testDocumentWithUpperCasedSpineExtensionAndNoMediaTypeIsStillRead() throws {
        try buildFixture(includeNav: false)
        let opfURL = root.appendingPathComponent("OEBPS/content.opf")
        var opf = String(data: try Data(contentsOf: opfURL), encoding: .utf8)!
        opf = opf.replacingOccurrences(
            of: "<item id=\"ch2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/>",
            with: "<item id=\"ch2\" href=\"ch2.HTML\"/>")
        try Data(opf.utf8).write(to: opfURL)
        try write("OEBPS/ch2.HTML", "<html><body><p>Second chapter text.</p></body></html>")

        let result = try parse()
        XCTAssertEqual(result.chapters.count, 2)
        XCTAssertEqual(result.chapters[1].docHref, "OEBPS/ch2.HTML")
    }

    // MARK: - EPUB 2 NCX

    func testNcxProvidesTitlesWhenThereIsNoNavDocument() throws {
        try buildFixture(includeNav: false)
        try write("OEBPS/toc.ncx", """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint id="n1"><navLabel><text>Первая</text></navLabel><content src="ch1.xhtml"/></navPoint>
            <navPoint id="n2"><navLabel><text>Вторая</text></navLabel><content src="ch2.xhtml#top"/></navPoint>
          </navMap>
        </ncx>
        """)
        let opfURL = root.appendingPathComponent("OEBPS/content.opf")
        var opf = String(data: try Data(contentsOf: opfURL), encoding: .utf8)!
        opf = opf.replacingOccurrences(
            of: "</manifest>",
            with: "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/></manifest>")
        try Data(opf.utf8).write(to: opfURL)

        let result = try parse()
        XCTAssertEqual(result.chapters.map(\.title), ["Первая", "Вторая"],
                       "a fragment in the NCX src must still match the spine document")
    }
}

final class EPUBUnpackerTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("booktrans-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Path guard

    func testEntryPathGuard() {
        XCTAssertTrue(EPUBUnpacker.isSafeEntryPath("META-INF/container.xml"))
        XCTAssertTrue(EPUBUnpacker.isSafeEntryPath("OEBPS/images/cover.jpg"))
        XCTAssertFalse(EPUBUnpacker.isSafeEntryPath("/etc/passwd"), "absolute path")
        XCTAssertFalse(EPUBUnpacker.isSafeEntryPath("../evil.txt"))
        XCTAssertFalse(EPUBUnpacker.isSafeEntryPath("OEBPS/../../evil.txt"))
        XCTAssertFalse(EPUBUnpacker.isSafeEntryPath("..\\evil.txt"), "windows separator")
        XCTAssertFalse(EPUBUnpacker.isSafeEntryPath(""), "empty path")
        XCTAssertTrue(EPUBUnpacker.isSafeEntryPath("a..b/c.txt"), "two dots inside a name are fine")
    }

    // MARK: - Real archives

    #if canImport(ZIPFoundation)
    private func makeArchive(_ entries: [(String, String)]) throws -> URL {
        let url = base.appendingPathComponent("book-\(UUID().uuidString).epub")
        let archive = try XCTUnwrap(Archive(url: url, accessMode: .create))
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count),
                                 provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
        }
        return url
    }

    func testRealArchiveIsExtracted() throws {
        let archive = try makeArchive([
            ("META-INF/container.xml", "<container/>"),
            ("OEBPS/content.opf", "<package/>"),
        ])
        let destination = base.appendingPathComponent("out", isDirectory: true)
        try EPUBUnpacker.unpack(archive: archive, to: destination)

        for path in ["META-INF/container.xml", "OEBPS/content.opf"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(path).path), "missing \(path)")
        }
        XCTAssertEqual(EPUBParser.firstRootfilePath(in: "<container/>"), nil)
    }

    func testRealArchiveWithTraversalEntryIsRefusedBeforeWritingAnything() throws {
        let archive = try makeArchive([
            ("META-INF/container.xml", "<container/>"),
            ("../escaped.txt", "nope"),
        ])
        let destination = base.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(try EPUBUnpacker.unpack(archive: archive, to: destination)) { error in
            guard case EPUBUnpackError.unsafeEntryPath(let path) = error else {
                return XCTFail("expected unsafeEntryPath, got \(error)")
            }
            XCTAssertEqual(path, "../escaped.txt")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("escaped.txt").path),
            "nothing may be written outside the destination")
    }

    func testMissingArchiveIsReportedNotCrashed() throws {
        let destination = base.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(try EPUBUnpacker.unpack(
            archive: base.appendingPathComponent("nope.epub"), to: destination)) { error in
            guard case EPUBUnpackError.extractionFailed = error else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        }
    }
    #endif
}
