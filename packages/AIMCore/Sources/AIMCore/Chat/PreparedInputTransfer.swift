import Foundation

/// Uses the existing encrypted, digest-checked chunk transfer. The original
/// video never leaves the importing device; only bounded prepared evidence does.
public enum PreparedInputTransfer {
    public static let mimeType = "application/vnd.aim.prepared-video+json"
    public static func encode(_ input: NativeChatAttachment) throws -> Data {
        try NativeChatAttachment.validate([input])
        guard input.video != nil else { throw NativeDocumentError.invalidSelection }
        let data = try JSONEncoder().encode(input)
        guard data.count <= RemoteAttachmentRules.maximumSize else { throw NativeDocumentError.limit }
        return data
    }
    public static func decode(_ data: Data) throws -> NativeChatAttachment {
        guard data.count <= RemoteAttachmentRules.maximumSize else { throw NativeDocumentError.limit }
        let input = try JSONDecoder().decode(NativeChatAttachment.self, from: data)
        try NativeChatAttachment.validate([input])
        guard input.video != nil else { throw NativeDocumentError.invalidSelection }
        return input
    }
}
