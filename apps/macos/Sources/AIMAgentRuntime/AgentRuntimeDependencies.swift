import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform

/// One composition path for interactive, scheduled and remote runs.
package struct AgentRuntimeDependencies: Sendable {
    let conversations: any ConversationRepository
    let missions: any AgentMissionRepository
    let runs: any WorkspaceRunRepository
    let secureStore: any SecureStoring
    let memory: (any MemoryRepository)?
    let settings: (any SettingsRepository)?
    let plans: (any AgentPlanRepository)?
    let ledger: any GlobalSpendLedger
    let cuaQualifications: (any CuaQualificationRepository)?
    let mcpServers: (any MCPServerRepository)?
    let projects: (any ProjectRepository)?
    let documents: SQLiteProjectDocumentRepository?
    let sourceIndex: SQLiteProjectSourceIndex?
    let activity: (any ActivityRepository)?
    let compaction: (any SessionCompactionRepository)?
    let jobs: (any SubagentJobRepository)?
    let workspaces: (any SubagentWorkspaceRepository)?
    let scheduler: SQLiteSchedulerRepository?

    package init(conversations: any ConversationRepository, missions: any AgentMissionRepository,
                 runs: any WorkspaceRunRepository, secureStore: any SecureStoring,
                 memory: (any MemoryRepository)?, settings: (any SettingsRepository)?,
                 plans: (any AgentPlanRepository)?, ledger: any GlobalSpendLedger,
                 cuaQualifications: (any CuaQualificationRepository)?, mcpServers: (any MCPServerRepository)?,
                 projects: (any ProjectRepository)? = nil, documents: SQLiteProjectDocumentRepository? = nil,
                 sourceIndex: SQLiteProjectSourceIndex? = nil, activity: (any ActivityRepository)? = nil,
                 compaction: (any SessionCompactionRepository)? = nil, jobs: (any SubagentJobRepository)? = nil,
                 workspaces: (any SubagentWorkspaceRepository)? = nil, scheduler: SQLiteSchedulerRepository? = nil) {
        self.conversations = conversations; self.missions = missions; self.runs = runs
        self.secureStore = secureStore; self.memory = memory; self.settings = settings
        self.plans = plans; self.ledger = ledger; self.cuaQualifications = cuaQualifications
        self.mcpServers = mcpServers; self.projects = projects; self.documents = documents
        self.sourceIndex = sourceIndex; self.activity = activity; self.compaction = compaction
        self.jobs = jobs; self.workspaces = workspaces; self.scheduler = scheduler
    }

    package func runner(approvals: ToolApprovalBroker = ToolApprovalBroker(),
                        questions: AgentQuestionBroker = AgentQuestionBroker(),
                        meter: BillableRequestMeter? = nil, executionContext: RuntimeExecutionContext? = nil,
                        subagentRegistry: DurableSubagentRegistry? = nil, processRegistry: DurableProcessRegistry? = nil) -> ProviderTurnRunner {
        ProviderTurnRunner(repository: conversations, secureStore: secureStore, approvals: approvals,
            runRepository: runs, projectRepository: projects, projectDocuments: documents,
            projectSourceIndex: sourceIndex, memoryRepository: memory, activityRepository: activity,
            settingsRepository: settings, compactionRepository: compaction, questionBroker: questions,
            planRepository: plans, missionRepository: missions, subagentJobRepository: jobs,
            spendMeter: meter ?? BillableRequestMeter(ledger: ledger),
            cuaQualificationRepository: cuaQualifications, mcpServerRepository: mcpServers,
            schedulerRepository: scheduler, subagentWorkspaceRepository: workspaces, executionContext: executionContext,
            subagentRegistry: subagentRegistry, processRegistry: processRegistry)
    }
}

package typealias ScheduledRunDependencies = AgentRuntimeDependencies
