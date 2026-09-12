#!/usr/bin/env python3
"""Build an EPUB from the owner's own PDF copy of a book.

The PDF was produced by calibre, so the text layer is clean but carries no
formatting: every glyph is the same size, and structure has to be recovered from
the words themselves. The table of contents inside the PDF is used as the chapter
list, and each of its titles is located as a standalone line in the body.

Usage:
    python3 tools/pdf2epub.py <input.pdf> <output.epub> "<Title>" "<Author>"

Needs pypdf (the only dependency):
    python3 -m pip install --user pypdf

The chapter list is the book's own printed table of contents, and every title is
required to appear as its own line in the body, in order. That is what makes the
result a real book rather than one long text file: BookTrans batches per chapter
and the reader needs the structure.

To check the result with the app's own importer:

    EPUB_TO_VALIDATE=out.epub swift test \
      --package-path Packages/BookTransCore --filter ValidateGeneratedEPUBTests
"""
import io
import re
import sys
import unicodedata
import zipfile
from collections import Counter
from pathlib import Path

from pypdf import PdfReader

TOC_TITLES = [
    "How I Got Here",
    "The Problem This Book Solves",
    "Leads Alone Aren’t Enough",
    "Engage Your Leads: Offers and Lead Magnets",
    "#1 Warm Outreach",
    "#2 Post Free Content Part I",
    "#2 Post Free Content Part II",
    "Free Goodwill",
    "#3 Cold Outreach",
    "#4 Run Paid Ads Part I: Making An Ad",
    "#4 Run Paid Ads Part II: Money Stuff",
    "Core Four On Steroids: More Better New",
    "#1 Customer Referrals - Word of Mouth",
    "#2 Employees",
    "#3 Agencies",
    "#4 Affiliates and Partners",
    "Advertising in Real Life: Open To Goal",
    "The Roadmap - Putting it All Together",
    "A Decade in a Page",
    "Free Goodies: Calls To Action",
]

TOC_SECTIONS = [
    "Section I: Start Here",
    "Section II: Get Understanding",
    "Section III: Get Leads",
    "Section IV: Get Lead Getters",
    "Section IV Conclusion: Get Lead Getters",
    "Section V: Get Started",
]
# Pages holding the printed table of contents, which the EPUB replaces.
TOC_PAGES = {5, 6}


def normalise(text: str) -> str:
    """Fold quotes, dashes and whitespace so titles compare equal."""
    text = text.replace("\u2019", "'").replace("\u2018", "'")
    text = text.replace("\u201c", '"').replace("\u201d", '"')
    text = text.replace("\u2013", "-").replace("\u2014", "-")
    text = unicodedata.normalize("NFKC", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def page_lines(reader: PdfReader, page_no: int) -> list[str]:
    return (reader.pages[page_no].extract_text() or "").split("\n")


def find_running_heads(reader: PdfReader) -> set[str]:
    """Lines repeated at the top of many pages are headers, not prose."""
    starts = Counter()
    for page_no in range(len(reader.pages)):
        for line in page_lines(reader, page_no):
            stripped = line.strip()
            if stripped:
                starts[normalise(stripped)] = starts[normalise(stripped)] + 1
                break
    # A running head appears on many pages and is short.
    return {text for text, count in starts.items() if count >= 5 and len(text) <= 40}


def scan_book(reader: PdfReader, skip_pages: set[int]) -> list[tuple[str, str, int]]:
    """Flatten the book into ("heading"|"body", text, page) items.

    Headings are recognised per *line*, not per paragraph: in this PDF a heading
    line is followed immediately by prose with no blank line between them, so
    paragraph-level matching would swallow the heading into the first paragraph
    of its own chapter.

    A blank line ends a paragraph; a page boundary does not, because a paragraph
    continuing onto the next page is still one paragraph.

    The printed contents pages are skipped outright: they contain the very titles
    this matcher looks for, in order, so consuming them there would leave nothing
    to match in the body.
    """
    running_heads = find_running_heads(reader)
    section_matcher = Matcher(TOC_SECTIONS)
    chapter_matcher = Matcher(TOC_TITLES)
    items: list[tuple[str, str, int]] = []
    buffer: list[str] = []
    buffer_page = 0

    def flush() -> None:
        nonlocal buffer
        if buffer:
            text = join_lines(buffer)
            if text:
                items.append(("body", text, buffer_page))
        buffer = []

    for page_no in range(len(reader.pages)):
        if page_no in skip_pages:
            continue
        lines = [line.strip() for line in page_lines(reader, page_no)]
        index = 0
        while index < len(lines):
            line = lines[index]
            if not line or normalise(line) in running_heads:
                if not line:
                    flush()
                index += 1
                continue

            # Single-line exact matches first: a heading is far more likely to be
            # one line than two, and trying two first would eat the first line of
            # the chapter's own text.
            heading: tuple[str, str, int] | None = None
            for take in (1, 2):
                candidate = " ".join(lines[index:index + take]).strip()
                if not candidate or len(candidate) > 90:
                    continue
                section = section_matcher.match(candidate)
                if section:
                    heading = ("section", section, take)
                    break
                chapter = chapter_matcher.match(candidate)
                if chapter:
                    heading = ("heading", chapter, take)
                    break
            if heading:
                flush()
                kind, title, take = heading
                items.append((kind if kind == "section" else "heading", title, page_no))
                index += take
                continue

            if not buffer:
                buffer_page = page_no
            buffer.append(line)
            index += 1
        # A page break is not a paragraph break: keep accumulating.
    flush()
    return items


def join_lines(lines: list[str]) -> str:
    """Join wrapped lines, undoing end-of-line hyphenation."""
    out = ""
    for line in lines:
        if not out:
            out = line
            continue
        if out.endswith("-") and len(out) > 1 and line[:1].islower():
            # "prod-" + "ucts" is one word; a real hyphen is followed by a
            # capital or the hyphen is part of a compound like "well-known".
            out = out[:-1] + line
        else:
            out = out + " " + line
    return re.sub(r"\s+", " ", out).strip()


class Matcher:
    """Recognises headings, in the order the printed contents lists them.

    Two rules make this reliable where pattern matching is not:

    A chapter heading must match the *next* title from the contents exactly. The
    order requirement rejects the book's own cross-references — "#3 Agencies"
    inside a list of the four lead getters is not a chapter — and requiring an
    exact match rejects list items such as "#2 Employees- people in your business
    that get you leads.", which a prefix rule would accept. Every one of the 26
    headings was confirmed to appear as its own line, so nothing is lost by it.
    """

    def __init__(self, titles: list[str]) -> None:
        self.titles = titles
        self.next = 0

    def _exact(self, folded: str) -> int | None:
        for offset in range(self.next, len(self.titles)):
            if folded == normalise(self.titles[offset]):
                return offset
        return None

    def match(self, raw: str) -> str | None:
        offset = self._exact(normalise(raw))
        if offset is None:
            return None
        self.next = offset + 1
        return self.titles[offset]


def esc(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def build_chapters(items, toc_pages):
    """Split the scanned items into front matter and chapters."""
    chapters: list[dict] = []
    current = {"title": "Front Matter", "section": None, "body": []}

    def close() -> None:
        nonlocal current
        if current["body"]:
            chapters.append(current)

    for kind, text, page in items:
        if page in toc_pages:
            continue
        if kind == "section":
            close()
            current = {"title": text, "section": text, "body": []}
        elif kind == "heading":
            section = current.get("section")
            close()
            current = {"title": text, "section": section, "body": []}
        else:
            current["body"].append(text)
    close()
    return [c for c in chapters if c["body"]]


def xhtml(title: str, paragraphs: list[str], heading_level: str = "1") -> str:
    body = "\n".join(f"<p>{esc(p)}</p>" for p in paragraphs)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="utf-8"/><title>{esc(title)}</title>
<link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>
<section epub:type="chapter">
<h{heading_level}>{esc(title)}</h{heading_level}>
{body}
</section>
</body>
</html>
"""


STYLE = """body{font-family:serif;line-height:1.5;margin:1em}
h1{font-size:1.5em;margin:1.2em 0 .6em}
h2{font-size:1.2em;margin:1.2em 0 .5em}
p{margin:0 0 .8em;text-align:justify}
"""


def extract_cover(reader: PdfReader) -> tuple[str, bytes] | None:
    """Largest image on the first pages is the cover."""
    best = None
    for page_no in range(min(3, len(reader.pages))):
        try:
            for image in reader.pages[page_no].images:
                data = image.data
                if best is None or len(data) > len(best[1]):
                    name = image.name or "cover.png"
                    best = (name, data)
        except Exception:
            continue
    return best


def write_epub(path: Path, title: str, author: str, chapters: list[dict]) -> None:
    files: dict[str, bytes] = {}
    files["mimetype"] = b"application/epub+zip"
    files["META-INF/container.xml"] = b"""<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""
    files["OEBPS/style.css"] = STYLE.encode()

    manifest, spine, nav_items, ncx_points = [], [], [], []
    for index, chapter in enumerate(chapters):
        name = f"ch{index + 1:03d}.xhtml"
        files[f"OEBPS/{name}"] = xhtml(chapter["title"], chapter["body"]).encode()
        manifest.append(f'<item id="c{index}" href="{name}" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="c{index}"/>')
        nav_items.append(f'<li><a href="{name}">{esc(chapter["title"])}</a></li>')
        ncx_points.append(
            f'<navPoint id="n{index}" playOrder="{index + 1}">'
            f'<navLabel><text>{esc(chapter["title"])}</text></navLabel>'
            f'<content src="{name}"/></navPoint>')

    files["OEBPS/nav.xhtml"] = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><meta charset="utf-8"/><title>Contents</title></head>
<body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
{chr(10).join(nav_items)}
</ol></nav></body>
</html>
""".encode()
    manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')

    files["OEBPS/toc.ncx"] = f"""<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="booktrans-generated"/></head>
<docTitle><text>{esc(title)}</text></docTitle>
<navMap>
{chr(10).join(ncx_points)}
</navMap></ncx>
""".encode()
    manifest.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')

    files["OEBPS/content.opf"] = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">booktrans-{abs(hash(title)) & 0xffffffff:x}</dc:identifier>
    <dc:title>{esc(title)}</dc:title>
    <dc:creator>{esc(author)}</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    {chr(10).join(manifest)}
  </manifest>
  <spine toc="ncx">
    {chr(10).join(spine)}
  </spine>
</package>
""".encode()

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        # The mimetype entry must be first and stored uncompressed.
        zf.writestr(zipfile.ZipInfo("mimetype"), files["mimetype"], zipfile.ZIP_STORED)
        for name, data in files.items():
            if name == "mimetype":
                continue
            zf.writestr(name, data)


def main() -> int:
    pdf_path, epub_path, title, author = sys.argv[1:5]
    reader = PdfReader(pdf_path)
    items = scan_book(reader, TOC_PAGES)
    chapters = build_chapters(items, TOC_PAGES)
    paragraphs = items
    write_epub(Path(epub_path), title, author, chapters)

    print(f"pages:      {len(reader.pages)}")
    print(f"items:      {len(paragraphs)} "
          f"(headings: {sum(1 for i in paragraphs if i[0] != 'body')})")
    print(f"chapters:   {len(chapters)}")
    for chapter in chapters:
        print(f"   {chapter['title'][:60]:62} {len(chapter['body']):5} paragraphs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
