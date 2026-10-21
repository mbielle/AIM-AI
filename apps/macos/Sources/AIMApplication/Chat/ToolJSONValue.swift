import Foundation

/// The model/provider boundary preserves JSON types. Existing host executors
/// still receive their historical string representation through one adapter.
public indirect enum ToolJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([ToolJSONValue])
    case object([String: ToolJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let integer = try? value.decode(Int.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([ToolJSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: ToolJSONValue].self) { self = .object(object) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid tool JSON value") }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item):
            guard item.isFinite else { throw EncodingError.invalidValue(item, .init(codingPath: encoder.codingPath, debugDescription: "Non-finite tool number")) }
            try value.encode(item)
        case .boolean(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    public var legacyString: String? {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        case .null: return nil
        }
    }

    public static func decodeObject(_ data: Data) throws -> [String: ToolJSONValue] {
        guard data.count <= ToolPayloadLimits.argumentsJSONBytes, withinDepthLimit(data),
              let object = try? JSONDecoder().decode([String: ToolJSONValue].self, from: data),
              ToolPayloadLimits.validJSONArguments(object) else { throw ModelToolError.invalidProtocol }
        return object
    }

    public static func decodeObject(_ value: Any) throws -> [String: ToolJSONValue] {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { throw ModelToolError.invalidProtocol }
        return try decodeObject(data)
    }

    private static func withinDepthLimit(_ data: Data) -> Bool {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { quoted = false }
            } else if byte == 0x22 { quoted = true }
            else if byte == 0x7B || byte == 0x5B {
                depth += 1
                if depth > 17 { return false } // Root object plus 16 nested values.
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0 && !quoted
    }
}

public enum ToolArgumentKind: String, Codable, Sendable {
    case string, integer, number, boolean, array, object
    case planSteps, questionItems

    public func accepts(_ value: ToolJSONValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.integer, .integer), (.number, .integer), (.number, .number),
             (.boolean, .boolean): true
        case (.array, .array(let values)): values.allSatisfy { if case .string = $0 { true } else { false } }
        case (.object, .object(let values)): values.values.allSatisfy { if case .string = $0 { true } else { false } }
        case (.planSteps, .array(let values)):
            values.allSatisfy { value in
                guard case .object(let fields) = value, Set(fields.keys).isSuperset(of: ["title", "status"]),
                      Set(fields.keys).isSubset(of: ["title", "status", "done_when"]),
                      case .string = fields["title"], case .string(let status) = fields["status"] else { return false }
                if let criterion = fields["done_when"], criterion != .null {
                    guard case .string = criterion else { return false }
                }
                return ["todo", "doing", "done"].contains(status)
            }
        case (.questionItems, .array(let values)):
            values.allSatisfy { value in
                guard case .object(let fields) = value, fields["question"] != nil,
                      Set(fields.keys).isSubset(of: ["question", "options", "multi"]),
                      case .string = fields["question"] else { return false }
                if let options = fields["options"], options != .null,
                   case .array(let items) = options {
                    guard items.allSatisfy({ if case .string = $0 { true } else { false } }) else { return false }
                } else if let options = fields["options"], options != .null { return false }
                if let multi = fields["multi"], multi != .null,
                   case .boolean = multi {} else if let multi = fields["multi"], multi != .null { return false }
                return true
            }
        default: false
        }
    }

    public func parseLegacy(_ value: String) -> ToolJSONValue? {
        if self == .string { return .string(value) }
        guard let decoded = try? JSONDecoder().decode(ToolJSONValue.self, from: Data(value.utf8)),
              accepts(decoded) else { return nil }
        return decoded
    }

    /// OpenAI strict mode requires optional properties to be nullable and all
    /// declared properties to appear in `required`.
    public func schema(optional: Bool = false) -> [String: Any] {
        if self == .planSteps {
            return ["type": optional ? ["array", "null"] : "array", "minItems": 1, "maxItems": 15, "items": [
                "type": "object", "properties": [
                    "title": ["type": "string", "maxLength": 200],
                    "status": ["type": "string", "enum": ["todo", "doing", "done"]],
                    "done_when": ["type": "string", "maxLength": 300]
                ], "required": ["title", "status"], "additionalProperties": false
            ]]
        }
        if self == .questionItems {
            return ["type": optional ? ["array", "null"] : "array", "minItems": 1, "maxItems": 3, "items": [
                "type": "object", "properties": [
                    "question": ["type": "string", "maxLength": 2_000],
                    "options": ["type": ["array", "null"], "items": ["type": "string", "maxLength": 200]],
                    "multi": ["type": ["boolean", "null"]]
                ], "required": ["question", "options", "multi"], "additionalProperties": false
            ]]
        }
        var result: [String: Any] = ["type": optional ? [rawValue, "null"] : rawValue]
        if self == .array { result["items"] = ["type": "string"] }
        if self == .object { result["additionalProperties"] = ["type": "string"] }
        return result
    }
}

/// Shared schema gate for provider decoding and host dispatch. The registry
/// supplies the same key/type declaration to both sides of this boundary.
public enum ToolArgumentValidation {
    public static func normalized(_ arguments: [String: ToolJSONValue], required: Set<String>,
                                  optional: Set<String>, kinds: [String: ToolArgumentKind]) throws -> [String: ToolJSONValue] {
        let keys = Set(arguments.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)),
              ToolPayloadLimits.validJSONArguments(arguments) else { throw ModelToolError.invalidProtocol }
        var result: [String: ToolJSONValue] = [:]
        for (key, value) in arguments {
            if value == .null, optional.contains(key) { continue }
            guard (kinds[key] ?? .string).accepts(value) else { throw ModelToolError.invalidProtocol }
            result[key] = value
        }
        return result
    }
}
