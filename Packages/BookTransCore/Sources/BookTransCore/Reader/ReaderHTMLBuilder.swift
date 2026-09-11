import Foundation

/// Builds `reader.html` for one chapter.
///
/// Lives in Core rather than the app because it is pure string assembly with two
/// rules that are easy to get wrong and expensive to debug on a device: a block
/// is only shown translated when *all* of its parts came back, and a run of
/// untranslated blocks is announced once with a marker instead of per block.
public enum ReaderHTMLBuilder {
    public struct Configuration: Sendable, Equatable {
        /// When false the original markup is rendered for every block.
        public var showTranslation: Bool
        public var fontSize: Double
        public var lineHeight: Double
        public var margin: Double

        public init(showTranslation: Bool = true, fontSize: Double = 19,
                    lineHeight: Double = 1.55, margin: Double = 20) {
            self.showTranslation = showTranslation
            self.fontSize = fontSize
            self.lineHeight = lineHeight
            self.margin = margin
        }
    }

    /// Text shown where the reader switches back to the original.
    public static let untranslatedMarker = "далее — оригинал"

    public static func build(
        chapter: Chapter,
        translations: TranslationMap,
        configuration: Configuration
    ) -> String {
        var body = ""
        var insideUntranslatedRun = false

        for block in chapter.blocks {
            let isTranslatable = block.kind.isTranslatable
            let translated = isTranslatable
                ? translations.translatedText(for: block.id)
                : nil
            let showsOriginal = isTranslatable && translated == nil

            if configuration.showTranslation, showsOriginal {
                if !insideUntranslatedRun {
                    insideUntranslatedRun = true
                    body += "<div class=\"untranslated\">\(Block.escape(untranslatedMarker))</div>\n"
                }
            } else {
                insideUntranslatedRun = false
            }

            guard let element = render(
                block: block, translated: configuration.showTranslation ? translated : nil)
            else { continue }
            body += element
            body += "\n"
        }

        return """
        <!DOCTYPE html>
        <html lang="ru">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>\(stylesheet(configuration))</style>
        </head>
        <body>
        <article id="book" data-chapter="\(chapter.index)">
        \(body)</article>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    // MARK: - Blocks

    static func render(block: Block, translated: String?) -> String? {
        switch block.kind {
        case .hr:
            return "<div class=\"b\" id=\"b\(block.id)\" data-kind=\"hr\"><hr></div>"

        case .image:
            // A block whose image could not be resolved renders as nothing.
            guard let reference = block.imageRef, !reference.isEmpty else { return nil }
            let source = escapeAttribute(BookPaths.readerImageSource(for: reference))
            return "<div class=\"b\" id=\"b\(block.id)\" data-kind=\"image\">"
                + "<img src=\"\(source)\" alt=\"\">"
                + "</div>"

        case .table:
            guard let raw = block.rawHTML, !raw.isEmpty else { return nil }
            return "<div class=\"b\" id=\"b\(block.id)\" data-kind=\"table\">\(raw)</div>"

        case .heading, .paragraph, .listItem, .blockquote, .note:
            let content = translated.map { Block.escape($0) } ?? block.html
            guard !content.isEmpty else { return nil }
            return "<div class=\"b\" id=\"b\(block.id)\" data-kind=\"\(block.kind.rawValue)\">\(content)</div>"
        }
    }

    static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Stylesheet

    static func stylesheet(_ configuration: Configuration) -> String {
        """
        :root{--fs:\(format(configuration.fontSize))px;--lh:\(format(configuration.lineHeight));--mx:\(format(configuration.margin))px}
        html,body{background:#111214;color:#e9e7e3;margin:0;padding:0;-webkit-text-size-adjust:100%}
        article{max-width:780px;margin:0 auto;padding:24px var(--mx) 96px;font:var(--fs)/var(--lh) ui-serif,"New York",Georgia,serif}
        .b{margin:0 0 1em}
        .b[data-kind="heading"]{font-family:-apple-system,sans-serif;font-weight:600;font-size:1.25em;line-height:1.25;margin:1.6em 0 .6em}
        .b[data-kind="heading"]:first-child{margin-top:0}
        .b[data-kind="listItem"]{padding-left:1.4em;position:relative}
        .b[data-kind="listItem"]::before{content:"•";position:absolute;left:.4em;color:#8b8f96}
        .b[data-kind="blockquote"]{margin:1em 0;padding-left:14px;border-left:3px solid #3a3d42;color:#c9c6c0}
        .b[data-kind="note"]{margin:1em 0;padding-left:14px;border-left:3px solid #2f3a46;color:#b9c2cc;font-size:.94em}
        .b[data-kind="hr"]{margin:1.8em 0}
        .b[data-kind="hr"] hr{border:0;border-top:1px solid #2a2d31}
        .b[data-kind="image"] img{max-width:100%;height:auto;border-radius:6px;display:block;margin:0 auto}
        .b[data-kind="table"]{overflow-x:auto}
        .b[data-kind="table"] table{border-collapse:collapse;width:100%;font-size:.92em}
        .b[data-kind="table"] td,.b[data-kind="table"] th{border:1px solid #2a2d31;padding:6px 8px;text-align:left}
        .b a{color:#6f9dff}
        .untranslated{border-top:1px dashed #3a3d42;margin:28px 0 16px;padding-top:10px;color:#8b8f96;font-size:.8em;font-family:-apple-system,sans-serif}
        """
    }

    private static func format(_ value: Double) -> String {
        // Whole numbers print without a decimal point so the CSS stays readable.
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Reader bridge

    /// The script injected into every page. Keeping it here means the Swift and
    /// JavaScript halves of the position contract cannot drift.
    public static let script = """
    window.Reader = {
      position() {
        const blocks = document.querySelectorAll('.b');
        if (!blocks.length) { return JSON.stringify({ block: 0, dy: 0, progress: 0 }); }
        const y = window.scrollY || window.pageYOffset || 0;
        let current = blocks[0];
        let dy = 0;
        for (const element of blocks) {
          const top = element.getBoundingClientRect().top + y;
          if (top <= y + 8) { current = element; dy = Math.round(y - top); } else { break; }
        }
        const max = document.documentElement.scrollHeight - window.innerHeight;
        return JSON.stringify({
          block: Number(current.id.slice(1)),
          dy: dy,
          progress: max > 0 ? Math.min(1, Math.max(0, y / max)) : 0
        });
      },
      restore(block, dy) {
        const element = document.getElementById('b' + block);
        if (element) {
          const top = element.getBoundingClientRect().top + (window.scrollY || window.pageYOffset || 0);
          window.scrollTo(0, top + (dy || 0));
          return true;
        }
        return false;
      },
      style(fontSize, lineHeight, margin) {
        const root = document.documentElement.style;
        root.setProperty('--fs', fontSize + 'px');
        root.setProperty('--lh', String(lineHeight));
        root.setProperty('--mx', margin + 'px');
      },
      top() { window.scrollTo(0, 0); }
    };
    """
}
