// JSON that round-trips the way the Node harness writes it.
//
// Two properties matter more than speed here, and Foundation gives neither:
//
// - **Unknown fields survive.** `bots.json` is shared with the Node engine
//   and with builds newer than this one. A record decoded into a struct and
//   encoded back loses every field the struct does not name; an object kept
//   as JSON loses nothing. Records in this harness are views over `JSON`.
// - **Key order survives.** `JSON.stringify` keeps insertion order, so the
//   files people diff and paste into bug reports read the same whichever
//   engine wrote them.
//
// Numbers are `Double`, exactly like JavaScript; integers up to 2^53 (epoch
// milliseconds included) print without a fraction, as `JSON.stringify` does.
import Foundation

public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An object that remembers insertion order.
public struct JSONObject: Equatable, Sendable, Sequence {
    public private(set) var keys: [String] = []
    private var values: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, values[key]!)
        }
    }

    /// Copy without the given keys — the wire shapes strip bookkeeping.
    public func removing(_ names: String...) -> JSONObject {
        var copy = self
        for name in names { copy[name] = nil }
        return copy
    }

    /// Shallow merge, `JSON`'s `{...a, ...b}`: later keys win, new keys append.
    public func merging(_ other: JSONObject) -> JSONObject {
        var copy = self
        for (key, value) in other { copy[key] = value }
        return copy
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.values == rhs.values
    }
}

// MARK: - Literals

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Reading

extension JSON {
    public subscript(key: String) -> JSON? {
        get { if case let .object(object) = self { return object[key] } else { return nil } }
        set {
            guard case var .object(object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public var string: String? { if case let .string(value) = self { return value } else { return nil } }
    public var double: Double? { if case let .number(value) = self { return value } else { return nil } }
    public var int: Int? { double.flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil } }
    public var bool: Bool? { if case let .bool(value) = self { return value } else { return nil } }
    public var array: [JSON]? { if case let .array(value) = self { return value } else { return nil } }
    public var object: JSONObject? { if case let .object(value) = self { return value } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// JavaScript truthiness, for ports of `if (x.flag)`.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case let .bool(value): return value
        case let .number(value): return value != 0 && !value.isNaN
        case let .string(value): return !value.isEmpty
        case .array, .object: return true
        }
    }

    public static func from(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
    public static func from(_ value: Double?) -> JSON { value.map(JSON.number) ?? .null }
    public static func from(_ value: Bool?) -> JSON { value.map(JSON.bool) ?? .null }
    public static func strings(_ values: [String]) -> JSON { .array(values.map(JSON.string)) }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON: \(reason) at byte \(offset)" }
}

extension JSON {
    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512 else { throw error("nesting too deep") }
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try objectValue(depth: depth)
            case UInt8(ascii: "["): return try arrayValue(depth: depth)
            case UInt8(ascii: "\""): return .string(try stringValue())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try numberValue())
            }
        }

        mutating func literal(_ word: String) throws {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
                throw error("invalid literal")
            }
            index += utf8.count
        }

        mutating func objectValue(depth: Int) throws -> JSON {
            index += 1
            var object = JSONObject()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
                let key = try stringValue()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                object[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func arrayValue(depth: Int) throws -> JSON {
            index += 1
            var items: [JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func stringValue() throws -> String {
            index += 1
            var out = [UInt8]()
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { break }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        // a surrogate pair is two \u escapes making one scalar
                        if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            }
                        }
                        let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(character).utf8))
                    default:
                        throw error("invalid escape")
                    }
                    continue
                }
                out.append(byte)
                index += 1
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw error("invalid \\u escape") }
            index += 4
            return value
        }

        mutating func numberValue() throws -> Double {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw error("invalid number")
            }
            return value
        }
    }
}

// MARK: - Writing

extension JSON {
    /// `JSON.stringify(value)`.
    public func serialized() -> String {
        var out = ""
        write(into: &out, indent: nil, level: 0)
        return out
    }

    /// `JSON.stringify(value, null, 2)` — the shape of every file on disk.
    public func pretty() -> String {
        var out = ""
        write(into: &out, indent: "  ", level: 0)
        return out
    }

    public var data: Data { Data(serialized().utf8) }

    private func write(into out: inout String, indent: String?, level: Int) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .number(value): out += Self.format(value)
        case let .string(value): Self.quote(value, into: &out)
        case let .array(items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                newline(&out, indent, level + 1)
                item.write(into: &out, indent: indent, level: level + 1)
            }
            newline(&out, indent, level)
            out += "]"
        case let .object(object):
            guard !object.isEmpty else { out += "{}"; return }
            out += "{"
            var first = true
            for (key, value) in object {
                if !first { out += "," }
                first = false
                newline(&out, indent, level + 1)
                Self.quote(key, into: &out)
                out += indent == nil ? ":" : ": "
                value.write(into: &out, indent: indent, level: level + 1)
            }
            newline(&out, indent, level)
            out += "}"
        }
    }

    private func newline(_ out: inout String, _ indent: String?, _ level: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: indent, count: level)
    }

    /// JavaScript's number printing for the values that occur in practice:
    /// integers without a fraction, non-finite as null.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    public static func quote(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Bridging

extension JSON {
    /// From Foundation objects (`JSONSerialization` output, `[String: Any]`).
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let json as JSON: self = json
        case let string as String: self = .string(string)
        case let number as NSNumber:
            #if canImport(Darwin)
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            #else
            // swift-corelibs JSONSerialization boxes booleans as char-typed NSNumbers
            let isBool = String(cString: number.objCType) == "c"
            #endif
            if isBool { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let array as [Any]: self = .array(array.map { JSON(any: $0) })
        case let dictionary as [String: Any]:
            var object = JSONObject()
            for key in dictionary.keys.sorted() { object[key] = JSON(any: dictionary[key]) }
            self = .object(object)
        default: self = .string(String(describing: value!))
        }
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) { self.init(elements) }
}
