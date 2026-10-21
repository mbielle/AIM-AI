import AIMCore
import Foundation

/// Provider-specific image parts. Text-only messages retain their existing wire shape.
enum ImageMessageEncoding {
    static func prepare(_ messages: [ConversationMessage], provider: ChatProvider, maxPayloadBytes: Int64 = 24_000_000) throws -> [ConversationMessage] {
        let hasImages = messages.contains { !($0.images ?? []).isEmpty }
        guard hasImages else { return messages }
        var localOnlyStripped = messages
        for index in localOnlyStripped.indices where localOnlyStripped[index].role == .assistant {
            guard let images = localOnlyStripped[index].images, !images.isEmpty else { continue }
            try ImageAttachment.validate(images)
            localOnlyStripped[index].images = nil
            localOnlyStripped[index].content += "\n\n[AIM note: \(images.count) generated image(s) are saved locally. Attach an image to a new message to send its pixels to this provider.]"
        }
        if provider == .deepSeek {
            guard (localOnlyStripped.last(where: { $0.role == .user })?.images ?? []).isEmpty else {
                throw ImageAttachmentError.unsupportedProvider
            }
            return localOnlyStripped.map { message in
                guard let images = message.images, !images.isEmpty else { return message }
                var textOnly = message
                textOnly.images = nil
                textOnly.content += "\n\n[AIM note: \(images.count) earlier image(s) cannot be sent to DeepSeek. The local conversation still retains them.]"
                return textOnly
            }
        }
        for message in localOnlyStripped {
            guard message.role == .user || (message.images ?? []).isEmpty else { throw ImageAttachmentError.invalidImage }
            try ImageAttachment.validate(message.images ?? [])
        }
        var prepared = localOnlyStripped
        var total = prepared.reduce(Int64(0)) { $0 + Int64(($1.images ?? []).reduce(0) { $0 + $1.data.count }) }
        for index in prepared.indices where total > maxPayloadBytes {
            guard let images = prepared[index].images, !images.isEmpty else { continue }
            total -= Int64(images.reduce(0) { $0 + $1.data.count })
            prepared[index].images = nil
            prepared[index].content += "\n\n[AIM note: \(images.count) earlier image(s) omitted from this request to keep its payload manageable. The local conversation still retains them.]"
        }
        return prepared
    }

    static func responsesContent(_ message: ConversationMessage) -> Any {
        guard let images = message.images, !images.isEmpty else { return message.content }
        let text: [[String: Any]] = message.content.isEmpty ? [] : [["type": "input_text", "text": message.content]]
        return text + images.map { ["type": "input_image", "image_url": $0.dataURL, "detail": "auto"] }
    }

    static func chatCompletionsContent(_ message: ConversationMessage) -> Any {
        guard let images = message.images, !images.isEmpty else { return message.content }
        let text: [[String: Any]] = message.content.isEmpty ? [] : [["type": "text", "text": message.content]]
        return text + images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
    }

    static func anthropicContent(_ message: ConversationMessage) -> Any {
        guard let images = message.images, !images.isEmpty else { return message.content }
        let imageParts: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mimeType, "data": $0.data.base64EncodedString()]]
        }
        return message.content.isEmpty ? imageParts : imageParts + [["type": "text", "text": message.content]]
    }

    static func googleParts(_ message: ConversationMessage) -> [[String: Any]] {
        let imageParts: [[String: Any]] = (message.images ?? []).map {
            ["inline_data": ["mime_type": $0.mimeType, "data": $0.data.base64EncodedString()]]
        }
        return message.content.isEmpty && !imageParts.isEmpty ? imageParts : imageParts + [["text": message.content]]
    }
}
