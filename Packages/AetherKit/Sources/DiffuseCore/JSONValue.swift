import Foundation

/// A field's value as a flow holds it: any JSON, with whole numbers kept
/// apart from fractional ones, because the core refuses `6.0` for a field
/// that takes a whole number.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var doubleValue: Double? {
        switch self {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let v): v
        case .double(let v) where v.rounded() == v: Int64(v)
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// How the value reads in a node's summary row.
    public var display: String {
        switch self {
        case .null: "—"
        case .bool(let b): b ? "on" : "off"
        case .int(let v): String(v)
        case .double(let v): v.formatted(.number.precision(.fractionLength(0...3)))
        case .string(let s): s
        case .array(let a): "\(a.count) items"
        case .object: "{…}"
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
