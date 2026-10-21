import Foundation

public enum RemoteJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RemoteJSONValue])
    case array([RemoteJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RemoteJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RemoteJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var objectValue: [String: RemoteJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [RemoteJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var displayText: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return value.formatted()
        case let .bool(value): return value ? "true" : "false"
        case .null: return nil
        case .object, .array:
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
