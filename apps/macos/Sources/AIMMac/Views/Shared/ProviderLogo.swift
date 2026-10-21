import AIMCore
import AppKit
import ImageIO
import AIMApplication
import SwiftUI

struct ProviderLogo: View {
    let provider: ChatProvider
    var size: CGFloat = 24
    private var asset: String {
        switch provider {
        case .openAI: "chatgpt_black"
        case .anthropic: "claude"
        case .google: "gemini"
        case .openRouter: "openrouter"
        case .deepSeek: "deepseek"
        case .xAI: "grok_black"
        case .perplexity: "perplexity_black"
        case .local: ""
        case .chatgpt: "chatgpt_black"
        default: CompatibleProviders.spec(provider).map { "logo-" + $0.logo } ?? ""
        }
    }

    /// Providers without a bundled logo show their company's GitHub avatar.
    private static let githubAvatars: [ChatProvider: String] = [
        .sambanova: "sambanova", .deepinfra: "deepinfra", .nebius: "nebius", .novita: "novitalabs", .venice: "veniceai",
    ]

    var body: some View {
        if provider == .local {
            Image(systemName: "desktopcomputer").font(.system(size: size * 0.7)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else if let org = Self.githubAvatars[provider] {
            RemoteLogo(url: "https://github.com/\(org).png?size=96", fallback: "cloud", size: size)
        } else {
            CachedCreatorAsset(asset: asset, size: size)
        }
    }
}

struct ModelCreatorLogo: View {
    let creator: String
    var size: CGFloat = 22

    var body: some View {
        if let provider = providerForCreator {
            ProviderLogo(provider: provider, size: size)
        } else if let asset = extraAsset {
            CachedCreatorAsset(asset: asset, size: size)
        } else {
            CreatorAvatar(creator: ModelIdentity.normalizedCreator(creator), size: size)
        }
    }

    private var extraAsset: String? {
        switch ModelIdentity.normalizedCreator(creator) {
        case "moonshotai": "moonshot_black"
        case "qwen": "qwen"
        case "meta-llama": "meta"
        case "mistralai": "mistral"
        case "z-ai": "zai_black"
        default: Self.lobeLogos[ModelIdentity.normalizedCreator(creator)].map { "logo-" + $0 }
        }
    }

    /// Creator slug (as in OpenRouter ids) → Lobe Icons file (Resources/ModelLogos, MIT).
    static let lobeLogos: [String: String] = [
        "aion-labs": "aionlabs", "amazon": "nova", "arcee-ai": "arcee", "baidu": "baidu", "bytedance": "bytedance",
        "bytedance-seed": "bytedance", "cognitivecomputations": "dolphin", "cohere": "cohere", "dots-studio": "dotsstudio",
        "fireworks": "fireworks", "ibm-granite": "ibm", "inception": "inception", "inclusionai": "antgroup",
        "inference-net": "inference", "kwaipilot": "kwaipilot", "liquid": "liquid", "meituan": "longcat",
        "microsoft": "microsoft", "minimax": "minimax", "morph": "morph", "nousresearch": "nousresearch",
        "nvidia": "nvidia", "perceptron": "perceptron", "poolside": "poolside", "rekaai": "reka", "relace": "relace",
        "sakana": "sakana", "stepfun": "stepfun", "tencent": "hunyuan", "upstage": "upstage", "xiaomi": "xiaomimimo",
        "ai21": "ai21", "alibaba": "alibaba", "allenai": "ai2", "01-ai": "yi", "baai": "baai", "deepcogito": "deepcogito",
        "essentialai": "essentialai", "tiiuae": "tii", "huggingface": "huggingface", "lmstudio": "lmstudio",
        "ollama": "ollama", "openchat": "openchat", "internlm": "internlm", "thudm": "chatglm", "zhipu": "zhipu",
        "togethercomputer": "together", "groq": "groq", "cerebras": "cerebras", "gemma": "gemma",
        "black-forest-labs": "bfl",
    ]

    private var providerForCreator: ChatProvider? {
        switch ModelIdentity.normalizedCreator(creator) {
        case "openai": .openAI
        case "anthropic": .anthropic
        case "google": .google
        case "deepseek": .deepSeek
        case "xai", "x-ai": .xAI
        case "perplexity": .perplexity
        default: nil
        }
    }
}

private struct CachedCreatorAsset: View {
    let asset: String
    let size: CGFloat

    /// Single-color logos follow the text color, so they stay visible in dark mode.
    static func isMonochrome(_ asset: String) -> Bool {
        asset.contains("black") || asset == "openrouter" || asset == "claude" || monochromeLobe.contains(asset)
    }
    private static let monochromeLobe: Set<String> = [
        "logo-dolphin", "logo-dotsstudio", "logo-ibm", "logo-inception", "logo-inference", "logo-liquid",
        "logo-nousresearch", "logo-perceptron", "logo-reka", "logo-relace", "logo-xiaomimimo", "logo-ai21", "logo-baai",
        "logo-lmstudio", "logo-ollama", "logo-groq", "logo-moonshot", "logo-zai", "logo-openai", "logo-anthropic",
        "logo-grok", "logo-xai", "logo-bfl",
    ]
    @MainActor private static var images: [String: NSImage] = [:]
    private var bitmap: NSImage? {
        if let image = Self.images[asset] { return image }
        guard let url = Bundle.module.url(forResource: asset, withExtension: "png"), let original = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        original.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        image.unlockFocus()
        Self.images[asset] = image
        return image
    }
    var body: some View {
        Group {
            if let bitmap {
                Image(nsImage: bitmap).resizable()
                    .renderingMode(Self.isMonochrome(asset) ? .template : .original)
                    .scaledToFit().foregroundStyle(.primary)
            } else { Image(systemName: "sparkles").foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A creator without a bundled logo: its Hugging Face profile picture (fetched once, then
/// cached on this Mac), or a colored initial meanwhile and when there is none.
struct CreatorAvatar: View {
    let creator: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                Text(String(ModelIdentity.creatorName(creator).prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Self.color(for: creator), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            }
        }
        .accessibilityHidden(true)
        .task(id: creator) { image = await CreatorAvatarCache.shared.image(for: creator) }
    }

    /// A stable, muted color per creator.
    static func color(for creator: String) -> Color {
        let hash = creator.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.38, brightness: 0.62)
    }
}

/// Hugging Face avatars by organization or user name, cached in ~/Library/Caches/AIM AI.
actor CreatorAvatarCache {
    static let shared = CreatorAvatarCache()
    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    // v2: earlier versions could store SVG avatars, which crash macOS's SVG renderer.
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: AIMInstallationContext.legacyDirectoryName + "/CreatorAvatars-v2", directoryHint: .isDirectory)

    func image(for creator: String) async -> NSImage? {
        let name = creator.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "~ "))
        guard !name.isEmpty, name.range(of: #"^[a-z0-9][a-z0-9._-]{0,95}$"#, options: .regularExpression) != nil else { return nil }
        if let image = memory[name] { return image }
        if missing.contains(name) { return nil }
        let file = directory.appending(path: name + ".img")
        let marker = directory.appending(path: name + ".none")
        if let data = try? Data(contentsOf: file), let image = Self.bitmap(from: data) { memory[name] = image; return image }
        if let date = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date,
           Date.now.timeIntervalSince(date) < 7 * 86_400 { missing.insert(name); return nil }
        if let task = inFlight[name] { return await task.value }
        let task = Task<NSImage?, Never> { await Self.download(name) }
        inFlight[name] = task
        let image = await task.value
        inFlight[name] = nil
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let image, let data = Self.png(image) {
            memory[name] = image
            try? data.write(to: file, options: .atomic)
        } else {
            missing.insert(name)
            try? Data().write(to: marker, options: .atomic)
        }
        return image
    }

    /// Decodes PNG, JPEG, WebP or GIF only (ImageIO, first frame), scaled to 128 px. SVG and
    /// other vector formats are refused: some crash macOS's SVG renderer while drawing.
    static func bitmap(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "org.webmproject.webp", "com.compuserve.gif", "public.heic"].contains(type) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 128,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private static func download(_ name: String) async -> NSImage? {
        for kind in ["organizations", "users"] {
            guard let api = URL(string: "https://huggingface.co/api/\(kind)/\(name)/avatar"),
                  let (data, response) = try? await RuntimeManagedNetworkSession.shared.data(from: api),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let link = json["avatarUrl"] as? String, let url = URL(string: link),
                  url.scheme == "https", url.host?.hasSuffix("huggingface.co") == true,
                  let (bytes, _) = try? await RuntimeManagedNetworkSession.shared.data(from: url),
                  bytes.count < 2_000_000, let image = bitmap(from: bytes) else { continue }
            return image
        }
        return nil
    }
}
