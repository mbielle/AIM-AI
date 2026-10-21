import Foundation
import Metal

/// What a local model needs in memory (weights + the KV cache of its context) against what this
/// Mac can give the GPU, so AIM proposes a context that fits and warns before one that does not.
public enum LocalModelMemory {
    /// The shape that sizes the KV cache, read from the model on disk.
    public struct Architecture: Equatable, Sendable {
        public var layers: Int
        public var kvHeads: Int
        public var headDimension: Int
        /// The longest context the model was trained for.
        public var maxContext: Int?

        public init(layers: Int, kvHeads: Int, headDimension: Int, maxContext: Int?) {
            self.layers = layers; self.kvHeads = kvHeads; self.headDimension = headDimension; self.maxContext = maxContext
        }

        /// Keys and values for one token, every layer.
        public func kvBytesPerToken(quantized: Bool) -> Int64 {
            Int64(layers) * Int64(kvHeads) * Int64(headDimension) * 2 * (quantized ? 1 : 2)
        }
    }

    public enum Verdict: Equatable, Sendable { case fits, tight, tooLarge }

    public struct Estimate: Equatable, Sendable {
        public let weightsBytes: Int64
        public let contextBytes: Int64
        public let overheadBytes: Int64
        public let budgetBytes: Int64
        public var totalBytes: Int64 { weightsBytes + contextBytes + overheadBytes }
        public var verdict: Verdict {
            let share = Double(totalBytes) / Double(max(budgetBytes, 1))
            return share <= 0.85 ? .fits : share <= 1 ? .tight : .tooLarge
        }
    }

    /// Working memory for activations and buffers beside weights and cache.
    static let overhead: Int64 = 512 * 1_024 * 1_024

    /// The memory macOS lets the GPU use (unified memory), else 70 % of the RAM.
    public static func budget() -> Int64 {
        if let device = MTLCreateSystemDefaultDevice(), device.recommendedMaxWorkingSetSize > 0 {
            return Int64(device.recommendedMaxWorkingSetSize)
        }
        return Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.7)
    }

    public static func estimate(weightsBytes: Int64, architecture: Architecture?, context: Int, quantizedCache: Bool,
                                budget: Int64 = LocalModelMemory.budget()) -> Estimate {
        // Without the shape, assume a typical 8B model's cache per token (144 KB in f16).
        let perToken = architecture?.kvBytesPerToken(quantized: quantizedCache) ?? (quantizedCache ? 73_728 : 147_456)
        return Estimate(weightsBytes: weightsBytes, contextBytes: perToken * Int64(context), overheadBytes: overhead, budgetBytes: budget)
    }

    public static let contextSteps = [2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144]

    /// The largest step that stays under 80 % of the budget (and within the model's limit).
    public static func recommendedContext(weightsBytes: Int64, architecture: Architecture?, quantizedCache: Bool = false,
                                          budget: Int64 = LocalModelMemory.budget()) -> Int {
        let limit = architecture?.maxContext ?? 32_768
        var best = 2_048
        for step in contextSteps where step <= max(limit, 2_048) {
            let estimate = estimate(weightsBytes: weightsBytes, architecture: architecture, context: step,
                                    quantizedCache: quantizedCache, budget: budget)
            if Double(estimate.totalBytes) <= Double(budget) * 0.8 { best = step }
        }
        return min(best, 32_768)
    }

    /// The largest context the memory allows at all (for "Use the largest that fits").
    public static func largestFittingContext(weightsBytes: Int64, architecture: Architecture?, quantizedCache: Bool,
                                             budget: Int64 = LocalModelMemory.budget()) -> Int {
        let perToken = architecture?.kvBytesPerToken(quantized: quantizedCache) ?? 147_456
        let spare = budget - weightsBytes - overhead
        guard spare > 0 else { return 0 }
        let tokens = Int(spare / max(perToken, 1))
        let capped = min(tokens, architecture?.maxContext ?? tokens)
        return max(0, capped / 1_024 * 1_024)
    }

    // MARK: Reading the model

    /// Weights on disk: the GGUF file, or the safetensors of an MLX folder.
    public static func weightsBytes(_ url: URL) -> Int64 {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return 0 }
        guard directory.boolValue else {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.reduce(0) { total, file in
            // Hugging Face snapshots link to blobs: measure the target.
            let resolved = file.resolvingSymlinksInPath()
            return total + Int64((try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static let cache = ArchitectureCache()

    /// The model's shape, read once per file (GGUF header or config.json).
    public static func architecture(_ url: URL) -> Architecture? {
        if let known = cache.value(url.path) { return known }
        let read = readArchitecture(url)
        if let read { cache.set(read, for: url.path) }
        return read
    }

    private static func readArchitecture(_ url: URL) -> Architecture? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return nil }
        if directory.boolValue {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("config.json")) else { return nil }
            return architecture(config: data)
        }
        return GGUFHeader.read(url).flatMap(architecture(gguf:))
    }

    /// Hugging Face `config.json` (MLX folders); text settings may sit under `text_config`.
    public static func architecture(config data: Data) -> Architecture? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if json["num_hidden_layers"] == nil, let text = json["text_config"] as? [String: Any] { json = text }
        func int(_ key: String) -> Int? { (json[key] as? Int) ?? (json[key] as? Double).map { Int($0) } }
        guard let layers = int("num_hidden_layers"), let heads = int("num_attention_heads") else { return nil }
        let kvHeads = int("num_key_value_heads") ?? heads
        let dimension = int("head_dim") ?? int("hidden_size").map { $0 / max(heads, 1) }
        guard let dimension else { return nil }
        return Architecture(layers: layers, kvHeads: kvHeads, headDimension: dimension,
                            maxContext: int("max_position_embeddings"))
    }

    public static func architecture(gguf values: [String: GGUFHeader.Value]) -> Architecture? {
        guard case .string(let arch)? = values["general.architecture"] else { return nil }
        func int(_ key: String) -> Int? { values["\(arch).\(key)"]?.int }
        guard let layers = int("block_count"), let heads = int("attention.head_count") else { return nil }
        let kvHeads = int("attention.head_count_kv") ?? heads
        let dimension = int("attention.key_length") ?? int("embedding_length").map { $0 / max(heads, 1) }
        guard let dimension else { return nil }
        return Architecture(layers: layers, kvHeads: kvHeads, headDimension: dimension, maxContext: int("context_length"))
    }
}

private final class ArchitectureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: LocalModelMemory.Architecture] = [:]
    func value(_ key: String) -> LocalModelMemory.Architecture? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ value: LocalModelMemory.Architecture, for key: String) { lock.lock(); values[key] = value; lock.unlock() }
}

/// The key/value metadata at the start of a GGUF file (no tensor data is read).
public enum GGUFHeader {
    public enum Value: Equatable, Sendable {
        case int(Int), double(Double), bool(Bool), string(String), array
        public var int: Int? {
            switch self {
            case .int(let value): value
            case .double(let value): Int(value)
            default: nil
            }
        }
    }

    public static func read(_ url: URL, limit: Int = 32 * 1_024 * 1_024) -> [String: Value]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [String: Value]? {
        var reader = Reader(data: data)
        guard reader.bytes(4) == Data("GGUF".utf8), let version = reader.u32(), version >= 2,
              reader.u64() != nil, let count = reader.u64(), count < 100_000 else { return nil }
        var values: [String: Value] = [:]
        for _ in 0..<count {
            guard let key = reader.string(), let type = reader.u32(), let value = reader.value(type: type) else { break }
            values[key] = value
        }
        return values
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            bytes(MemoryLayout<T>.size).map { $0.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) } }
        }

        mutating func u32() -> UInt32? { integer(UInt32.self) }
        mutating func u64() -> UInt64? { integer(UInt64.self) }

        mutating func string() -> String? {
            guard let length = u64(), length < 1_000_000, let raw = bytes(Int(length)) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        /// GGUF value types: 0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 i32, 6 f32, 7 bool, 8 string, 9 array, 10 u64, 11 i64, 12 f64.
        mutating func value(type: UInt32) -> Value? {
            switch type {
            case 0: return integer(UInt8.self).map { .int(Int($0)) }
            case 1: return integer(Int8.self).map { .int(Int($0)) }
            case 2: return integer(UInt16.self).map { .int(Int($0)) }
            case 3: return integer(Int16.self).map { .int(Int($0)) }
            case 4: return u32().map { .int(Int($0)) }
            case 5: return integer(Int32.self).map { .int(Int($0)) }
            case 6: return u32().map { .double(Double(Float(bitPattern: $0))) }
            case 7: return integer(UInt8.self).map { .bool($0 != 0) }
            case 8: return string().map { .string($0) }
            case 9:
                guard let itemType = u32(), let count = u64(), count < 10_000_000 else { return nil }
                for _ in 0..<count { guard value(type: itemType) != nil else { return nil } }
                return .array
            case 10: return u64().map { .int(Int(clamping: $0)) }
            case 11: return integer(Int64.self).map { .int(Int($0)) }
            case 12: return u64().map { .double(Double(bitPattern: $0)) }
            default: return nil
            }
        }
    }
}
