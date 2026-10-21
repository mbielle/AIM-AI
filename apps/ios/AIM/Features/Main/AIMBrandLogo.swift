import AIMCore
import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// One identity table for providers, model creators and connector accounts.
enum AIMBrandRegistry {
    static func identity(_ value: String) -> String {
        let raw = value.lowercased().replacingOccurrences(of: "oauth_", with: "").replacingOccurrences(of: "mcp_", with: "")
        let slug = raw.split(separator: "/").first.map(String.init) ?? raw
        let aliases = ["aionlabs": "aion-labs", "blackforestlabs": "black-forest-labs", "bfl": "black-forest-labs", "flux": "black-forest-labs", "chatgpt": "openai", "x-ai": "xai", "meta": "meta-llama", "mistral": "mistralai", "moonshot": "moonshotai", "zai": "z-ai", "slackapi": "slack", "canva-sdks": "canva", "makenotion": "notion", "hugging-face": "huggingface", "nvidia-nim": "nvidia"]
        return aliases[slug] ?? slug
    }
    static let creators: [String: String] = [
        "openai":"chatgpt_black", "anthropic":"claude", "google":"gemini", "openrouter":"openrouter", "deepseek":"deepseek", "xai":"grok_black", "perplexity":"perplexity_black", "moonshotai":"moonshot_black", "qwen":"qwen", "meta-llama":"meta", "mistralai":"mistral", "z-ai":"zai_black",
        "aion-labs":"logo-aionlabs", "amazon":"logo-nova", "arcee-ai":"logo-arcee", "baidu":"logo-baidu", "bytedance":"logo-bytedance", "bytedance-seed":"logo-bytedance", "cognitivecomputations":"logo-dolphin", "cohere":"logo-cohere", "dots-studio":"logo-dotsstudio", "fireworks":"logo-fireworks", "ibm-granite":"logo-ibm", "inception":"logo-inception", "inclusionai":"logo-antgroup", "inference-net":"logo-inference", "kwaipilot":"logo-kwaipilot", "liquid":"logo-liquid", "meituan":"logo-longcat", "microsoft":"logo-microsoft", "minimax":"logo-minimax", "morph":"logo-morph", "nousresearch":"logo-nousresearch", "nvidia":"logo-nvidia", "perceptron":"logo-perceptron", "poolside":"logo-poolside", "rekaai":"logo-reka", "relace":"logo-relace", "sakana":"logo-sakana", "stepfun":"logo-stepfun", "tencent":"logo-hunyuan", "upstage":"logo-upstage", "xiaomi":"logo-xiaomimimo", "ai21":"logo-ai21", "alibaba":"logo-alibaba", "allenai":"logo-ai2", "01-ai":"logo-yi", "baai":"logo-baai", "deepcogito":"logo-deepcogito", "essentialai":"logo-essentialai", "tiiuae":"logo-tii", "huggingface":"logo-huggingface", "lmstudio":"logo-lmstudio", "ollama":"logo-ollama", "openchat":"logo-openchat", "internlm":"logo-internlm", "thudm":"logo-chatglm", "zhipu":"logo-zhipu", "togethercomputer":"logo-together", "groq":"logo-groq", "cerebras":"logo-cerebras", "gemma":"logo-gemma", "black-forest-labs":"logo-bfl", "aim":"aim-logo", "github":"github", "slack":"slackpng", "notion":"notion"
    ]
    static func asset(for value: String) -> String { creators[identity(value)] ?? "brand-" + identity(value) }
    static func monochrome(_ asset: String) -> Bool {
        asset.contains("black") || ["openrouter", "github", "notion", "claude"].contains(asset) || ["logo-dolphin","logo-dotsstudio","logo-ibm","logo-inception","logo-inference","logo-liquid","logo-nousresearch","logo-perceptron","logo-reka","logo-relace","logo-xiaomimimo","logo-ai21","logo-baai","logo-lmstudio","logo-ollama","logo-groq","logo-bfl"].contains(asset)
    }
}

@MainActor final class AIMLogoImageCache {
    static let shared = AIMLogoImageCache()
    private var bundled: [String: UIImage] = [:]
    private var memory: [URL: UIImage] = [:]
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private var missing: [URL: Date] = [:]
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AIMBrandLogos-v1", isDirectory: true)

    func image(asset: String) -> UIImage? {
        if let image = bundled[asset] { return image }
        guard let url = Bundle.main.url(forResource: asset, withExtension: "png", subdirectory: "ModelLogos"), let bytes = try? Data(contentsOf: url), let image = Self.decode(bytes) else { return nil }
        bundled[asset] = image; return image
    }
    func cached(_ url: URL) -> UIImage? { memory[url] }
    func prewarmKnown() { for asset in Set(AIMBrandRegistry.creators.values).union(ConnectorCatalog.connectors.map { "brand-" + $0.id }).union(["brand-sambanova", "brand-deepinfra", "brand-nebius", "brand-novita", "brand-venice"]) { _ = image(asset: asset) } }
    func remote(_ url: URL) async -> UIImage? {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        if let image = memory[url] { return image }
        if let date = missing[url], Date.now.timeIntervalSince(date) < 3_600 { return nil }
        if let task = inFlight[url] { return await task.value }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".png")
        if let data = try? Data(contentsOf: file), let image = Self.decode(data) { memory[url] = image; return image }
        let task = Task<UIImage?, Never> {
            do {
                let (data, response) = try await AIMManagedNetworkSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000, let image = Self.decode(data) else { return nil }
                try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                if let png = image.pngData() { try? png.write(to: file, options: .atomic) }
                return image
            } catch { return nil }
        }
        inFlight[url] = task
        let image = await task.value; inFlight[url] = nil
        if let image { memory[url] = image } else { missing[url] = .now }
        return image
    }
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?, ["public.png","public.jpeg","org.webmproject.webp","com.compuserve.gif","public.heic"].contains(type), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:128, kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).preparingForDisplay() ?? UIImage(cgImage: cg)
    }
}

struct AIMBrandLogo: View {
    let identity: String
    var fallbackURL: URL? = nil
    var size: CGFloat = 32
    @State private var remoteImage: UIImage?
    private var asset: String { AIMBrandRegistry.asset(for: identity) }
    var body: some View {
        let bundled = AIMLogoImageCache.shared.image(asset: asset)
        Group {
            if let image = bundled ?? remoteImage {
                Image(uiImage: image).resizable().renderingMode(bundled != nil && AIMBrandRegistry.monochrome(asset) ? .template : .original).scaledToFit().padding(size * 0.13)
            } else { Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().padding(size * 0.23).foregroundStyle(.secondary) }
        }.foregroundStyle(.primary).frame(width: size, height: size)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
            .task(id: fallbackURL) {
                if bundled == nil, let fallbackURL { if let cached = AIMLogoImageCache.shared.cached(fallbackURL) { remoteImage = cached } else { remoteImage = await AIMLogoImageCache.shared.remote(fallbackURL) } }
            }
    }
}
