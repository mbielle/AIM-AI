import Foundation

/// OpenRouter's public catalog describes most models (price, context, description,
/// capabilities). Models reached through another provider borrow those facts when the
/// same model is listed there; nothing is invented when it is not.
public enum ModelCatalogDetails {
    /// Enrich a complete provider catalog using one public reference index.
    public static func enrich(_ models: [ChatModel], provider: ChatProvider, publicModels: [ChatModel]) -> [ChatModel] {
        let references = index(publicModels)
        return models.map { enriched($0, provider: provider, index: references) }
    }

    public static func creator(for model: ChatModel, via route: ChatProvider) -> String {
        if route == .chatgpt { return "openai" }
        let hosts = route == .openRouter || (CompatibleProviders.spec(route).map { $0.group != .open } ?? false)
        guard hosts else { return route.rawValue }
        guard model.id.contains("/") else { return route == .openRouter ? "other" : route.rawValue }
        return normalizedCreator(model.id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "other")
    }

    public static func normalizedCreator(_ value: String) -> String {
        let slug = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "~ "))
        switch slug {
        case "xai", "x-ai": return "xai"
        case "moonshot", "moonshotai": return "moonshotai"
        case "zai", "z.ai", "z-ai": return "z-ai"
        case "meta", "meta-llama": return "meta-llama"
        case "mistral", "mistralai": return "mistralai"
        default: return slug
        }
    }

    public static func identity(_ id: String, provider: ChatProvider) -> String {
        let maker = creator(for: ChatModel(id: id, name: id), via: provider)
        var local = id.lowercased()
        if let slash = local.firstIndex(of: "/") { local = String(local[local.index(after: slash)...]) }
        return maker + "/" + local.replacingOccurrences(of: ".", with: "-")
    }

    /// The OpenRouter catalog keyed by model identity, built once per catalog load.
    public static func index(_ catalog: [ChatModel]) -> [String: ChatModel] {
        var result: [String: ChatModel] = [:]
        for model in catalog {
            let key = canonical(identity(model.id, provider: .openRouter))
            // A paid listing describes the model better than its ":free" twin (real prices).
            if let existing = result[key], !(existing.id.hasSuffix(":free") && !model.id.hasSuffix(":free")) { continue }
            result[key] = model
        }
        return result
    }

    public static func reference(for model: ChatModel, provider: ChatProvider, in index: [String: ChatModel]) -> ChatModel? {
        index[canonical(identity(model.id, provider: provider))]
    }

    public static func enriched(_ model: ChatModel, provider: ChatProvider, catalog: [ChatModel]) -> ChatModel {
        enriched(model, provider: provider, index: index(catalog))
    }

    /// `model` with any missing catalog facts filled from its OpenRouter reference.
    public static func enriched(_ model: ChatModel, provider: ChatProvider, index: [String: ChatModel]) -> ChatModel {
        guard let reference = reference(for: model, provider: provider, in: index) else { return model }
        var result = model
        result.summary = model.summary ?? reference.summary
        result.pricing = model.pricing ?? reference.pricing
        result.knowledgeCutoff = model.knowledgeCutoff ?? reference.knowledgeCutoff
        result.topProvider = model.topProvider ?? reference.topProvider
        result.reasoning = model.reasoning ?? reference.reasoning
        // Fill each modality field independently. A missing output description
        // must not overwrite a provider's known input capabilities.
        if model.architecture != nil || reference.architecture != nil {
            result.architecture = .init(inputModalities: model.architecture?.inputModalities ?? model.inputModalities
                ?? reference.architecture?.inputModalities ?? reference.inputModalities,
                outputModalities: model.architecture?.outputModalities ?? reference.architecture?.outputModalities)
        }
        if result.supportedParameters == nil { result.supportedParameters = reference.supportedParameters }
        return result.withFallback(reference)
    }

    /// Dated snapshots and "-latest" aliases describe the same model family entry.
    public static func canonical(_ identity: String) -> String {
        var value = identity
        for pattern in [#"-\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#, #"-latest$"#, #":free$"#] {
            if let range = value.range(of: pattern, options: .regularExpression) { value.removeSubrange(range) }
        }
        return value
    }
}

private extension ChatModel {
    /// Fields that are `let` can only come from the reference through a rebuilt value.
    func withFallback(_ reference: ChatModel) -> ChatModel {
        guard contextLength == nil || maxOutputTokens == nil || (architecture == nil && inputModalities == nil) || created == nil else { return self }
        var copy = ChatModel(id: id, name: name, contextLength: contextLength ?? reference.contextLength,
                             inputModalities: inputModalities ?? reference.architecture?.inputModalities ?? reference.inputModalities,
                             created: created ?? reference.created, maxOutputTokens: maxOutputTokens ?? reference.maxOutputTokens)
        copy.supportedParameters = supportedParameters
        copy.summary = summary
        copy.pricing = pricing
        copy.knowledgeCutoff = knowledgeCutoff
        copy.topProvider = topProvider
        copy.reasoning = reasoning
        copy.architecture = architecture
        return copy
    }
}
