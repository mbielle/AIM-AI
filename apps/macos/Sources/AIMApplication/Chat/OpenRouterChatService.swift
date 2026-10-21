import Foundation
import AIMCore

public typealias ChatModel = AIMCore.ChatModel
public typealias ChatServiceError = AIMCore.ChatServiceError
public typealias ChatStreamPayload = AIMCore.ChatStreamPayload

public struct OpenRouterChatService: Sendable {
    private let session: URLSession
    private let meter: BillableRequestMeter
    public init(session: URLSession? = nil, meter: BillableRequestMeter = BillableRequestMeter()) {
        self.session = session ?? ProviderHTTPSession.make()
        self.meter = meter
    }

    public func models() async throws -> [ChatModel] {
        let (data, response) = try await session.data(from: URL(string: "https://openrouter.ai/api/v1/models?output_modalities=all")!)
        try Self.validate(response)
        struct Catalog: Decodable { let data: [ChatModel] }
        // Every model, as on openrouter.ai; the picker marks the ones that cannot chat.
        return try JSONDecoder().decode(Catalog.self, from: data).data
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stream(modelID: String, messages: [ConversationMessage], apiKey: String, mode: AIMMode) -> AsyncThrowingStream<String, Error> {
        // Keep the compatibility entry point on the same completion and
        // continuation contract as the main Chat implementation.
        ProviderChatService(session: session, meter: meter).stream(provider: .openRouter,
            modelID: modelID, messages: messages, apiKey: apiKey, mode: mode, useWebSearch: false)
    }

    public static func request(modelID: String, messages: [ConversationMessage], apiKey: String, mode: AIMMode, reasoningEffort: OpenAIReasoningEffort? = nil, extraInstruction: String? = nil, useWebSearch: Bool = false) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatServiceError.missingKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var history: [[String: Any]] = []
        if mode != .chat {
            history.append(["role": "system", "content": "You are AIM, a helpful assistant in \(mode.rawValue) mode. In this version you can discuss and propose changes, but cannot execute tools, inspect local files or control the computer. Never claim to have performed those actions."])
        }
        if let extraInstruction {
            if history.isEmpty { history.append(["role": "system", "content": extraInstruction]) }
            else { history[0]["content"] = (history[0]["content"] as? String ?? "") + "\n\n" + extraInstruction }
        }
        let selected = try ImageMessageEncoding.prepare(messages.filter { $0.role == .user || $0.role == .assistant }, provider: .openRouter)
        history += selected.map { ["role": $0.role.rawValue, "content": ImageMessageEncoding.chatCompletionsContent($0)] }
        var reasoning: [String: Any] = ["exclude": true]
        if let reasoningEffort { reasoning["effort"] = reasoningEffort == .max ? "xhigh" : reasoningEffort.rawValue }
        var body: [String: Any] = ["model": modelID, "messages": history, "stream": true,
            "usage": ["include": true], "reasoning": reasoning]
        if useWebSearch, NativeWebSearchRules.supports(provider: .openRouter, modelID: modelID) {
            body["tools"] = [NativeWebSearchRules.tool(provider: .openRouter)]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ChatServiceError.http(http.statusCode) }
    }
}
