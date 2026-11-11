import Foundation

/// A JSON value, as MCP's messages carry them: plain data that can go between the network's queue and the main
/// actor, compared in tests, and written back out exactly.
nonisolated enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    /// Parses one JSON text. Nil when it isn't one.
    static func parse(_ data: Data) -> JSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(foundation: any)
    }

    init?(foundation any: Any) {
        switch any {
        case is NSNull: self = .null
        case let string as String: self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue); return }
            // Whole numbers stay whole (a request's id 7 comes back as 7, never 7.0).
            let type = String(cString: number.objCType)
            if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) { self = .int(number.intValue); return }
            let double = number.doubleValue
            if double.isFinite, double == double.rounded(), abs(double) < 9e15 { self = .int(Int(double)) } else { self = .double(double) }
        case let array as [Any]:
            var items: [JSON] = []
            for item in array {
                guard let value = JSON(foundation: item) else { return nil }
                items.append(value)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            var object: [String: JSON] = [:]
            for (key, item) in dictionary {
                guard let value = JSON(foundation: item) else { return nil }
                object[key] = value
            }
            self = .object(object)
        default: return nil
        }
    }

    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value.isFinite ? value : 0
        case .string(let value): value
        case .array(let items): items.map(\.foundation)
        case .object(let object): object.mapValues(\.foundation)
        }
    }

    /// Compact JSON text, keys sorted so the same value always reads the same.
    var data: Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var object: [String: JSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSON]? { if case .array(let value) = self { value } else { nil } }

    /// A whole number, also when it came as 3.0.
    var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.isFinite && value == value.rounded() && abs(value) < 9e15: Int(value)
        default: nil
        }
    }

    /// Any number.
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}

extension JSON: ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(stringInterpolation: DefaultStringInterpolation) { self = .string(String(stringInterpolation: stringInterpolation)) }
    nonisolated init(integerLiteral value: Int) { self = .int(value) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(floatLiteral value: Double) { self = .double(value) }
    nonisolated init(arrayLiteral elements: JSON...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    nonisolated init(nilLiteral: ()) { self = .null }
}
