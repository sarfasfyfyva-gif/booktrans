import Foundation

/// Compact, order-preserving JSON value used to build the protocol's payload
/// arrays, which are positional and therefore must not be built with
/// dictionaries (key order and `null` holes are semantically meaningful).
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let value): try single.encode(value)
        case .int(let value): try single.encode(value)
        case .string(let value): try single.encode(value)
        case .array(let values): try single.encode(values)
        }
    }

    /// Compact JSON text, with no whitespace at all.
    public var jsonText: String {
        guard let data = try? JSONCoders.makeEncoder().encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    /// Decodes arbitrary JSON into `JSONValue` trees.
    public static func decode(from data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .bool(value); return }
        if let value = try? single.decode(Int.self) { self = .int(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        if let value = try? single.decode([JSONValue].self) { self = .array(value); return }
        self = .null
    }

    // MARK: - Accessors

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Decodes a positional payload that may arrive either as a nested array or as a
/// JSON string containing one; the web protocol uses both shapes.
public enum JSONPayload {
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONValue.decode(from: data)
    }

    public static func parse(_ text: Substring) -> JSONValue? {
        parse(String(text))
    }

    /// Depth-first search for the first string that satisfies `matches`.
    public static func firstString(in value: JSONValue, matching matches: (String) -> Bool) -> String? {
        switch value {
        case .string(let text):
            return matches(text) ? text : nil
        case .array(let values):
            for child in values {
                if let found = firstString(in: child, matching: matches) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// Depth-first search for the first integer that satisfies `matches`.
    public static func firstInt(in value: JSONValue, matching matches: (Int) -> Bool) -> Int? {
        switch value {
        case .int(let number):
            return matches(number) ? number : nil
        case .array(let values):
            for child in values {
                if let found = firstInt(in: child, matching: matches) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}
