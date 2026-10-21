import AIMApplication
import Foundation

/// Catalogs only the host registrations for this run. Discovery reveals schemas,
/// never approval or new scope. Actual calls still go through the dispatcher.
public struct ProgressiveToolCatalog: ToolExecutor {
    public let supportedTools: Set<String> = ["discover_tools"]
    private let definitions: [ModelToolDefinition]
    public static let definition = ModelToolDefinition(name: "discover_tools",
        description: "Find authorized tools by name or task. Returns at most eight schemas and makes those tools available for the next model turn. Use offset to page; discovery grants no permission to execute.",
        optionalArguments: ["query", "offset"], argumentKinds: ["offset": .integer])

    public init(definitions: [ModelToolDefinition]) { self.definitions = definitions.sorted { $0.name < $1.name } }
    public func execute(_ request: ToolRequest) async -> ToolResult {
        let query = (request.arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.utf8.count <= 512, let offset = Int(request.arguments["offset"] ?? "0"), offset >= 0 else {
            return ToolResult(requestID: request.id, content: "Provide a query up to 512 bytes and a nonnegative offset.", isError: true)
        }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var matches: [(definition: ModelToolDefinition, score: Int)] = []
        for item in definitions {
            let name = item.name.lowercased()
            let text = (item.name + " " + item.description).lowercased()
            var score = 0
            for word in words {
                if name.contains(word) { score += 4 }
                else if text.contains(word) { score += 1 }
            }
            if words.isEmpty || score > 0 { matches.append((item, score)) }
        }
        matches.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.definition.name < right.definition.name
        }
        let page: [ModelToolDefinition] = matches.dropFirst(min(offset, matches.count)).prefix(8).map { $0.definition }
        let records = page.map { item -> [String: Any] in
            ["name": item.name, "description": item.description,
             "required": item.requiredArguments.sorted(), "optional": item.optionalArguments.sorted(),
             "argument_kinds": item.argumentKinds.mapValues { $0.rawValue }]
        }
        do {
            let nextOffset: Any = offset + page.count < matches.count ? (offset + page.count) as Any : NSNull()
            let payload: [String: Any] = ["tools": records, "total": matches.count, "next_offset": nextOffset]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            let names = String(decoding: try JSONEncoder().encode(page.map { $0.name }), as: UTF8.self)
            return ToolResult(requestID: request.id, content: text, metadata: ["discovered_tools": names])
        } catch { return ToolResult(requestID: request.id, content: "Tool catalog encoding failed.", isError: true) }
    }

    public func cancel(requestID: String) async {}

    public static func assemble(_ tools: [RegisteredTool], descriptions: [String: String]) ->
        (registered: [RegisteredTool], initial: [ModelToolDefinition], available: [ModelToolDefinition]) {
        let available = tools.map { item in
            ModelToolDefinition(name: item.name, description: LocalModelProfile.compact(descriptions[item.name] ?? item.name),
                requiredArguments: item.requiredArguments, optionalArguments: item.optionalArguments, argumentKinds: item.argumentKinds)
        }
        let service = ProgressiveToolCatalog(definitions: available)
        let discover = RegisteredTool(name: definition.name, risk: .readOnly,
            optionalArguments: definition.optionalArguments, argumentKinds: definition.argumentKinds, executor: service)
        return (tools + [discover], available.filter { LocalModelProfile.allowedTools.contains($0.name) } + [definition], available + [definition])
    }
}
