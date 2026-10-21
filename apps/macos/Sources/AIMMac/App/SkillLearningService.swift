import AIMApplication
import AIMAgentRuntime
import AIMCore
import Foundation

/// One billable review request with the conversation's own model and key.
struct SkillLearningService: Sendable {
    let secureStore: any SecureStoring
    let meter: BillableRequestMeter

    func review(provider: ChatProvider, modelID: String, message: ConversationMessage) async throws -> SkillLearning.Proposal? {
        guard provider.supportsWorkspaceTools else { return nil }
        let key: String
        if provider == .chatgpt {
            key = try await RuntimeProviderCredentials.reader(provider: provider, store: secureStore)()
        } else {
            guard let data = try secureStore.readData(forKey: provider.rawValue),
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
            key = value
        }
        let conversation = try ProviderToolConversation(provider: provider, modelID: modelID, messages: [message],
            apiKey: key, tools: [SkillLearning.tool], meter: meter, billingFeature: "skill-learning")
        return SkillLearning.proposal(from: try await conversation.next(outputs: []))
    }

    /// Reviews the conversation's latest Agent run; the level decides whether the
    /// single resulting skill is applied (versioned) or left as a proposal.
    func learn(from conversation: Conversation, messages: [ConversationMessage], run: WorkspaceRunHistory,
               level: SkillLearningLevel, global: URL? = SkillCatalog.globalDirectory)
        async throws -> (proposal: SkillLearning.Proposal, outcome: SkillLearningOutcome)? {
        guard level != .off else { return nil }
        guard let provider = conversation.provider, let modelID = conversation.modelID, !modelID.isEmpty,
              let digest = SkillLearning.digest(messages: messages, run: run) else { return nil }
        let skills = SkillCatalog.discover(workspace: conversation.workspacePath, global: global)
        let viewed = SkillLearning.viewedSkills(run)
        var bodies: [String: String] = [:]
        for skill in skills where viewed.contains(skill.name) && skill.source == .global {
            bodies[skill.name] = try? SkillCatalog.readFile(skill, relativePath: "SKILL.md")
        }
        let message = SkillLearning.reviewMessage(digest: digest, skills: skills, viewedBodies: bodies,
                                                  conversationID: conversation.id)
        guard let proposal = try await review(provider: provider, modelID: modelID, message: message),
              // A project's own skill of that name would shadow an AIM-folder version.
              !skills.contains(where: { $0.name == proposal.name && $0.source == .workspace }) else { return nil }
        let outcome = try SkillLearning.commit(name: proposal.name, description: proposal.description,
                                               instructions: proposal.instructions, level: level, global: global)
        return (proposal, outcome)
    }
}
