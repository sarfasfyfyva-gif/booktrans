import XCTest
@testable import BookTransCore

final class MarkupTokenizerTests: XCTestCase {
    private func tokens(_ text: String) -> [MarkupToken] {
        var tokenizer = MarkupTokenizer(text)
        var out: [MarkupToken] = []
        while let token = tokenizer.next() { out.append(token) }
        return out
    }

    private func kinds(_ text: String) -> [String] {
        tokens(text).map { token in
            switch token.kind {
            case .start(let tag):
                return "start:\(tag.name)" + (tag.selfClosing ? "/" : "")
            case .end(let name): return "end:\(name)"
            case .text(let value): return "text:\(value)"
            case .cdata(let value): return "cdata:\(value)"
            case .comment: return "comment"
            case .processingInstruction: return "pi"
            case .doctype: return "doctype"
            }
        }
    }

    func testSimpleDocument() {
        XCTAssertEqual(kinds("<p>Hello</p>"), ["start:p", "text:Hello", "end:p"])
    }

    func testTagAndAttributeNamesAreLowercasedAndPrefixStripped() {
        let tokens = tokens("<FictionBook xmlns:l=\"x\"><image L:HREF=\"#a.jpg\"/></FictionBook>")
        guard case .start(let first) = tokens[0].kind,
              case .start(let image) = tokens[1].kind
        else { return XCTFail("unexpected tokens") }
        XCTAssertEqual(first.name, "fictionbook")
        XCTAssertEqual(image.name, "image")
        XCTAssertEqual(image.attributes["href"], "#a.jpg")
        XCTAssertTrue(image.selfClosing)
    }

    func testAttributeValuesAreEntityDecoded() {
        let tokens = tokens("<a href=\"a&amp;b\">x</a>")
        guard case .start(let tag) = tokens[0].kind else { return XCTFail("no start tag") }
        XCTAssertEqual(tag.attributes["href"], "a&b")
    }

    func testUnquotedAttributeAndDuplicateKeepsFirst() {
        let tokens = tokens("<img src=a.png src=b.png>")
        guard case .start(let tag) = tokens[0].kind else { return XCTFail("no start tag") }
        XCTAssertEqual(tag.attributes["src"], "a.png")
    }

    func testVoidElementIsNotSelfClosingButHasNoEndTag() {
        let tokens = tokens("<p>a<br>b</p>")
        guard case .start(let br) = tokens[2].kind else { return XCTFail("no br") }
        XCTAssertFalse(br.selfClosing, "HTML void elements are written without a slash")
    }

    func testCommentDoctypeAndProcessingInstruction() {
        XCTAssertEqual(kinds("<?xml version=\"1.0\"?><!DOCTYPE html><!-- x --><p>y</p>"),
                       ["pi", "doctype", "comment", "start:p", "text:y", "end:p"])
    }

    func testCDATAContentIsKeptVerbatim() {
        XCTAssertEqual(kinds("<p><![CDATA[a < b & c]]></p>"),
                       ["start:p", "cdata:a < b & c", "end:p"])
    }

    func testStrayLessThanBecomesText() {
        XCTAssertEqual(kinds("a < b"), ["text:a ", "text:<", "text: b"])
    }

    func testUnclosedTagAtEndOfInputDoesNotHang() {
        XCTAssertEqual(kinds("<p>unfinished"), ["start:p", "text:unfinished"])
    }

    func testMalformedTagWithoutNameIsTreatedAsText() {
        XCTAssertEqual(kinds("x </> y"), ["text:x ", "text:<", "text:/> y"])
    }

    func testRawSliceReproducesTheSource() {
        let tokens = tokens("<p class=\"x\">a &amp; b</p>")
        XCTAssertEqual(tokens.map(\.raw).joined(), "<p class=\"x\">a &amp; b</p>")
    }

    func testNestedRawSlicesReproduceATable() {
        let source = "<table><tr><td>a</td></tr></table>"
        XCTAssertEqual(tokens(source).map(\.raw).joined(), source)
    }
}

final class HTMLEntitiesTests: XCTestCase {
    func testNamedReferences() {
        XCTAssertEqual(HTMLEntities.decode("a&amp;b &lt;x&gt; &quot;q&quot; &apos;s&apos;"),
                       "a&b <x> \"q\" 's'")
    }

    func testNbspAndTypography() {
        XCTAssertEqual(HTMLEntities.decode("a&nbsp;b&mdash;c"), "a\u{00A0}b\u{2014}c")
    }

    func testNumericReferences() {
        XCTAssertEqual(HTMLEntities.decode("&#1055;&#x440;"), "Пр")
    }

    func testSurrogatePairReference() {
        XCTAssertEqual(HTMLEntities.decode("&#x1F600;"), "\u{1F600}")
    }

    func testUnknownAndMalformedReferencesArePreserved() {
        XCTAssertEqual(HTMLEntities.decode("&notanentity; &amp &; &#;"), "&notanentity; &amp &; &#;")
    }

    func testDecodingIsNotAppliedTwice() {
        XCTAssertEqual(HTMLEntities.decode("&amp;lt;"), "&lt;")
    }

    func testOutOfRangeNumericReferenceBecomesReplacementCharacter() {
        XCTAssertEqual(HTMLEntities.decode("&#x110000;"), "\u{FFFD}")
    }
}

final class EncodingDetectTests: XCTestCase {
    func testDeclaredUTF8() {
        let data = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><a/>".utf8)
        XCTAssertEqual(EncodingDetect.declaredEncodingName(in: data), "utf-8")
        XCTAssertEqual(EncodingDetect.decode(data)?.encodingName, "utf-8")
    }

    func testDeclaredWindows1251Bytes() {
        // "Привет" in windows-1251.
        let bytes: [UInt8] = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]
        let prefix = Array("<?xml version=\"1.0\" encoding=\"windows-1251\"?><t>".utf8)
        var data = Data(prefix + bytes)
        data.append(contentsOf: Array("</t>".utf8))

        let decoded = EncodingDetect.decode(data)
        XCTAssertEqual(decoded?.encodingName, "windows-1251")
        XCTAssertEqual(decoded?.text, "<?xml version=\"1.0\" encoding=\"windows-1251\"?><t>Привет</t>")
    }

    func testWindows1251FallbackWhenNothingIsDeclared() {
        // Invalid UTF-8 and no declaration: the Russian fallback must kick in.
        let data = Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])
        let decoded = EncodingDetect.decode(data)
        XCTAssertEqual(decoded?.text, "Привет")
        XCTAssertEqual(decoded?.encodingName, "windows-1251 (fallback)")
    }

    func testUTF8BOMWins() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Array("<p>Привет</p>".utf8))
        let decoded = EncodingDetect.decode(data)
        XCTAssertEqual(decoded?.encodingName, "utf-8 (BOM)")
        XCTAssertEqual(decoded?.text, "<p>Привет</p>")
    }

    func testUnknownDeclaredNameFallsBackToUTF8() {
        let data = Data("<?xml version=\"1.0\" encoding=\"klingon\"?><t>ok</t>".utf8)
        let decoded = EncodingDetect.decode(data)
        XCTAssertEqual(decoded?.encodingName, "utf-8")
        XCTAssertEqual(decoded?.text, "<?xml version=\"1.0\" encoding=\"klingon\"?><t>ok</t>")
    }

    func testSingleQuoteDeclaration() {
        let data = Data("<?xml version='1.0' encoding='koi8-r'?><t/>".utf8)
        XCTAssertEqual(EncodingDetect.declaredEncodingName(in: data), "koi8-r")
    }

    func testWindows1251TableCoversCyrillic() {
        // Uppercase А..Я is 0xC0..0xDF in order.
        let data = Data(Array(0xC0...0xDF))
        XCTAssertEqual(Windows1251.decode(data), "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
    }
}

final class SHA1Tests: XCTestCase {
    func testKnownDigests() {
        XCTAssertEqual(SHA1.hexDigest(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hexDigest("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    func testMultiBlockMessagePadLength() {
        // Exercises the multi-chunk path and the 64-bit length field.
        XCTAssertEqual(SHA1.hexDigest(String(repeating: "a", count: 1_000_000)),
                       "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    func testMultibyteInputIsHashedAsUTF8() {
        // "П" is D0 9F in UTF-8; the digest must follow the bytes, not the
        // Unicode scalars, so it must match the two-byte input exactly.
        XCTAssertEqual(SHA1.hexDigest("П"), SHA1.hexDigest([0xD0, 0x9F]))
        XCTAssertEqual(SHA1.hexDigest("The quick brown fox jumps over the lazy dog"),
                       "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
    }
}
