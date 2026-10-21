import AIMApplication
import AIMCore
import Foundation

public enum VideoAttachmentImporter {
    public static func read(_ url: URL, maximumFrames: Int = 64,
                            mode: PreparedVideoAttachment.Mode = .automatic,
                            range: ClosedRange<Double>? = nil,
                            originDeviceID: String = "mac", originDeviceName: String = "Mac") async throws -> (TextAttachment, [ImageAttachment]) {
        let video = try await VideoPreparationService.prepare(url, mode: mode, range: range,
            originDeviceID: originDeviceID, originDeviceName: originDeviceName)
        return (TextAttachment(id: video.id, name: video.name, content: video.context, video: video), [])
    }
}
