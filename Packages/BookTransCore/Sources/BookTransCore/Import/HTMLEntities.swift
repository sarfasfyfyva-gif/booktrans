import Foundation

/// Named and numeric character references.
///
/// Unknown names are left verbatim rather than dropped: real FB2 and EPUB files
/// contain typos and references from XML subsets we do not model, and silently
/// deleting them would corrupt the text that gets translated.
public enum HTMLEntities {
    public static let named: [String: String] = [
        // XML predefined
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        // Spaces and dashes
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "shy": "\u{00AD}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "minus": "\u{2212}",
        "horbar": "\u{2015}", "bdquo": "\u{201E}",
        // Quotes
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "prime": "\u{2032}", "Prime": "\u{2033}",
        // Punctuation
        "hellip": "\u{2026}", "middot": "\u{00B7}", "bull": "\u{2022}", "bull;": "\u{2022}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "sect": "\u{00A7}", "para": "\u{00B6}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}",
        "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "frasl": "\u{2044}", "permil": "\u{2030}",
        // Fractions
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "frac13": "\u{2153}", "frac23": "\u{2154}",
        // Currency
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        "curren": "\u{00A4}", "rub": "\u{20BD}",
        // Arrows and marks
        "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}",
        "harr": "\u{2194}", "crarr": "\u{21B5}",
        "infin": "\u{221E}", "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}",
        "asymp": "\u{2248}", "equiv": "\u{2261}", "sum": "\u{2211}", "prod": "\u{220F}",
        "radic": "\u{221A}", "part": "\u{2202}", "int": "\u{222B}", "Delta": "\u{0394}",
        "lceil": "\u{2308}", "rceil": "\u{2309}", "lfloor": "\u{230A}", "rfloor": "\u{230B}",
        "lowast": "\u{2217}", "oline": "\u{203E}", "ang": "\u{2220}",
        // Greek (lowercase), often needed in business prose
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}",
        "epsilon": "\u{03B5}", "zeta": "\u{03B6}", "eta": "\u{03B7}", "theta": "\u{03B8}",
        "iota": "\u{03B9}", "kappa": "\u{03BA}", "lambda": "\u{03BB}", "mu": "\u{03BC}",
        "nu": "\u{03BD}", "xi": "\u{03BE}", "omicron": "\u{03BF}", "pi": "\u{03C0}",
        "rho": "\u{03C1}", "sigma": "\u{03C3}", "tau": "\u{03C4}", "upsilon": "\u{03C5}",
        "phi": "\u{03C6}", "chi": "\u{03C7}", "psi": "\u{03C8}", "omega": "\u{03C9}",
        "Alpha": "\u{0391}", "Beta": "\u{0392}", "Gamma": "\u{0393}", "Sigma": "\u{03A3}",
        "Omega": "\u{03A9}",
        // Latin-1 accented letters seen in names
        "aacute": "\u{00E1}", "agrave": "\u{00E0}", "acirc": "\u{00E2}", "auml": "\u{00E4}",
        "aring": "\u{00E5}", "atilde": "\u{00E3}", "aelig": "\u{00E6}",
        "ccedil": "\u{00E7}", "eacute": "\u{00E9}", "egrave": "\u{00E8}", "ecirc": "\u{00EA}",
        "euml": "\u{00EB}", "iacute": "\u{00ED}", "igrave": "\u{00EC}", "iuml": "\u{00EF}",
        "ntilde": "\u{00F1}", "oacute": "\u{00F3}", "ograve": "\u{00F2}", "ocirc": "\u{00F4}",
        "ouml": "\u{00F6}", "otilde": "\u{00F5}", "oslash": "\u{00F8}",
        "uacute": "\u{00FA}", "ugrave": "\u{00F9}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}",
        "yacute": "\u{00FD}", "szlig": "\u{00DF}",
        "Aacute": "\u{00C1}", "Agrave": "\u{00C0}", "Auml": "\u{00C4}", "Ccedil": "\u{00C7}",
        "Eacute": "\u{00C9}", "Iacute": "\u{00CD}", "Ntilde": "\u{00D1}", "Oacute": "\u{00D3}",
        "Ouml": "\u{00D6}", "Oslash": "\u{00D8}", "Uacute": "\u{00DA}", "Uuml": "\u{00DC}",
    ]

    /// Decodes one reference body (the text between `&` and `;`), or returns nil
    /// when it is not a reference we understand.
    public static func decodeReference(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let scalarValue = value, let scalar = Unicode.Scalar(scalarValue) else {
                // Out of range or malformed: fall back to the replacement
                // character rather than dropping the reference silently.
                return "\u{FFFD}"
            }
            return String(Character(scalar))
        }
        return named[body]
    }

    /// Replaces every reference it understands, leaving unknown ones untouched.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            // A reference is at most ~32 characters; anything longer is treated
            // as a literal ampersand.
            var cursor = text.index(after: index)
            var body = ""
            var found = false
            var scanned = 0
            while cursor < text.endIndex, scanned < 32 {
                let next = text[cursor]
                if next == ";" {
                    found = true
                    break
                }
                if next == "&" || next == "<" || next == ">" || next.isWhitespace { break }
                body.append(next)
                cursor = text.index(after: cursor)
                scanned += 1
            }
            if found, let decoded = decodeReference(body) {
                out.append(decoded)
                index = text.index(after: cursor)
            } else {
                out.append(character)
                index = text.index(after: index)
            }
        }
        return out
    }
}
