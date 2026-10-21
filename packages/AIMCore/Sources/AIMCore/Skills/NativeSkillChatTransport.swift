import Foundation

/// Read-only skill loop. Calls stay with the captured provider/model/key; failures are not replayed.
public struct NativeSkillChatTransport: Sendable {
    private let session: URLSession
    private let networkAdmission: @Sendable () throws -> Void
    public init(session: URLSession? = nil, networkAdmission: @escaping @Sendable () throws -> Void = AIMNetworkPrivacyPolicy.requireNetwork) { self.session = session ?? NativeChatTransport.secretSession(); self.networkAdmission = networkAdmission }
    public func stream(provider: ChatProvider, modelID: String, messages: [NativeChatMessage], key: String, instructions: String = "", maxOutputTokens: Int? = nil, webSearch: Bool = false, catalogMaximum: Int? = nil, skills: [NativeSkill] = [], projectSources: (any ProjectSourceToolRuntime)? = nil, research: (any AIMResearchToolRuntime)? = nil, researchAdmission: (@Sendable (Int, TokenUsage, NativeWebSearchUsage) async throws -> Int?)? = nil, researchWillExecute: (@Sendable (TokenUsage, NativeWebSearchUsage) async throws -> Void)? = nil, admission: (@Sendable () async throws -> Void)? = nil) -> AsyncThrowingStream<NativeChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try networkAdmission()
                    guard NativeSkillToolRuntime.supports(provider) else { throw NativeSkillError.unsupportedModel }
                    let runtime = NativeSkillToolRuntime(skills: skills)
                    guard !webSearch || research == nil else { throw AIMResearchError.invalidArguments }
                    let joined = [instructions, runtime.catalogInstructions, projectSources == nil ? "" : ProjectSourceTools.instructions, research == nil ? "" : AIMResearchTools.instructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    var request = try NativeChatTransport.request(provider: provider, modelID: modelID, messages: messages, key: key, instructions: joined, maxOutputTokens: maxOutputTokens, webSearch: webSearch, catalogMaximum: catalogMaximum)
                    guard var body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any], var history = body["messages"] as? [[String: Any]] else { throw NativeSkillError.unsupportedModel }
                    body["stream"] = false; body.removeValue(forKey: "stream_options")
                    let definitions = (runtime.skills.isEmpty ? [] : NativeSkillToolRuntime.tools) + (projectSources == nil ? [] : ProjectSourceTools.tools) + (research == nil ? [] : AIMResearchTools.tools)
                    let skillTools: [[String: Any]] = provider == .anthropic ? definitions : definitions.map { item in
                        ["type": "function", "function": ["name": item["name"]!, "description": item["description"]!, "parameters": item["input_schema"]!]]
                    }
                    body["tools"] = (body["tools"] as? [[String: Any]] ?? []) + skillTools
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    var cumulativeUsage = TokenUsage()
                    var searchUsage = NativeWebSearchUsageAccumulator()
                    var researchModelCharges = NativeWebSearchUsageAccumulator()
                    var toolCalls = 0, projectResultBytes = 0
                    while true {
                        try Task.checkCancellation()
                        try networkAdmission()
                        try await NetworkAvailability.wait { continuation.yield(.init(connectionWaiting: true)) }
                        try Task.checkCancellation(); try networkAdmission()
                        try await admission?()
                        try Task.checkCancellation()
                        continuation.yield(.init(connectionWaiting: false))
                        body["messages"] = history; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        if let research, let researchAdmission {
                            let metadata = await AIMResearchAccounting.combined(modelTotalUSD: researchModelCharges.usage.providerTotalCostUSD, research: research.usage())
                            if let maximum = try await researchAdmission(request.httpBody?.count ?? 0, cumulativeUsage, metadata) {
                                guard maximum > 0 else { throw AIMResearchError.limitReached }
                                body["max_tokens"] = maximum
                                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                            }
                        }
                        if let research {
                            // The next model request has no receipt yet. Do not retain an earlier round's
                            // partial invoice as the confirmed whole turn if this request becomes uncertain.
                            continuation.yield(.init(webSearchUsage: await AIMResearchAccounting.combined(modelTotalUSD: nil, research: research.usage())))
                        }
                        let (data, response) = try await session.data(for: request)
                        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { throw ChatServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
                        continuation.yield(.init(requestAccepted: true))
                        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else { throw ChatServiceError.invalidResponse }
                        // A valid provider receipt is accounting evidence even when its tool
                        // arguments or answer are unusable. Preserve it before content validation.
                        if let usage = TokenUsageParser.parse(data) { cumulativeUsage.add(usage); continuation.yield(.init(usage: cumulativeUsage)) }
                        if let research {
                            let reported = provider == .openRouter ? NativeWebSearchRules.usage(String(decoding: data, as: UTF8.self), provider: provider) : nil
                            researchModelCharges.append(reported)
                            continuation.yield(.init(webSearchUsage: AIMResearchAccounting.combined(modelTotalUSD: researchModelCharges.usage.providerTotalCostUSD, research: await research.usage())))
                        }
                        var calls: [(id: String, name: String, args: [String: String])] = []
                        var text = ""
                        var interrupted = false
                        if provider == .anthropic {
                            guard let content = root["content"] as? [[String: Any]], let stop = root["stop_reason"] as? String else { throw NativeSkillError.incomplete }
                            for item in content {
                                if item["type"] as? String == "text" { text += item["text"] as? String ?? "" }
                                if item["type"] as? String == "tool_use" {
                                    guard let id = item["id"] as? String, let name = item["name"] as? String,
                                          let args = item["input"] as? [String: String] else { throw ChatServiceError.invalidResponse }
                                    calls.append((id, name, args))
                                }
                            }
                            interrupted = stop != "end_turn" && stop != "tool_use"
                            history.append(["role": "assistant", "content": content])
                        } else {
                            guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first, let message = choice["message"] as? [String: Any], let stop = choice["finish_reason"] as? String else { throw NativeSkillError.incomplete }
                            interrupted = !["stop", "tool_calls"].contains(stop)
                            text = message["content"] as? String ?? message["refusal"] as? String ?? ""
                            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                                guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                                      let name = function["name"] as? String, let raw = function["arguments"] as? String,
                                      let value = raw.data(using: .utf8),
                                      let args = (try? JSONSerialization.jsonObject(with: value)) as? [String: String] else { throw ChatServiceError.invalidResponse }
                                calls.append((id, name, args))
                            }
                            history.append(message)
                        }
                        if !text.isEmpty { continuation.yield(.init(text: text)) }
                        if webSearch {
                            var normalized = root
                            if provider == .anthropic { normalized["type"] = "message_delta" }
                            let usageRaw = String(decoding: try JSONSerialization.data(withJSONObject: normalized), as: UTF8.self)
                            searchUsage.append(NativeWebSearchRules.usage(usageRaw, provider: provider))
                            continuation.yield(.init(webSearchUsage: searchUsage.usage))
                            if provider == .anthropic {
                                let content = (root["content"] as? [[String: Any]] ?? []).filter { ["server_tool_use", "web_search_tool_result"].contains($0["type"] as? String ?? "") }
                                let activityRaw = String(decoding: try JSONSerialization.data(withJSONObject: ["message": ["content": content]]), as: UTF8.self)
                                let observed = NativeWebSearchRules.activities(activityRaw, provider: provider)
                                if !observed.isEmpty { continuation.yield(.init(webSearchActivities: observed)) }
                            }
                            var sources: [(String, String)] = []
                            if provider == .anthropic {
                                for block in root["content"] as? [[String: Any]] ?? [] {
                                    if block["type"] as? String == "web_search_tool_result", block["content"] is [String: Any] { throw ChatServiceError.webSearchFailed }
                                    for item in block["citations"] as? [[String: Any]] ?? [] { if let url = item["url"] as? String { sources.append((url, item["title"] as? String ?? url)) } }
                                }
                            } else {
                                for choice in root["choices"] as? [[String: Any]] ?? [] {
                                    for item in (choice["message"] as? [String: Any])?["annotations"] as? [[String: Any]] ?? [] {
                                        let cite = item["url_citation"] as? [String: Any] ?? item
                                        if let url = cite["url"] as? String { sources.append((url, cite["title"] as? String ?? url)) }
                                    }
                                }
                            }
                            var seen = Set<String>()
                            let safeSources = sources.filter { raw, _ in
                                guard raw.rangeOfCharacter(from: .whitespacesAndNewlines.union(.init(charactersIn: "()<>\\"))) == nil, let url = URLComponents(string: raw), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return false }
                                return seen.insert(raw).inserted
                            }
                            if !safeSources.isEmpty { continuation.yield(.init(sources: safeSources.enumerated().compactMap { index, item in ConversationSource(url: item.0, title: item.1, references: [index + 1]) })) }
                        }
                        if interrupted { throw NativeSkillError.incomplete }
                        if calls.isEmpty {
                            guard !text.isEmpty else { throw ChatServiceError.emptyResponse }
                            continuation.yield(.init(isComplete: true)); continuation.finish(); return
                        }
                        guard toolCalls + calls.count <= ProjectSourceTools.maximumCalls else { throw ProjectSourceToolError.callLimit }
                        toolCalls += calls.count
                        var results: [[String: Any]] = []
                        for call in calls {
                            try Task.checkCancellation()
                            // Revalidate captured ownership, permissions and budget before every tool access too.
                            try await admission?()
                            try Task.checkCancellation()
                            let began = Date.now
                            if let research, AIMResearchTools.contains(call.name) {
                                if let researchWillExecute {
                                    try await researchWillExecute(cumulativeUsage, await AIMResearchAccounting.combined(modelTotalUSD: researchModelCharges.usage.providerTotalCostUSD, research: research.usage()))
                                }
                                let activity = try await research.activity(name: call.name, arguments: call.args, callID: call.id)
                                continuation.yield(.init(webSearchActivities: [activity]))
                                do {
                                    let result = try await research.execute(name: call.name, arguments: call.args)
                                    try Task.checkCancellation(); try await admission?(); try Task.checkCancellation()
                                    projectResultBytes += result.text.utf8.count
                                    guard projectResultBytes <= ProjectSourceTools.maximumTurnResultBytes else { throw AIMResearchError.responseTooLarge }
                                    var completed = activity; completed.status = .completed; completed.output = result.text
                                    continuation.yield(.init(webSearchUsage: AIMResearchAccounting.combined(modelTotalUSD: researchModelCharges.usage.providerTotalCostUSD, research: await research.usage()), webSearchActivities: [completed], sources: result.sources))
                                    if provider == .anthropic { results.append(["type": "tool_result", "tool_use_id": call.id, "content": result.text, "is_error": false]) }
                                    else { history.append(["role": "tool", "tool_call_id": call.id, "content": result.text]) }
                                } catch {
                                    var failed = activity; failed.status = .failed
                                    continuation.yield(.init(webSearchUsage: AIMResearchAccounting.combined(modelTotalUSD: researchModelCharges.usage.providerTotalCostUSD, research: await research.usage()), webSearchActivities: [failed]))
                                    throw error
                                }
                                continue
                            }
                            continuation.yield(.init(skillActivities: [.init(id: call.id, name: call.name, skill: call.args["name"] ?? call.args["query"] ?? call.args["sourceID"] ?? "", path: call.args["path"] ?? call.args["chunkID"], running: true, startedAt: began)]))
                            var failed = false
                            let result: String
                            if ProjectSourceTools.contains(call.name) {
                                guard let projectSources else { throw ProjectSourceToolError.unavailable }
                                do { result = try await ProjectSourceTools.execute(name: call.name, arguments: call.args, runtime: projectSources) }
                                catch is CancellationError { throw CancellationError() }
                                catch let error as ProjectSourceToolError { throw error }
                                catch { throw ProjectSourceToolError.unavailable }
                                projectResultBytes += result.utf8.count
                                guard projectResultBytes <= ProjectSourceTools.maximumTurnResultBytes else { throw ProjectSourceToolError.resultLimit }
                            } else {
                                do { result = try runtime.execute(name: call.name, arguments: call.args) }
                                catch { result = error.localizedDescription; failed = true }
                            }
                            try Task.checkCancellation()
                            try await admission?()
                            try Task.checkCancellation()
                            continuation.yield(.init(skillActivities: [.init(id: call.id, name: call.name, skill: call.args["name"] ?? call.args["query"] ?? call.args["sourceID"] ?? "", path: call.args["path"] ?? call.args["chunkID"], isError: failed, running: false, startedAt: began, finishedAt: .now, detail: result)]))
                            if provider == .anthropic { results.append(["type": "tool_result", "tool_use_id": call.id, "content": result, "is_error": failed]) }
                            else { history.append(["role": "tool", "tool_call_id": call.id, "content": result]) }
                        }
                        if provider == .anthropic { history.append(["role": "user", "content": results]) }
                    }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
