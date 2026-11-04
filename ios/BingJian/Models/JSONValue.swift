import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var double: Double? { if case .number(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var object: JSONObject? { if case .object(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
}

typealias JSONObject = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    func text(_ key: String, fallback: String = "") -> String { self[key]?.string ?? fallback }
    func number(_ key: String) -> Double? { self[key]?.double }
    func flag(_ key: String) -> Bool { self[key]?.bool ?? false }
    func objects(_ key: String) -> [JSONObject] { self[key]?.array?.compactMap(\.object) ?? [] }
    func strings(_ key: String) -> [String] { self[key]?.array?.compactMap(\.string) ?? [] }
}

enum Codec {
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        value.outputFormatting = [.sortedKeys]
        return value
    }

    static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }

    static func object<T: Encodable>(_ value: T) throws -> JSONObject {
        try JSONDecoder().decode(JSONObject.self, from: encoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: JSONObject) throws -> T {
        try decoder().decode(type, from: JSONEncoder().encode(object))
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }
}

enum TimeFormat {
    static func iso(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func day(_ date: Date = Date(), timezone: String = TimeZone.current.identifier, startMinutes: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let isPrevious = (components.hour ?? 0) * 60 + (components.minute ?? 0) < startMinutes
        let target = isPrevious ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: target)
    }

    static func window(_ day: String, timezone: String, startMinutes: Int = 0) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let base = formatter.date(from: day),
              let start = calendar.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: base),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }
}

extension Double {
    var concise: String { formatted(.number.precision(.fractionLength(0...2))) }
}
