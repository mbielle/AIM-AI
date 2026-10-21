import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

final class LocalModelMemoryTests: XCTestCase {
    private let qwen3_8B = LocalModelMemory.Architecture(layers: 36, kvHeads: 8, headDimension: 128, maxContext: 40_960)

    func testKVCacheOfQwen3_8B() {
        XCTAssertEqual(qwen3_8B.kvBytesPerToken(quantized: false), 147_456)
        XCTAssertEqual(qwen3_8B.kvBytesPerToken(quantized: true), 73_728)
        let estimate = LocalModelMemory.estimate(weightsBytes: 4_600_000_000, architecture: qwen3_8B, context: 32_768,
                                                 quantizedCache: false, budget: 12_000_000_000)
        XCTAssertEqual(estimate.contextBytes, 147_456 * 32_768)
        XCTAssertEqual(estimate.verdict, .fits)
        let huge = LocalModelMemory.estimate(weightsBytes: 4_600_000_000, architecture: qwen3_8B, context: 131_072,
                                             quantizedCache: false, budget: 12_000_000_000)
        XCTAssertEqual(huge.verdict, .tooLarge)
    }

    func testRecommendedAndLargestContext() {
        XCTAssertEqual(LocalModelMemory.recommendedContext(weightsBytes: 4_600_000_000, architecture: qwen3_8B, budget: 12_000_000_000), 16_384,
                       "32k needs 4.8 GB of cache in f16: above 80 % of 12 GB with the weights")
        XCTAssertEqual(LocalModelMemory.recommendedContext(weightsBytes: 4_600_000_000, architecture: qwen3_8B,
                                                           quantizedCache: true, budget: 12_000_000_000), 32_768)
        XCTAssertEqual(LocalModelMemory.recommendedContext(weightsBytes: 4_600_000_000, architecture: qwen3_8B, budget: 6_000_000_000), 2_048)
        print("GPU budget on this Mac:", LocalModelMemory.budget())
        let largest = LocalModelMemory.largestFittingContext(weightsBytes: 4_600_000_000, architecture: qwen3_8B,
                                                             quantizedCache: false, budget: 12_000_000_000)
        XCTAssertEqual(largest, 40_960, "Capped by what the model was trained for")
    }

    func testConfigJSON() throws {
        let config = #"{"num_hidden_layers":36,"num_attention_heads":32,"num_key_value_heads":8,"head_dim":128,"max_position_embeddings":40960}"#
        XCTAssertEqual(LocalModelMemory.architecture(config: Data(config.utf8)), qwen3_8B)
        let nested = #"{"text_config":{"num_hidden_layers":4,"num_attention_heads":8,"hidden_size":512}}"#
        XCTAssertEqual(LocalModelMemory.architecture(config: Data(nested.utf8)),
                       .init(layers: 4, kvHeads: 8, headDimension: 64, maxContext: nil))
    }

    func testGGUFHeader() throws {
        var data = Data("GGUF".utf8)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func string(_ value: String) { u64(UInt64(value.utf8.count)); data.append(contentsOf: value.utf8) }
        u32(3); u64(0); u64(6)
        string("general.architecture"); u32(8); string("qwen3")
        string("tokenizer.ggml.tokens"); u32(9); u32(8); u64(2); string("a"); string("b")
        for (key, value) in [("qwen3.block_count", 36), ("qwen3.attention.head_count", 32),
                             ("qwen3.attention.head_count_kv", 8), ("qwen3.context_length", 40_960)] {
            string(key); u32(4); u32(UInt32(value))
        }
        let values = try XCTUnwrap(GGUFHeader.parse(data))
        // No key_length or embedding_length: the head dimension is unknown.
        XCTAssertNil(LocalModelMemory.architecture(gguf: values))
        string("qwen3.attention.key_length"); u32(4); u32(128)
        data.replaceSubrange(16..<24, with: withUnsafeBytes(of: UInt64(7).littleEndian) { Data($0) })
        XCTAssertEqual(LocalModelMemory.architecture(gguf: try XCTUnwrap(GGUFHeader.parse(data))), qwen3_8B)
    }

    func testEngineArguments() {
        let mlx = BuiltInLocalEngine.arguments(file: URL(fileURLWithPath: "/m"), mlx: true, port: 9, name: "q",
                                               contextTokens: 16_384, kvCacheQuantized: true)
        XCTAssertEqual(mlx, ["--model", "/m", "--port", "9", "--alias", "q", "--context", "16384", "--kv-bits", "8"])
        let llama = BuiltInLocalEngine.arguments(file: URL(fileURLWithPath: "/m.gguf"), mlx: false, port: 9, name: "q",
                                                 contextTokens: 8_192, kvCacheQuantized: true)
        XCTAssertTrue(llama.contains("8192"))
        XCTAssertTrue(llama.contains("q8_0"))
    }

    func testRealGGUFWhenPresent() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIM AI/Models/unsloth/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("no local model") }
        let architecture = try XCTUnwrap(LocalModelMemory.architecture(file))
        print("GGUF architecture:", architecture)
        XCTAssertEqual(architecture.layers, 36)
        XCTAssertEqual(architecture.kvHeads, 8)
    }
}
