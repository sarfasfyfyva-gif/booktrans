import Foundation

/// Byte-to-text decoding for imported books.
///
/// The declared encoding is read from the XML prologue, which is ASCII in every
/// single-byte encoding and therefore safe to scan as bytes. Unknown names fall
/// back to UTF-8 and then to windows-1251, the two encodings Russian FB2 files
/// actually use.
public enum EncodingDetect {
    /// Byte-oriented name → Foundation encoding map. `String.Encoding(rawValue:)`
    /// is used instead of `CFStringConvertIANACharSetNameToEncoding`, which is
    /// not available on Linux.
    public static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "utf-16le", "utf16le": return .utf16LittleEndian
        case "utf-16be", "utf16be": return .utf16BigEndian
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "cp819": return .isoLatin1
        case "iso-8859-5", "iso8859-5": return String.Encoding(rawValue: 28595)
        case "windows-1251", "cp1251", "win-1251", "x-cp1251": return String.Encoding(rawValue: 1251)
        case "windows-1252", "cp1252", "win-1252": return String.Encoding(rawValue: 1252)
        case "koi8-r", "koi8r": return String.Encoding(rawValue: 20866)
        case "windows-1250", "cp1250": return String.Encoding(rawValue: 1250)
        default: return nil
        }
    }

    /// Reads `encoding="…"` from the XML declaration in the first 200 bytes.
    public static func declaredEncodingName(in data: Data) -> String? {
        let head = data.prefix(200)
        guard let ascii = String(bytes: head, encoding: .ascii)
            ?? String(bytes: head, encoding: .isoLatin1)
        else { return nil }
        guard let range = ascii.range(of: "encoding", options: .caseInsensitive) else { return nil }
        let tail = ascii[range.upperBound...]
        guard let equals = tail.firstIndex(of: "=") else { return nil }
        let afterEquals = tail[tail.index(after: equals)...]
        guard let quoteIndex = afterEquals.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let quote = afterEquals[quoteIndex]
        let valueStart = afterEquals.index(after: quoteIndex)
        guard let valueEnd = afterEquals[valueStart...].firstIndex(of: quote) else { return nil }
        return String(afterEquals[valueStart..<valueEnd])
    }

    public struct Decoded: Sendable {
        public var text: String
        /// Name as understood by us; `windows-1251 (fallback)` when the declared
        /// encoding failed and the fallback was used.
        public var encodingName: String
    }

    public static func decode(_ data: Data) -> Decoded? {
        // Byte order marks win over the declaration: they are unambiguous.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) {
                return Decoded(text: text, encodingName: "utf-8 (BOM)")
            }
        }
        if data.starts(with: [0xFF, 0xFE]) {
            if let text = String(data: data, encoding: .utf16LittleEndian) {
                return Decoded(text: text, encodingName: "utf-16le (BOM)")
            }
        }
        if data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16BigEndian) {
                return Decoded(text: text, encodingName: "utf-16be (BOM)")
            }
        }

        if let name = declaredEncodingName(in: data) {
            if let decoded = decodeWithName(name, data: data) { return decoded }
            CoreLog.warn("unsupported or mismatched declared encoding '\(name)', falling back")
        }

        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, encodingName: "utf-8")
        }
        if let text = Windows1251.decode(data) {
            return Decoded(text: text, encodingName: "windows-1251 (fallback)")
        }
        return nil
    }

    /// Decodes using the declared name. windows-1251 goes through the local table
    /// rather than `String.Encoding`: Foundation's ICU converter does not carry
    /// that codepage on Linux, so relying on it would silently route every
    /// Russian FB2 file through the fallback path and mis-report the encoding.
    static func decodeWithName(_ name: String, data: Data) -> Decoded? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["windows-1251", "cp1251", "win-1251", "x-cp1251"].contains(lower) {
            return Windows1251.decode(data).map { Decoded(text: $0, encodingName: lower) }
        }
        guard let encoding = encoding(named: lower),
              let text = String(data: data, encoding: encoding)
        else { return nil }
        return Decoded(text: text, encodingName: lower)
    }
}

/// Minimal windows-1251 decoder.
///
/// Foundation's ICU-backed converter is not guaranteed to carry this codepage on
/// every platform we build for, and Russian FB2 libraries are the single most
/// likely input, so the mapping is spelled out.
public enum Windows1251 {
    /// 0x80…0xFF in order; the ASCII range is passed through unchanged.
    static let highTable: [Character] = [
        "\u{0402}", "\u{0403}", "\u{201A}", "\u{0453}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{20AC}", "\u{2030}", "\u{0409}", "\u{2039}", "\u{040A}", "\u{040C}", "\u{040B}", "\u{040F}",
        "\u{0452}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{0098}", "\u{2122}", "\u{0459}", "\u{203A}", "\u{045A}", "\u{045C}", "\u{045B}", "\u{045F}",
        "\u{00A0}", "\u{040E}", "\u{045E}", "\u{0408}", "\u{00A4}", "\u{0490}", "\u{00A6}", "\u{00A7}",
        "\u{0401}", "\u{00A9}", "\u{0404}", "\u{00AB}", "\u{00AC}", "\u{00AD}", "\u{00AE}", "\u{0407}",
        "\u{00B0}", "\u{00B1}", "\u{0406}", "\u{0456}", "\u{0491}", "\u{00B5}", "\u{00B6}", "\u{00B7}",
        "\u{0451}", "\u{2116}", "\u{0454}", "\u{00BB}", "\u{0458}", "\u{0405}", "\u{0455}", "\u{0457}",
        "\u{0410}", "\u{0411}", "\u{0412}", "\u{0413}", "\u{0414}", "\u{0415}", "\u{0416}", "\u{0417}",
        "\u{0418}", "\u{0419}", "\u{041A}", "\u{041B}", "\u{041C}", "\u{041D}", "\u{041E}", "\u{041F}",
        "\u{0420}", "\u{0421}", "\u{0422}", "\u{0423}", "\u{0424}", "\u{0425}", "\u{0426}", "\u{0427}",
        "\u{0428}", "\u{0429}", "\u{042A}", "\u{042B}", "\u{042C}", "\u{042D}", "\u{042E}", "\u{042F}",
        "\u{0430}", "\u{0431}", "\u{0432}", "\u{0433}", "\u{0434}", "\u{0435}", "\u{0436}", "\u{0437}",
        "\u{0438}", "\u{0439}", "\u{043A}", "\u{043B}", "\u{043C}", "\u{043D}", "\u{043E}", "\u{043F}",
        "\u{0440}", "\u{0441}", "\u{0442}", "\u{0443}", "\u{0444}", "\u{0445}", "\u{0446}", "\u{0447}",
        "\u{0448}", "\u{0449}", "\u{044A}", "\u{044B}", "\u{044C}", "\u{044D}", "\u{044E}", "\u{044F}",
    ]

    public static func decode(_ data: Data) -> String? {
        var out = ""
        out.reserveCapacity(data.count)
        for byte in data {
            if byte < 0x80 {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append(highTable[Int(byte) - 0x80])
            }
        }
        return out
    }
}
