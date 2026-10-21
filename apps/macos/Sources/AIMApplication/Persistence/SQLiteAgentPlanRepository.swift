import Foundation
import GRDB

public actor SQLiteAgentPlanRepository: AgentPlanRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func load(conversationID: UUID) throws -> AgentPlan? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT stepsJSON, updatedAt FROM agentPlans WHERE conversationID = ?",
                                             arguments: [conversationID.uuidString]) else { return nil }
            let steps = try JSONDecoder().decode([AgentPlanStep].self, from: row["stepsJSON"] as Data)
            return AgentPlan(conversationID: conversationID, steps: steps, updatedAt: row["updatedAt"] as Date)
        }
    }

    public func save(_ plan: AgentPlan) throws {
        let steps = try JSONEncoder().encode(plan.steps)
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO agentPlans(conversationID, stepsJSON, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(conversationID) DO UPDATE SET stepsJSON = excluded.stepsJSON, updatedAt = excluded.updatedAt
                """, arguments: [plan.conversationID.uuidString, steps, plan.updatedAt])
        }
    }
}
