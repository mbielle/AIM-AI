import Foundation

/// Keeps editing separate from stored data until the user explicitly saves.
public struct ProjectDraft: Sendable {
    public let projectID: UUID?
    public var name: String
    public var instructions: String
    private let savedName: String
    private let savedInstructions: String

    public init(project: AIMProject? = nil) {
        projectID = project?.id
        name = project?.name ?? ""
        instructions = project?.instructions ?? ""
        savedName = name; savedInstructions = instructions
    }
    public var isDirty: Bool { name != savedName || instructions != savedInstructions }
    public var isValid: Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 120 && instructions.count <= 16_000
    }
}
