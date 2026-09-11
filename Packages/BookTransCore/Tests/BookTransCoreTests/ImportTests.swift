import XCTest
@testable import BookTransCore

final class FB2ParserTests: XCTestCase {
    private let fullBook = """
    <?xml version="1.0" encoding="utf-8"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
      <description>
        <title-info>
          <genre>sf</genre>
          <author><first-name>Frank</first-name><middle-name>Patrick</middle-name><last-name>Herbert</last-name></author>
          <book-title>Dune</book-title>
          <lang>en</lang>
          <coverpage><image l:href="#cover.jpg"/></coverpage>
        </title-info>
        <document-info><author><nickname>scanner</nickname></author></document-info>
      </description>
      <body>
        <section>
          <title><p>Chapter One</p></title>
          <p>Hello <emphasis>world</emphasis> &amp; more.</p>
          <empty-line/>
          <subtitle>A subtitle</subtitle>
          <p><image l:href="#pic.png"/></p>
          <section>
            <title><p>Nested</p></title>
            <p>Inside nested.</p>
          </section>
        </section>
        <section>
          <title><p>Chapter Two</p></title>
          <p>Second chapter.</p>
          <table><tr><td>cell</td></tr></table>
        </section>
      </body>
      <body name="notes">
        <title><p>Notes</p></title>
        <section><p>A note.</p></section>
      </body>
      <binary id="cover.jpg" content-type="image/jpeg">QUJD</binary>
      <binary id="pic.png" content-type="image/png">REVG</binary>
    </FictionBook>
    """

    private func parse() throws -> FB2ParseResult {
        try FB2Parser.parse(text: fullBook)
    }

    // MARK: - Metadata

    func testMetadataIsRead() throws {
        let result = try parse()
        XCTAssertEqual(result.title, "Dune")
        XCTAssertEqual(result.author, "Frank Patrick Herbert")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.coverImageID, "cover.jpg")
        XCTAssertEqual(result.images.map(\.id), ["cover.jpg", "pic.png"])
        XCTAssertEqual(result.images.first?.contentType, "image/jpeg")
    }

    func testScannerNicknameIsNotTreatedAsAnAuthor() throws {
        let result = try parse()
        XCTAssertFalse(result.author.contains("scanner"),
                       "document-info authors are not book authors")
    }

    // MARK: - Chapters

    func testTopLevelSectionsBecomeChaptersAndNotesComeLast() throws {
        let result = try parse()
        XCTAssertEqual(result.chapters.map(\.title), ["Chapter One", "Chapter Two", "Notes"])
        XCTAssertEqual(result.chapters.map(\.index), [0, 1, 2])
        XCTAssertTrue(result.chapters.allSatisfy { $0.docHref.isEmpty },
                      "FB2 has no per-chapter document")
    }

    func testNestedSectionTitleBecomesAHeadingInsideTheChapter() throws {
        let result = try parse()
        let first = result.chapters[0]
        let headings = first.blocks.filter { $0.kind == .heading }.map(\.text)
        XCTAssertEqual(headings, ["Chapter One", "A subtitle", "Nested"],
                       "nested sections add headings but do not create chapters")
        XCTAssertEqual(result.chapters.count, 3)
    }

    func testTitleParagraphsInheritTheHeadingKind() throws {
        let result = try parse()
        XCTAssertEqual(result.chapters[0].blocks.first?.kind, .heading)
        XCTAssertEqual(result.chapters[0].blocks.first?.text, "Chapter One")
    }

    // MARK: - Blocks

    func testInlineMarkupAndEntities() throws {
        let result = try parse()
        let paragraph = try XCTUnwrap(result.chapters[0].blocks.first { $0.kind == .paragraph })
        XCTAssertEqual(paragraph.text, "Hello world & more.")
        XCTAssertEqual(paragraph.html, "Hello <em>world</em> &amp; more.")
    }

    func testEmptyLineProducesNoBlock() throws {
        let result = try parse()
        XCTAssertFalse(result.chapters[0].blocks.contains { $0.text.isEmpty && $0.kind == .paragraph },
                       "empty-line is a spacing device only")
    }

    func testTableBecomesOneUntranslatableBlockWithRawMarkup() throws {
        let result = try parse()
        let table = try XCTUnwrap(result.chapters[1].blocks.first { $0.kind == .table })
        XCTAssertEqual(table.rawHTML, "<table><tr><td>cell</td></tr></table>")
        XCTAssertFalse(table.kind.isTranslatable)
        XCTAssertTrue(table.text.isEmpty)
    }

    func testImageBlockResolvesAfterTheBinaryIsRead() throws {
        let result = try parse()
        let image = try XCTUnwrap(result.chapters[0].blocks.first { $0.kind == .image })
        XCTAssertEqual(image.imageRef, "images/pic.png",
                       "binaries follow the body, so refs must resolve at the end")
    }

    func testMissingImageIsWarnedAboutAndLeavesNoReference() throws {
        let xml = """
        <FictionBook><body><section><title><p>T</p></title>
        <p>Some text.</p><p><image l:href="#gone.png"/></p>
        </section></body></FictionBook>
        """
        let result = try FB2Parser.parse(text: xml)
        let image = try XCTUnwrap(result.chapters[0].blocks.first { $0.kind == .image })
        XCTAssertNil(image.imageRef)
        XCTAssertTrue(result.warnings.contains { $0.contains("gone.png") }, "\(result.warnings)")
    }

    func testBlockOrderFollowsTheDocument() throws {
        let result = try parse()
        let texts = result.chapters[0].blocks.map(\.text)
        XCTAssertEqual(texts, ["Chapter One", "Hello world & more.", "A subtitle",
                               "", "Nested", "Inside nested."])
    }

    // MARK: - Failure modes

    func testTextWithoutAnyBodyIsRejected() {
        XCTAssertThrowsError(try FB2Parser.parse(text: "<html><body></body></html>"))
        XCTAssertThrowsError(try FB2Parser.parse(text: "not xml at all"))
    }

    func testBookWithoutTranslatableTextIsRejected() {
        let xml = "<FictionBook><body><section><image href=\"#x\"/></section></body></FictionBook>"
        XCTAssertThrowsError(try FB2Parser.parse(text: xml)) { error in
            guard case FB2ParserError.notFB2 = error else {
                return XCTFail("expected notFB2, got \(error)")
            }
        }
    }

    // MARK: - Encoding

    func testWindows1251BytesAreDecoded() throws {
        let cyrillic: [UInt8] = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]   // "Привет"
        var data = Data(Array("<?xml version=\"1.0\" encoding=\"windows-1251\"?><FictionBook><body><section>".utf8))
        data.append(contentsOf: Array("<p>".utf8))
        data.append(contentsOf: cyrillic)
        data.append(contentsOf: Array("</p></section></body></FictionBook>".utf8))

        let result = try FB2Parser.parse(data: data)
        XCTAssertEqual(result.chapters.first?.blocks.first?.text, "Привет")
        XCTAssertTrue(result.warnings.contains { $0.contains("windows-1251") },
                      "the encoding used must be recorded: \(result.warnings)")
    }

    // MARK: - Image naming

    func testImageFileNames() {
        XCTAssertEqual(FB2Parser.fileName(for: FB2Image(id: "cover.jpg", contentType: "image/jpeg", base64: "")),
                       "cover.jpg")
        XCTAssertEqual(FB2Parser.fileName(for: FB2Image(id: "pic", contentType: "image/png", base64: "")),
                       "pic.png")
        // The security property, not the exact spelling: an id from the file can
        // never escape the images directory.
        let traversal = FB2Parser.fileName(
            for: FB2Image(id: "../../etc/passwd", contentType: "image/jpeg", base64: ""))
        XCTAssertFalse(traversal.contains("/"), traversal)
        XCTAssertFalse(traversal.hasPrefix("."), traversal)
        XCTAssertTrue(traversal.hasSuffix(".jpg"), traversal)
        XCTAssertEqual(FB2Parser.fileName(for: FB2Image(id: "..", contentType: "", base64: "")), "image.jpg")
        XCTAssertEqual(FB2Parser.fileName(for: FB2Image(id: "", contentType: "", base64: "")), "image.jpg")
    }
}

final class HTMLBlockExtractorTests: XCTestCase {
    private func extract(_ markup: String, resolver: ((String) -> String?)? = nil) -> BlockExtractionResult {
        HTMLBlockExtractor.extract(markup, options: .init(imageResolver: resolver))
    }

    func testNestedDivsProduceOneBlockPerTextRun() {
        let result = extract("<body><div>Outer text<p>Inner text</p>Tail</div></body>")
        XCTAssertEqual(result.blocks.map(\.text), ["Outer text", "Inner text", "Tail"])
        XCTAssertEqual(result.blocks.map(\.id), [0, 1, 2])
    }

    func testNestedListItemKeepsDocumentOrder() {
        let result = extract("<ul><li>first<ul><li>second</li></ul></li></ul>")
        XCTAssertEqual(result.blocks.map(\.text), ["first", "second"])
        XCTAssertEqual(result.blocks.map(\.kind), [.listItem, .listItem])
    }

    func testHeadingsAreRecognizedAndTheFirstOneNamesTheDocument() {
        let result = extract("<body><h1>Chapter 1</h1><p>Text</p><h2>Section</h2></body>")
        XCTAssertEqual(result.blocks.map(\.kind), [.heading, .paragraph, .heading])
        XCTAssertEqual(result.firstHeading, "Chapter 1")
    }

    func testScriptStyleAndHeadAreDropped() {
        let result = extract("""
        <html><head><title>hidden</title><style>p{color:red}</style></head>
        <body><p>visible</p><script>var x = "<p>fake</p>";</script></body></html>
        """)
        XCTAssertEqual(result.blocks.map(\.text), ["visible"])
    }

    func testTableIsCapturedVerbatimIncludingNestedTables() {
        let markup = "<body><p>before</p><table class=\"t\"><tr><td>a</td>"
            + "<td><table><tr><td>b</td></tr></table></td></tr></table><p>after</p></body>"
        let result = extract(markup)
        XCTAssertEqual(result.blocks.map(\.kind), [.paragraph, .table, .paragraph])
        let table = result.blocks[1]
        XCTAssertEqual(table.rawHTML, "<table class=\"t\"><tr><td>a</td>"
            + "<td><table><tr><td>b</td></tr></table></td></tr></table>",
            "nested tables must not end the capture early")
        XCTAssertFalse(table.kind.isTranslatable)
    }

    func testImageUsesTheResolverAndIsSkippedWhenMissing() {
        var events: [String] = []
        let result = extract("<body><p>a</p><img src=\"images/x.png\"/><img src=\"missing.png\"/></body>") { source in
            events.append(source)
            return source.hasSuffix("x.png") ? "images/hash.png" : nil
        }
        XCTAssertEqual(events, ["images/x.png", "missing.png"])
        let image = result.blocks.first { $0.kind == .image }
        XCTAssertEqual(image?.imageRef, "images/hash.png")
        XCTAssertEqual(result.blocks.filter { $0.kind == .image }.count, 1)
    }

    func testInlineMarkupIsPreservedAndNormalized() {
        let result = extract("<p>a <i>i</i> <b>b</b> <del>d</del> <code>c</code> "
            + "<sup>2</sup> <a href=\"http://x/?a=1&amp;b=2\">link</a></p>")
        XCTAssertEqual(result.blocks[0].html,
                       "a <em>i</em> <strong>b</strong> <s>d</s> <code>c</code> "
                       + "<sup>2</sup> <a href=\"http://x/?a=1&amp;b=2\">link</a>")
        XCTAssertEqual(result.blocks[0].text, "a i b d c 2 link")
    }

    func testTextDirectlyInBodyBecomesAParagraph() {
        let result = extract("<body>Loose text</body>")
        XCTAssertEqual(result.blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(result.blocks.first?.text, "Loose text")
    }

    func testEntitiesAndWhitespaceAreCollapsed() {
        let result = extract("<p>a\n\n   b&nbsp;&mdash;&nbsp;c &#1055;</p>")
        XCTAssertEqual(result.blocks.first?.text, "a b — c П")
    }

    func testHrBecomesItsOwnBlockAndRepeatsAreCollapsed() {
        let result = extract("<p>a</p><hr/><hr/><p>b</p>")
        XCTAssertEqual(result.blocks.map(\.kind), [.paragraph, .hr, .paragraph])
    }

    func testBlockQuoteAndPreKeepTheirKinds() {
        let result = extract("<blockquote>quoted</blockquote><pre>code line</pre>")
        XCTAssertEqual(result.blocks.map(\.kind), [.blockquote, .paragraph])
        XCTAssertEqual(result.blocks.map(\.text), ["quoted", "code line"])
    }

    func testIdsAreContiguousStartingFromTheRequestedValue() {
        let result = HTMLBlockExtractor.extract("<p>a</p><p>b</p>", options: .init(firstBlockID: 100))
        XCTAssertEqual(result.blocks.map(\.id), [100, 101])
    }

    func testPlainTextWithoutTagsStillProducesAParagraph() {
        let result = extract("Just a line of text with no markup at all.")
        XCTAssertEqual(result.blocks.map(\.text), ["Just a line of text with no markup at all."])
    }
}
