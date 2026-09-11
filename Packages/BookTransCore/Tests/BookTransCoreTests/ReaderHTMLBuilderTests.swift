import XCTest
@testable import BookTransCore

/// The reader page is what the user actually looks at, and its two rules decide
/// whether a half-translated book reads correctly: a block appears translated
/// only when every part of it is in, and the switch back to the original is
/// announced once per run.
final class ReaderHTMLBuilderTests: XCTestCase {
    private func chapter(_ blocks: [Block]) -> Chapter {
        Chapter(index: 2, title: "T", docHref: "d.xhtml", blocks: blocks)
    }

    private func translations(_ pairs: [(Int, Int, String)], blocks: [Block]) -> TranslationMap {
        let units = pairs.map { PlanUnit(block: $0.0, part: $0.1, text: "source \($0.0)/\($0.1)") }
        let plan = BatchPlan(target: 4000, totalChars: 0, batches: [
            Batch(index: 0, chars: 0, status: .done, units: units)
        ])
        return TranslationMap(plan: plan, results: [
            0: BatchResult(index: 0, modelId: "m", translations: pairs.map(\.2))
        ])
    }

    // MARK: - Block rendering

    func testEveryBlockGetsAStableIdAndKind() {
        let blocks = [
            Block(id: 10, kind: .heading, text: "Заголовок"),
            Block(id: 11, kind: .paragraph, text: "Текст"),
            Block(id: 12, kind: .listItem, text: "Пункт"),
            Block(id: 13, kind: .blockquote, text: "Цитата"),
            Block(id: 14, kind: .note, text: "Сноска"),
        ]
        let html = ReaderHTMLBuilder.build(
            chapter: chapter(blocks), translations: TranslationMap(),
            configuration: .init(showTranslation: false))
        for block in blocks {
            XCTAssertTrue(html.contains("id=\"b\(block.id)\" data-kind=\"\(block.kind.rawValue)\""),
                          "missing block \(block.id) of kind \(block.kind)")
        }
    }

    func testOriginalModeRendersInlineMarkup() {
        let block = Block(id: 1, kind: .paragraph, text: "Hello world & more.",
                          html: "Hello <em>world</em> &amp; more.")
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([block]), translations: TranslationMap(),
            configuration: .init(showTranslation: false))
        XCTAssertTrue(html.contains("Hello <em>world</em> &amp; more."))
    }

    func testTranslationModeRendersEscapedPlainText() {
        let block = Block(id: 1, kind: .paragraph, text: "Hello")
        let map = translations([(1, 0, "Привет <b>мир</b>")], blocks: [block])
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([block]), translations: map, configuration: .init(showTranslation: true))
        XCTAssertTrue(html.contains("Привет &lt;b&gt;мир&lt;/b&gt;"),
                      "a translation is text, never markup")
        XCTAssertFalse(html.contains("Hello"))
    }

    func testTableRendersRawMarkupInBothModes() {
        let block = Block(id: 5, kind: .table, text: "", rawHTML: "<table><tr><td>cell</td></tr></table>")
        for showTranslation in [true, false] {
            let html = ReaderHTMLBuilder.build(
                chapter: chapter([block]), translations: TranslationMap(),
                configuration: .init(showTranslation: showTranslation))
            XCTAssertTrue(html.contains("<table><tr><td>cell</td></tr></table>"),
                          "tables are never translated (showTranslation: \(showTranslation))")
        }
    }

    func testImageSourceIsRewrittenForTheReaderDirectory() {
        let block = Block(id: 7, kind: .image, text: "", imageRef: "images/abc.jpg")
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([block]), translations: TranslationMap(),
            configuration: .init(showTranslation: true))
        XCTAssertTrue(html.contains("src=\"parsed/images/abc.jpg\""),
                      "reader.html lives in the book directory, images live under parsed/")
    }

    func testImageWithoutAReferenceRendersNothing() {
        let block = Block(id: 7, kind: .image, text: "", imageRef: nil)
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([block]), translations: TranslationMap(),
            configuration: .init(showTranslation: true))
        XCTAssertFalse(html.contains("id=\"b7\""), "an image with no file renders nothing")
    }

    func testHorizontalRuleRenders() {
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([Block(id: 3, kind: .hr, text: "")]),
            translations: TranslationMap(), configuration: .init(showTranslation: true))
        XCTAssertTrue(html.contains("data-kind=\"hr\""))
        XCTAssertTrue(html.contains("<hr>"))
    }

    func testEmptyBlockIsSkipped() {
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([Block(id: 4, kind: .paragraph, text: "", html: "")]),
            translations: TranslationMap(), configuration: .init(showTranslation: false))
        XCTAssertFalse(html.contains("id=\"b4\""))
    }

    // MARK: - Partial translation

    func testPartiallyTranslatedBlockShowsTheOriginal() {
        let block = Block(id: 1, kind: .paragraph, text: "Long text", html: "Long text")
        // Two parts exist, only one came back.
        let plan = BatchPlan(target: 4000, totalChars: 0, batches: [
            Batch(index: 0, chars: 0, status: .done, units: [PlanUnit(block: 1, part: 0, text: "a")]),
            Batch(index: 1, chars: 0, status: .pending, units: [PlanUnit(block: 1, part: 1, text: "b")]),
        ])
        let map = TranslationMap(plan: plan, results: [
            0: BatchResult(index: 0, modelId: "m", translations: ["первая половина"])
        ])
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([block]), translations: map, configuration: .init(showTranslation: true))
        XCTAssertTrue(html.contains("Long text"), "an incomplete block stays in the original")
        XCTAssertFalse(html.contains("первая половина"))
        XCTAssertTrue(html.contains(ReaderHTMLBuilder.untranslatedMarker))
    }

    func testMarkerIsEmittedOncePerContiguousRun() {
        let blocks = (0..<4).map { Block(id: $0, kind: .paragraph, text: "p\($0)") }
        let map = translations([(1, 0, "первый")], blocks: blocks)
        let html = ReaderHTMLBuilder.build(
            chapter: chapter(blocks), translations: map, configuration: .init(showTranslation: true))
        // Block 1 is translated; 0, 2 and 3 are not, in two runs (before and after).
        let markerCount = html.components(separatedBy: ReaderHTMLBuilder.untranslatedMarker).count - 1
        XCTAssertEqual(markerCount, 2, "one marker before block 0 and one before block 2")
    }

    func testMarkerIsAbsentWhenEverythingIsTranslated() {
        let blocks = [Block(id: 0, kind: .paragraph, text: "a"), Block(id: 1, kind: .paragraph, text: "b")]
        let map = translations([(0, 0, "А"), (1, 0, "Б")], blocks: blocks)
        let html = ReaderHTMLBuilder.build(
            chapter: chapter(blocks), translations: map, configuration: .init(showTranslation: true))
        XCTAssertFalse(html.contains(ReaderHTMLBuilder.untranslatedMarker))
    }

    func testOriginalModeNeverShowsTheMarker() {
        let blocks = [Block(id: 0, kind: .paragraph, text: "a")]
        let html = ReaderHTMLBuilder.build(
            chapter: chapter(blocks), translations: TranslationMap(),
            configuration: .init(showTranslation: false))
        XCTAssertFalse(html.contains(ReaderHTMLBuilder.untranslatedMarker),
                       "the whole page is the original, so no switch notice is needed")
    }

    // MARK: - Document shape

    func testDocumentCarriesTheViewportAndTheBridge() {
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([Block(id: 0, kind: .paragraph, text: "a")]),
            translations: TranslationMap(), configuration: .init())
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("user-scalable=no"))
        XCTAssertTrue(html.contains("<article id=\"book\" data-chapter=\"2\">"))
        XCTAssertTrue(html.contains("window.Reader = {"))
        for method in ["position()", "restore(block, dy)", "style(fontSize, lineHeight, margin)"] {
            XCTAssertTrue(html.contains(method), "missing bridge method \(method)")
        }
    }

    func testConfigurationIsBakedIntoTheStylesheet() {
        let html = ReaderHTMLBuilder.build(
            chapter: chapter([Block(id: 0, kind: .paragraph, text: "a")]),
            translations: TranslationMap(),
            configuration: .init(showTranslation: true, fontSize: 22, lineHeight: 1.8, margin: 12))
        XCTAssertTrue(html.contains("--fs:22px"))
        XCTAssertTrue(html.contains("--lh:1.8"))
        XCTAssertTrue(html.contains("--mx:12px"))
    }

    func testFractionalLineHeightAndIntegerFontSizeFormatting() {
        let stylesheet = ReaderHTMLBuilder.stylesheet(.init(fontSize: 19, lineHeight: 1.55, margin: 20))
        XCTAssertTrue(stylesheet.contains("--fs:19px"), "whole numbers must not print as 19.00")
        XCTAssertTrue(stylesheet.contains("--lh:1.55"))
        let rounded = ReaderHTMLBuilder.stylesheet(.init(fontSize: 20, lineHeight: 2, margin: 0))
        XCTAssertTrue(rounded.contains("--lh:2"), "a whole line height must not print as 2.00")
        XCTAssertTrue(rounded.contains("--mx:0px"))
    }

    func testDarkPaletteIsUsed() {
        let stylesheet = ReaderHTMLBuilder.stylesheet(.init())
        XCTAssertTrue(stylesheet.contains("background:#111214"))
        XCTAssertTrue(stylesheet.contains("color:#e9e7e3"))
    }

    func testHeadingAndListStylesExistBecauseBlocksAreDivs() {
        let stylesheet = ReaderHTMLBuilder.stylesheet(.init())
        XCTAssertTrue(stylesheet.contains(".b[data-kind=\"heading\"]"),
                      "headings are divs, so plain h1 rules would never match")
        XCTAssertTrue(stylesheet.contains(".b[data-kind=\"listItem\"]"))
        XCTAssertTrue(stylesheet.contains(".b[data-kind=\"blockquote\"]"))
    }
}

final class BookPathsReaderTests: XCTestCase {
    func testImageReferenceIsRewrittenForThePage() {
        XCTAssertEqual(BookPaths.readerImageSource(for: "images/abc.jpg"), "parsed/images/abc.jpg")
        XCTAssertEqual(BookPaths.readerImageSource(for: "abc.jpg"), "parsed/images/abc.jpg",
                       "a bare file name still resolves under parsed/images")
        XCTAssertEqual(BookPaths.readerImageSource(for: "images/sub/abc.jpg"), "parsed/images/abc.jpg",
                       "only the file name is used, so a reference cannot escape")
        XCTAssertEqual(BookPaths.readerImageSource(for: "images/../../secret.jpg"),
                       "parsed/images/secret.jpg")
    }
}
