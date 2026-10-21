import Foundation

/// Deliberate allowlist: never serialize the repository's routing/workspace metadata.
public struct ConversationExport: Sendable {
    public enum Format: String, CaseIterable, Sendable { case text, json }
    public let title: String
    private let mode: AIMMode
    private let messages: [ConversationMessage]

    public init(conversation: Conversation, messages: [ConversationMessage]) throws {
        guard messages.allSatisfy({ $0.conversationID == conversation.id }),
              Set(messages.map(\.sequence)).count == messages.count else { throw ExportError.invalidHistory }
        title = conversation.title
        mode = conversation.mode
        self.messages = messages.filter { $0.role == .user || $0.role == .assistant }.sorted { $0.sequence < $1.sequence }
    }

    public func data(format: Format, includeAttachments: Bool = false, includeImages: Bool = false) throws -> Data {
        guard !includeImages || format == .json else { throw ExportError.imagesRequireJSON }
        let records = messages.map { message in
            Record(role: message.role.rawValue, text: message.content, createdAt: message.createdAt,
                   completionStatus: message.completionStatus?.rawValue,
                   attachments: includeAttachments ? (message.attachments ?? []).map { Attachment(name: $0.name, text: $0.content) } : nil,
                   images: includeImages ? (message.images ?? []).map { Image(name: $0.name, mimeType: $0.mimeType, dataBase64: $0.data.base64EncodedString()) } : nil)
        }
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(Document(schemaVersion: records.contains(where: { $0.completionStatus != nil }) ? 3 : (includeImages ? 2 : 1), title: title, mode: mode.rawValue,
                                               attachmentsIncluded: includeAttachments, imagesIncluded: includeImages, messages: records))
        case .text:
            var sections = [title, "Mode: \(mode.rawValue)\nText attachments: \(includeAttachments ? "included as snapshots" : "excluded")\nImages: excluded"]
            for record in records {
                var section = "\(record.role.uppercased()) — \(record.createdAt.ISO8601Format())"
                if let completionStatus = record.completionStatus { section += " — \(completionStatus.uppercased()) (incomplete)" }
                section += "\n\n\(record.text)"
                for attachment in record.attachments ?? [] {
                    section += "\n\n[Attachment: \(attachment.name)]\n\(attachment.text)\n[End attachment]"
                }
                sections.append(section)
            }
            data = Data((sections.joined(separator: "\n\n────────\n\n") + "\n").utf8)
        }
        guard data.count <= 20 * 1_024 * 1_024 else { throw ExportError.tooLarge }
        return data
    }

    private struct Document: Encodable {
        let schemaVersion: Int
        let title: String
        let mode: String
        let attachmentsIncluded: Bool
        let imagesIncluded: Bool
        let messages: [Record]
    }
    private struct Record: Encodable {
        let role: String
        let text: String
        let createdAt: Date
        let completionStatus: String?
        let attachments: [Attachment]?
        let images: [Image]?
    }
    private struct Attachment: Encodable { let name: String; let text: String }
    private struct Image: Encodable { let name: String; let mimeType: String; let dataBase64: String }
}

public enum ExportError: LocalizedError {
    case invalidHistory, tooLarge, unavailable, imagesRequireJSON
    public var errorDescription: String? {
        switch self {
        case .invalidHistory: "This conversation could not be exported because its message history is inconsistent."
        case .tooLarge: "The export exceeds 20 MB. Try excluding attachments or images."
        case .unavailable: "Finish the current response and save it before exporting."
        case .imagesRequireJSON: "Image data can only be included in a JSON export."
        }
    }
}
