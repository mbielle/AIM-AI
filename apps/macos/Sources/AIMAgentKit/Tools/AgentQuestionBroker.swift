import Foundation
import AIMApplication

public struct AgentQuestionItem: Codable, Equatable, Sendable {
    public let question: String
    public let options: [String]
    public let multi: Bool

    public init(question: String, options: [String] = [], multi: Bool = false) {
        self.question = question; self.options = options; self.multi = multi
    }

    private enum CodingKeys: String, CodingKey { case question, options, multi }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        question = try values.decode(String.self, forKey: .question)
        options = try values.decodeIfPresent([String].self, forKey: .options) ?? []
        multi = try values.decodeIfPresent(Bool.self, forKey: .multi) ?? false
    }
}

public struct AgentQuestion: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let conversationID: UUID
    public let items: [AgentQuestionItem]
    public var text: String { items.first?.question ?? "" }
    public var options: [String] { items.first?.options ?? [] }

    public init(id: String, conversationID: UUID, text: String, options: [String]) {
        self.init(id: id, conversationID: conversationID, items: [AgentQuestionItem(question: text, options: options)])
    }

    public init(id: String, conversationID: UUID, items: [AgentQuestionItem]) {
        self.id = id; self.conversationID = conversationID; self.items = items
    }
}

/// A tool turn remains suspended until the user answers or the run is cancelled.
public actor AgentQuestionBroker {
    private struct Pending {
        let question: AgentQuestion
        let continuation: CheckedContinuation<String?, Never>
    }
    private var pending: [String: Pending] = [:]
    private var subscribers: [UUID: AsyncStream<[AgentQuestion]>.Continuation] = [:]

    private let persistence: AgentInteractionStore?
    public init(persistence: AgentInteractionStore? = nil) { self.persistence = persistence }

    public func ask(_ question: AgentQuestion) async -> String? {
        guard !Task.isCancelled, pending[question.id] == nil, pending.count < 8 else { return nil }
        if let persistence {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                if let response = try persistence.register(id: question.id, kind: "question", sessionID: question.conversationID,
                                                           payload: encoder.encode(question)) {
                    return try JSONDecoder().decode(String.self, from: response)
                }
            } catch { return nil }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                pending[question.id] = Pending(question: question, continuation: continuation)
                publish()
            }
        } onCancel: { Task { await self.cancel(question.id) } }
    }

    @discardableResult public func answer(_ id: String, text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 4_096,
              let item = pending[id] else { return false }
        if let persistence {
            do { try persistence.answer(id: id, sessionID: item.question.conversationID, response: JSONEncoder().encode(text)) }
            catch { return false }
        }
        pending.removeValue(forKey: id)
        item.continuation.resume(returning: text)
        publish()
        return true
    }

    public func cancel(_ id: String) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.continuation.resume(returning: nil)
        publish()
    }

    public func updates() -> AsyncStream<[AgentQuestion]> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[subscriberID] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(subscriberID) } }
        }
    }

    public func snapshot() -> [AgentQuestion] {
        pending.values.map(\.question).sorted { $0.id < $1.id }
    }
    public func matchesReceipt(id: String, conversationID: UUID, text: String) -> Bool {
        guard let persistence else { return false }
        return (try? persistence.matchesResponse(id: id, kind: "question", sessionID: conversationID,
                                                 response: JSONEncoder().encode(text))) == true
    }
    private func publish() {
        let questions = snapshot()
        for subscriber in subscribers.values { subscriber.yield(questions) }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}

public actor AskUserToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["ask_user"]
    private let broker: AgentQuestionBroker
    private let conversationID: UUID
    public init(broker: AgentQuestionBroker, conversationID: UUID) {
        self.broker = broker; self.conversationID = conversationID
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard request.name == "ask_user" else {
            return ToolResult(requestID: request.id, content: "Unknown question tool.", isError: true)
        }
        let items: [AgentQuestionItem]
        if let raw = request.arguments["questions"] {
            guard request.arguments["question"] == nil, request.arguments["options"] == nil,
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AgentQuestionItem].self, from: data),
                  (1...3).contains(decoded.count), decoded.allSatisfy(Self.valid) else {
                return ToolResult(requestID: request.id, content: "questions must be a JSON array of 1–3 concise questions, each with optional choices and multi.", isError: true)
            }
            items = decoded
        } else {
            guard let text = request.arguments["question"]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return ToolResult(requestID: request.id, content: "Provide question or questions.", isError: true)
            }
            let options: [String]
            if let raw = request.arguments["options"] {
                guard let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                    return ToolResult(requestID: request.id, content: "Options must be a JSON array of short labels.", isError: true)
                }
                options = decoded
            } else { options = [] }
            let item = AgentQuestionItem(question: text, options: options)
            guard Self.valid(item) else {
                return ToolResult(requestID: request.id, content: "Ask one concise question with 0 or 2–6 distinct short choices.", isError: true)
            }
            items = [item]
        }
        let question = AgentQuestion(id: "\(conversationID.uuidString)/\(request.id)", conversationID: conversationID, items: items)
        guard let answer = await broker.ask(question) else {
            return ToolResult(requestID: request.id, content: "The question was cancelled without an answer.", isError: true)
        }
        return ToolResult(requestID: request.id, content: answer)
    }

    public func cancel(requestID: String) async { await broker.cancel("\(conversationID.uuidString)/\(requestID)") }

    private static func valid(_ item: AgentQuestionItem) -> Bool {
        let text = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf8.count <= 2_000 &&
            (item.options.isEmpty || (2...6).contains(item.options.count)) &&
            Set(item.options).count == item.options.count &&
            item.options.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 200 }
    }
}
