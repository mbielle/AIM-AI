import AIMAgentKit
import AIMCore
#if DEBUG
import AIMApplication
import AppKit
import Foundation

/// Throwaway conversations for the debug gallery (in-memory database only).
@MainActor
enum GalleryFixtures {
    /// A local model's answer with a numbered list and bold lead-ins: it used to render with
    /// "…" at the end of list items and a wide gap after the bold text.
    static let listAnswer = """
    La quantisation de l'intelligence artificielle (IA) consiste à réduire la précision des données utilisées dans un modèle (ex. : passer de 32 bits à 16 ou 8 bits). Cela permet de :

    1. **Réduire la taille du modèle** : Moins de mémoire nécessaire pour stocker les paramètres.  
    2. **Accélérer les calculs** : Les opérations sur des nombres à faible précision sont plus rapides, surtout sur hardware optimisé (ex. : appareils mobiles, microcontrôleurs).  
    3. **Diminuer la consommation d'énergie** : Utile pour les applications en temps réel ou en périphérie (edge computing).  

    **Limites** : Peut entraîner une perte d'exactitude, surtout si la quantisation est trop agressive. Elle nécessite souvent une calibration (ex. : quantisation post-training ou quantisation-aware training) pour minimiser cet effet.  

    Exemple : Un modèle en précision 8 bits peut être exécuté 2 à 10 fois plus vite qu'un modèle en 32 bits, avec une perte de précision négligeable dans certains cas.
    """

    /// A sidebar with every status: running, unread, failed and idle, chats and agent tasks.
    static func sidebar(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        let titles: [(String, AIMMode)] = [("Plan de la semaine", .agent), ("Recette de crêpes", .chat),
            ("Quantisation des modèles", .chat), ("Trier les fichiers du bureau", .agent),
            ("Résumé de réunion", .chat), ("Idées de cadeau", .chat)]
        var created: [Conversation] = []
        for (index, item) in titles.enumerated() {
            let date = Date.now.addingTimeInterval(Double(-index) * 600)
            let conversation = Conversation(title: item.0, mode: item.1, createdAt: date, updatedAt: date)
            do {
                try await model.conversationRepository.save(conversation)
                try await model.conversationRepository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: item.0, sequence: 0))
            } catch { continue }
            created.append(conversation)
        }
        model.conversations = created + model.conversations
        model.debugRunningConversationID = created.first?.id
        if created.count > 2 { model.lastReadAt[created[1].id] = Date.now.addingTimeInterval(-86_400) }
        if created.count > 3 { model.failedConversations.insert(created[3].id) }
        if created.count > 4 { model.lastReadAt[created[4].id] = .now }
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("sidebar\(suffix).png"))
        model.debugOpenMenu = "sidebar-filter"
        try? await Task.sleep(for: .milliseconds(900))
        capture(folder.appendingPathComponent("sidebar-filter\(suffix).png"))
        model.debugOpenMenu = "sidebar-search"
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("sidebar-search\(suffix).png"))
        model.debugOpenMenu = nil
        model.debugRunningConversationID = nil
    }

    /// The profile with two months of made-up usage.
    static func profile(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        var metrics: [TurnMetrics] = []
        var activity: [Date] = []
        let models = [("openrouter", "anthropic/claude-sonnet-5.5"), ("local", "Qwen3-8B-4bit"), ("anthropic", "claude-opus-5-5"), ("openai", "gpt-5.5")]
        for day in 0..<70 where day % 7 != 3 && day % 11 != 5 {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: .now)!
            activity.append(date)
            for turn in 0..<(1 + (day * 7) % 5) {
                let (provider, id) = models[(day + turn) % models.count]
                let output = 300 + (day * 37 + turn * 91) % 2_400
                metrics.append(TurnMetrics(provider: provider, modelID: id, mode: turn % 3 == 0 ? "agent" : "chat",
                    effort: turn % 2 == 0 ? "high" : "medium", startedAt: date.addingTimeInterval(Double(-turn) * 900),
                    usage: TokenUsage(inputTokens: 2_000 + day * 400 + turn * 3_000, outputTokens: output,
                                      promptSeconds: provider == "local" ? 0.6 : nil, generationSeconds: provider == "local" ? Double(output) / 27 : nil),
                    firstTokenSeconds: 0.6, streamSeconds: Double(output) / 60, totalSeconds: Double(output) / 50 + Double(turn * 40)))
            }
        }
        model.debugProfileSample = (metrics.sorted { $0.startedAt < $1.startedAt }, activity,
                                    [("read_file", 214), ("run_command", 96), ("web_search", 61), ("apply_edit", 44), ("desktop_observe_window", 17)])
        model.settingsSection = .profile
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("profile\(suffix).png"))
        model.settingsSection = nil
        model.debugProfileSample = nil
    }

    /// A local model's settings page: recommended, then a context too large for this Mac.
    static func localSettings(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIM AI/Models/unsloth/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let name = "Gallery-Qwen3-8B"
        model.pendingLocalModelSettings = LocalModelBrowser.settingsDetail(name: name, file: file)
        model.showModelPicker = true
        try? await Task.sleep(for: .seconds(3))
        capture(folder.appendingPathComponent("local-settings\(suffix).png"))
        var large = LocalModelSettings()
        large.contextTokens = 131_072
        large.temperature = 1.2
        LocalModelSettingsStore.shared.save(large, for: name)
        model.showModelPicker = false
        try? await Task.sleep(for: .milliseconds(600))
        model.pendingLocalModelSettings = LocalModelBrowser.settingsDetail(name: name, file: file)
        model.showModelPicker = true
        try? await Task.sleep(for: .seconds(3))
        capture(folder.appendingPathComponent("local-settings-large\(suffix).png"))
        model.debugOpenMenu = "local-sampling"
        try? await Task.sleep(for: .seconds(1))
        capture(folder.appendingPathComponent("local-settings-sampling\(suffix).png"))
        model.debugOpenMenu = nil
        LocalModelSettingsStore.shared.save(LocalModelSettings(), for: name)
        model.showModelPicker = false
        model.selectedProvider = .local
        model.selectedModelID = "Qwen3-8B-4bit"
    }

    /// Customize: each tab in Discover and Yours, and the Add menu (live public store).
    static func customize(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        for page in ["skills-discover", "connectors-discover", "connectors-discover-detail", "skills-discover-detail", "skills-yours"] {
            model.showCustomize = false
            model.debugOpenMenu = "customize-" + page
            try? await Task.sleep(for: .milliseconds(300))
            model.showCustomize = true
            try? await Task.sleep(for: .seconds(page.hasSuffix("discover") ? 7 : 2))
            capture(folder.appendingPathComponent("customize-\(page)\(suffix).png"))
        }
        model.debugOpenMenu = nil
        model.showCustomize = false
    }

    /// Opening conversations one after the other, captured frame by frame (no welcome flash,
    /// no raw Markdown), and the Chat ↔ Agent switch on the new-conversation screen.
    static func switching(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        var ids: [UUID] = []
        for index in 0..<2 {
            let conversation = Conversation(title: "Conversation \(index + 1)", mode: .chat, provider: .local, modelID: "Qwen3-8B-4bit")
            do {
                try await model.conversationRepository.save(conversation)
                try await model.conversationRepository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Question \(index + 1)", sequence: 0))
                try await model.conversationRepository.append(ConversationMessage(conversationID: conversation.id, role: .assistant,
                    content: "## Partie \(index + 1)\n\n" + listAnswer + "\n\n| A | B |\n|---|---|\n| **x** | y |", sequence: 1))
            } catch { continue }
            model.conversations.insert(conversation, at: 0)
            ids.append(conversation.id)
        }
        guard ids.count == 2 else { return }
        for (step, id) in ids.enumerated() {
            let task = Task { await model.selectConversation(id) }
            for (frame, delay) in [0, 30, 60, 120, 250, 450].enumerated() {
                try? await Task.sleep(for: .milliseconds(delay == 0 ? 0 : delay - ([0, 30, 60, 120, 250, 450][max(frame - 1, 0)])))
                capture(folder.appendingPathComponent("switch\(step)-\(frame)\(suffix).png"))
            }
            await task.value
            try? await Task.sleep(for: .milliseconds(400))
        }
        await model.selectConversation(nil)
        try? await Task.sleep(for: .milliseconds(500))
        model.selectNewConversationMode(.agent)
        for frame in 0..<4 {
            try? await Task.sleep(for: .milliseconds(70))
            capture(folder.appendingPathComponent("mode-agent-\(frame)\(suffix).png"))
        }
        // The context ring sits in the gray strip in Agent (a model must be chosen).
        let previousModel = model.selectedModelID
        model.selectedModelID = "mlx-community/Qwen3-8B-4bit"
        try? await Task.sleep(for: .milliseconds(600))
        capture(folder.appendingPathComponent("mode-agent-gauge\(suffix).png"))
        model.selectNewConversationMode(.chat)
        model.selectedModelID = "mlx-community/Qwen3-8B-4bit"
        try? await Task.sleep(for: .milliseconds(600))
        capture(folder.appendingPathComponent("mode-chat-gauge\(suffix).png"))
        model.selectedModelID = previousModel
    }

    /// A web-research answer recorded with its timeline: reasoning, searches, pages read,
    /// intermediate text, then the final answer; folded, then unfolded with a group open.
    static func timeline(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        let conversation = Conversation(title: "Nouveautés GPT-6 Luna", mode: .chat, provider: .openAI, modelID: "gpt-6-sol")
        let start = Date.now.addingTimeInterval(-90)
        let intermediate = "Je vérifie les annonces officielles avant de répondre.\n\n"
        let final = "**GPT-6 Luna** est le modèle compact d'OpenAI. L'API Decisions, en bêta publique, l'utilise pour renvoyer des choix typés avec une probabilité, facturés 0,10 $ par million de tokens d'entrée [1][2]. Jev de TypeSafe vise le même usage [3].\n\nPour un usage quotidien, tu en verras surtout les effets dans des applications plus rapides."
        let answerID = UUID()
        var builder = TurnTimelineBuilder(startedAt: start)
        builder.reasoning("**Identifier les sources fiables**\n\nLa question porte sur une annonce récente : je cherche la documentation officielle puis des articles indépendants.", at: start)
        builder.text(intermediate, at: start.addingTimeInterval(6))
        let queries = ["OpenAI Decisions API gpt-6-luna", "gpt-6-luna pricing", "Decisions API public beta", "OpenAI Luna decisions launch", "Decisions API structured choices", "Luna decisions latency", "OpenRouter gpt-6-luna-decisions"]
        var actions: [ConversationAction] = []
        for (index, query) in queries.enumerated() {
            let id = "web:search\(index)"
            builder.action("search\(index)", at: start.addingTimeInterval(Double(8 + index * 3)))
            actions.append(.init(id: id, conversationID: conversation.id, turnID: answerID, ordinal: index, name: "web_search", state: .completed,
                startedAt: start.addingTimeInterval(Double(8 + index * 3)), finishedAt: start.addingTimeInterval(Double(10 + index * 3)),
                input: query, output: "3 results · developers.openai.com, openrouter.ai, infoq.com"))
        }
        builder.reasoning("Les chiffres de prix concordent entre la documentation et OpenRouter.", at: start.addingTimeInterval(40))
        builder.text(final, at: start.addingTimeInterval(48))
        builder.finish(at: start.addingTimeInterval(72))
        do {
            try await model.conversationRepository.save(conversation)
            try await model.conversationRepository.append(ConversationMessage(conversationID: conversation.id, role: .user,
                content: "Que peux-tu me dire sur GPT-6 Luna Decisions ?", sequence: 0, createdAt: start))
            try await model.conversationRepository.append(ConversationMessage(id: answerID, conversationID: conversation.id, role: .assistant,
                content: intermediate + final, sequence: 1, createdAt: start.addingTimeInterval(1), actions: actions,
                sources: [ConversationSource(url: "https://developers.openai.com/api/docs/guides/decisions", title: "Decisions — OpenAI API", references: [1]),
                          ConversationSource(url: "https://openrouter.ai/openai/gpt-6-luna-decisions", title: "GPT-6 Luna Decisions — API pricing & providers", references: [2]),
                          ConversationSource(url: "https://www.infoq.com/news/2026/10/typesafe-ai-jev-released/", title: "TypeSafe AI releases Jev, a decision-only model", references: [3])].compactMap { $0 },
                timeline: builder.timeline))
        } catch { return }
        model.conversations.insert(conversation, at: 0)
        await model.selectConversation(conversation.id)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("timeline-folded\(suffix).png"))
        model.debugExpandTurns = true
        try? await Task.sleep(for: .milliseconds(900))
        capture(folder.appendingPathComponent("timeline-unfolded\(suffix).png"))
        model.debugExpandTurns = false
        model.requestedWorkbench = .init(kind: .sources, messageID: answerID, focusID: "https://openrouter.ai/openai/gpt-6-luna-decisions")
        try? await Task.sleep(for: .seconds(4))
        capture(folder.appendingPathComponent("workbench-sources\(suffix).png"))
        model.requestedWorkbench = .init(kind: .actions, focusID: "web:search1", actions: actions)
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("workbench-actions\(suffix).png"))
        // Two sub-agents: one still working, one finished, with their journals.
        let running = UUID(), finished = UUID(), execution = UUID(), now = Date.now
        func entry(_ child: UUID, _ kind: SubagentJournalEntry.Kind, _ text: String? = nil, call: String? = nil, name: String? = nil, _ seconds: Double) -> SubagentJournalEntry {
            .init(childID: child, kind: kind, text: text, callID: call, name: name, isError: kind == .toolFinished ? false : nil, at: now.addingTimeInterval(seconds - 120))
        }
        model.debugSubagents = [
            SubagentSnapshot(id: finished, executionID: execution, title: "Runtime completion", prompt: "Trace the tool-less Agent path to persistence and report where empty routes appear.",
                provider: "openai", modelID: "gpt-6-sol", effort: "high", state: .accepted, result: "Empty routes come from the compaction client built with zero tools; fixed by passing the explicit empty catalog.",
                createdAt: now.addingTimeInterval(-120), entries: [
                    entry(finished, .reasoning, "**Following the run** I start from the runtime entry point and follow the persistence path.", 2),
                    entry(finished, .toolStarted, "{\"path\":\"Sources/AIMAgentRuntime/ProviderTurnRunner.swift\"}", call: "r1", name: "read_file", 4),
                    entry(finished, .toolFinished, "1 320 lines", call: "r1", 5),
                    entry(finished, .toolStarted, "{\"query\":\"compaction\"}", call: "r2", name: "search_files", 6),
                    entry(finished, .toolFinished, "4 matches", call: "r2", 7),
                    entry(finished, .noteToParent, "The summary client is built with zero tools.", call: "n1", 9),
                    entry(finished, .parentMessage, "Check the active summaries as well.", 12),
                    entry(finished, .toolStarted, "{\"path\":\"Sources/AIMAgentRuntime/SessionCompactionService.swift\"}", call: "r3", name: "read_file", 14),
                    entry(finished, .toolFinished, "210 lines", call: "r3", 15),
                    entry(finished, .text, "Active summaries use the same client; both paths now pass an explicit empty catalog.", 20)],
                costUSD: 0.0184, tokens: 41_200),
            SubagentSnapshot(id: running, executionID: execution, title: "Remote completion", prompt: "Prepare the explicit activation for user trials in Remote.",
                provider: "anthropic", modelID: "claude-haiku-5-5", effort: "low", state: .running, result: nil,
                createdAt: now.addingTimeInterval(-70), entries: [
                    entry(running, .toolStarted, "{\"query\":\"activation\"}", call: "s1", name: "search_files", 60)],
                costUSD: nil, tokens: nil)]
        model.requestedWorkbench = .init(kind: .subagents)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("workbench-subagents\(suffix).png"))
        model.requestedWorkbench = .init(kind: .subagents, focusID: finished.uuidString)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("workbench-subagent-detail\(suffix).png"))
        model.debugSubagents = nil
        // An Agent run interrupted before any action: its state sits after the last turn, never above.
        let agent = Conversation(title: "Recherche sur les modèles de décision", mode: .agent, provider: .openRouter, modelID: "anthropic/claude-sonnet-5.5")
        do {
            try await model.conversationRepository.save(agent)
            try await model.conversationRepository.append(ConversationMessage(conversationID: agent.id, role: .user,
                content: "Déploie deux sous-agents : l'un sur les modèles de décision comme Jev, l'autre sur ce que la communauté a construit avec. Puis fais-moi un compte rendu.", sequence: 0))
        } catch { return }
        var interrupted = AgentExecution(commandID: UUID(), conversationID: agent.id, request: Data())
        interrupted.state = .waitingUser
        interrupted.reason = "Interrupted before any action. Nothing was changed."
        model.conversations.insert(agent, at: 0)
        model.selectNewConversationMode(.agent)
        await model.selectConversation(agent.id)
        model.continuityExecutions = [interrupted]
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("agent-interrupted\(suffix).png"))
        var spending = interrupted
        spending.reason = "Paused before sending: a sub-agent's request does not fit under your spending limit."
        model.continuityExecutions = [spending]
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("decision-spending\(suffix).png"))
        var stoppedChild = interrupted
        stoppedChild.reason = "A sub-agent stopped and needs your review before the task continues."
        let blockedID = UUID()
        model.debugSubagents = [
            SubagentSnapshot(id: blockedID, executionID: stoppedChild.id, title: "Recherche : modèles IA basés sur la décision (JEV)", prompt: "Research decision models.",
                provider: "openrouter", modelID: "anthropic/claude-haiku-5.5", effort: "low", state: .blocked,
                result: "The child returned no JSON object matching the approved result_keys.", createdAt: .now.addingTimeInterval(-60), entries: [], costUSD: nil, tokens: nil),
            SubagentSnapshot(id: UUID(), executionID: stoppedChild.id, title: "Recherche : réalisations communautaires avec JEV", prompt: "Research community projects.",
                provider: "openrouter", modelID: "anthropic/claude-haiku-5.5", effort: "low", state: .paused,
                result: "Paused before sending by the spending limit. The global spending limit has no room for this attempt.", createdAt: .now.addingTimeInterval(-60), entries: [], costUSD: nil, tokens: nil)]
        model.continuityExecutions = [stoppedChild]
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("decision-subagent\(suffix).png"))
        model.requestedWorkbench = .init(kind: .subagents)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("workbench-subagents-attention\(suffix).png"))
        model.debugSubagents = nil
        model.continuityExecutions = []
        // Codex-style permission cards in place of the composer (shown while the run is active), then a question.
        var active = AgentExecution(commandID: UUID(), conversationID: agent.id, request: Data())
        active.state = .running
        model.continuityExecutions = [active]
        let subagent = ToolRequest(name: "delegate_task", arguments: ["title": "Decision models like Jev", "prompt": "Research decision-only models.",
            "model": "anthropic/claude-haiku-5.5", "effort": "low"], risk: .delegation)
        model.pendingToolApprovals = [PendingToolApproval(id: UUID(), sessionID: agent.id, toolName: subagent.name, arguments: subagent.arguments,
            workspacePath: "/Users/example/Research", risk: .delegation, allowsSessionDecision: false, review: nil, priorUncertainAction: false,
            category: ToolApprovalCategory.of(subagent), allowsStandingDecision: true)]
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("approval-subagent\(suffix).png"))
        let command = ToolRequest(name: "run_command", arguments: ["command": "curl -sL https://api.github.com/search/repositories?q=jev -o repos.json"], risk: .destructive)
        model.pendingToolApprovals = [PendingToolApproval(id: UUID(), sessionID: agent.id, toolName: command.name, arguments: command.arguments,
            workspacePath: "/Users/example/Research", risk: .destructive, allowsSessionDecision: false, review: nil, priorUncertainAction: false,
            category: ToolApprovalCategory.of(command), allowsStandingDecision: true,
            safetyNote: "Downloads from the internet (curl). No safety judge is available, so AIM asks you.")]
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("approval-safety-check\(suffix).png"))
        model.pendingToolApprovals = []
        model.continuityExecutions = []
        model.pendingAgentQuestions = [AgentQuestion(id: "gallery-question", conversationID: agent.id, items: [
            AgentQuestionItem(question: "Which format do you want for the report?", options: ["A short summary (one page)", "A detailed report with sources", "A comparison table"])])]
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("agent-question\(suffix).png"))
        model.pendingAgentQuestions = []
    }

    static func chat(model: AppModel, folder: URL, suffix: String, capture: (URL) -> Void) async {
        let conversation = Conversation(title: "Comment fonctionne la quantisation", mode: .chat, provider: .local, modelID: "mlx-community/Qwen3-8B-4bit")
        do {
            try await model.conversationRepository.save(conversation)
            try await model.conversationRepository.append(ConversationMessage(conversationID: conversation.id, role: .user,
                content: "dit moi comment fonctionne la quantisation d'intelligence artificiel", sequence: 0))
            let answer = ConversationMessage(conversationID: conversation.id, role: .assistant, content: listAnswer, sequence: 1)
            try await model.conversationRepository.append(answer)
            try await model.metricsRepository.save(TurnMetrics(provider: "local", modelID: "mlx-community/Qwen3-8B-4bit", mode: "chat",
                startedAt: .now, usage: TokenUsage(inputTokens: 412, cachedInputTokens: 0, outputTokens: 214, processedPromptTokens: 412,
                promptSeconds: 0.61, generationSeconds: 7.9, engine: "mlx"), firstTokenSeconds: 0.68, streamSeconds: 7.95,
                totalSeconds: 8.7, characters: listAnswer.count), messageID: answer.id, conversationID: conversation.id)
        } catch { return }
        model.conversations.insert(conversation, at: 0)
        await model.selectConversation(conversation.id)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(folder.appendingPathComponent("chat-list\(suffix).png"))
        var appearance = model.settings.conversationAppearance ?? .init()
        appearance = ConversationAppearance(typeface: appearance.typeface == .lora ? .system : .lora, textSize: appearance.textSize)
        model.settings.conversationAppearance = appearance
        try? await Task.sleep(for: .milliseconds(1_000))
        capture(folder.appendingPathComponent("chat-list-other-font\(suffix).png"))
        model.settings.conversationAppearance = nil
        model.debugShowsMetrics = true
        try? await Task.sleep(for: .milliseconds(900))
        capture(folder.appendingPathComponent("chat-metrics\(suffix).png"))
        model.debugShowsMetrics = false
        // The context popover, folded then unfolded.
        var usage = ContextUsage(parts: [.messages: 18_400, .systemPrompt: 1_300, .systemTools: 5_200, .mcpTools: 3_100,
                                         .skills: 900, .memory: 400, .projectContext: 1_200], limit: 32_768)
        usage.reportedTotal = 31_000
        usage.autoCompactAt = 29_000
        model.contextUsage = usage
        model.debugOpenMenu = "context"
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("chat-context\(suffix).png"))
        model.debugOpenMenu = nil
        try? await Task.sleep(for: .milliseconds(400))
        model.debugOpenMenu = "context-expanded"
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(folder.appendingPathComponent("chat-context-expanded\(suffix).png"))
        model.debugOpenMenu = nil
        try? await Task.sleep(for: .milliseconds(400))
        model.debugOpenMenu = "effort"
        try? await Task.sleep(for: .milliseconds(900))
        capture(folder.appendingPathComponent("chat-effort\(suffix).png"))
        model.debugOpenMenu = nil
    }
}
#endif
