import Foundation

public struct ConversationAttention: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case response, approval, failure
        public var priority: Int { self == .failure ? 3 : self == .approval ? 2 : 1 }
    }
    public struct Entry: Codable, Equatable, Sendable {
        public var conversation: UUID
        public var version: String
        public var kind: Kind
        public init(conversation: UUID, version: String, kind: Kind) { self.conversation = conversation; self.version = version; self.kind = kind }
    }
    public private(set) var entries: [Entry] = []
    public private(set) var acknowledged: Set<String> = []
    public init() {}
    public var count: Int { Set(entries.map(\.conversation)).count }
    public var priority: Kind? { entries.map(\.kind).max { $0.priority < $1.priority } }
    public mutating func record(_ value: Entry) {
        guard !acknowledged.contains(value.version), !entries.contains(value) else { return }
        entries.removeAll { $0.conversation == value.conversation && $0.kind == value.kind }
        entries.append(value)
    }
    public mutating func consult(_ conversation: UUID) {
        for value in entries where value.conversation == conversation && value.kind != .approval { acknowledged.insert(value.version) }
        entries.removeAll { $0.conversation == conversation && $0.kind != .approval }
    }
    public mutating func acknowledgeResponse(_ conversation: UUID) {
        for value in entries where value.conversation == conversation && value.kind == .response { acknowledged.insert(value.version) }
        entries.removeAll { $0.conversation == conversation && $0.kind == .response }
    }
    public mutating func resolveApproval(_ conversation: UUID) {
        for value in entries where value.conversation == conversation && value.kind == .approval { acknowledged.insert(value.version) }
        entries.removeAll { $0.conversation == conversation && $0.kind == .approval }
    }
}
