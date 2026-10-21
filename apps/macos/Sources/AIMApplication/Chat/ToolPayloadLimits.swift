import Foundation

/// One wire-size contract for admission, persistence and provider adapters.
public enum ToolPayloadLimits {
    public static let argumentsJSONBytes = 2 * 1_024 * 1_024
    public static let resultTextBytes = 128 * 1_024
    public static let resultEnvelopeBytes = 160 * 1_024
    public static let imageBytes = 6_000_000

    public static func validArguments(_ arguments: [String: String]) -> Bool {
        guard arguments.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }),
              let encoded = try? JSONEncoder().encode(arguments) else { return false }
        return encoded.count <= argumentsJSONBytes
    }

    public static func validJSONArguments(_ arguments: [String: ToolJSONValue]) -> Bool {
        guard arguments.allSatisfy({ !$0.key.contains("\0") && valid($0.value, depth: 0) }) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arguments) else { return false }
        return data.count <= argumentsJSONBytes
    }

    private static func valid(_ value: ToolJSONValue, depth: Int) -> Bool {
        guard depth <= 16 else { return false }
        switch value {
        case .string(let text): return !text.contains("\0")
        case .number(let number): return number.isFinite
        case .array(let values): return values.allSatisfy { valid($0, depth: depth + 1) }
        case .object(let values): return values.allSatisfy { !$0.key.contains("\0") && valid($0.value, depth: depth + 1) }
        case .integer, .boolean, .null: return true
        }
    }
}
