import Foundation
import ImageIO

public struct ImageAttachment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: Data
    public let videoSourceID: UUID?

    public init(id: UUID = UUID(), name: String, mimeType: String, data: Data, videoSourceID: UUID? = nil) throws {
        self.videoSourceID = videoSourceID
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        try Self.validate([self])
    }

    public static func read(_ url: URL) throws -> ImageAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ImageAttachmentError.invalidImage }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let isHEIF = ["heic", "heif"].contains(url.pathExtension.lowercased())
        let data = try file.read(upToCount: isHEIF ? 20_000_001 : 6_000_001) ?? Data()
        if isHEIF { return try normalizedHEIF(data, originalName: url.lastPathComponent) }
        let mimeType: String
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { mimeType = "image/png" }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { mimeType = "image/jpeg" }
        else { throw ImageAttachmentError.invalidImage }
        return try ImageAttachment(name: url.lastPathComponent, mimeType: mimeType, data: data)
    }

    /// A provider can return a valid large JPEG after charging for generation.
    /// Re-encode only when needed so it fits the local attachment format rather
    /// than discarding the result solely because its byte size crossed 6 MB.
    public static func generatedJPEG(_ data: Data) throws -> ImageAttachment {
        guard !data.isEmpty, data.count <= 15_000_000, data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_000, height <= 8_000,
              Int64(width) * Int64(height) <= 40_000_000 else { throw ImageAttachmentError.invalidImage }
        if data.count <= 6_000_000 {
            return try ImageAttachment(name: "Generated image.jpg", mimeType: "image/jpeg", data: data)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageAttachmentError.invalidImage
        }
        for quality in [0.86, 0.72, 0.58, 0.42] {
            let compressed = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(compressed, "public.jpeg" as CFString, 1, nil) else {
                throw ImageAttachmentError.invalidImage
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageAttachmentError.invalidImage }
            if compressed.length <= 6_000_000 {
                return try ImageAttachment(name: "Generated image.jpg", mimeType: "image/jpeg", data: compressed as Data)
            }
        }
        throw ImageAttachmentError.limit
    }

    /// Providers do not consistently accept HEIF. Decode it on the Mac, apply
    /// orientation, and encode a fresh JPEG without carrying source metadata.
    private static func normalizedHEIF(_ data: Data, originalName: String) throws -> ImageAttachment {
        guard !data.isEmpty, data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.heic", "public.heif"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_000, height <= 8_000,
              Int64(width) * Int64(height) <= 40_000_000 else { throw ImageAttachmentError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageAttachmentError.invalidImage
        }
        let name = (originalName as NSString).deletingPathExtension + ".jpg"
        for quality in [0.82, 0.68, 0.52, 0.36] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
                throw ImageAttachmentError.invalidImage
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageAttachmentError.invalidImage }
            if encoded.length <= 6_000_000 {
                return try ImageAttachment(name: name, mimeType: "image/jpeg", data: encoded as Data)
            }
        }
        throw ImageAttachmentError.limit
    }

    public static func validate(_ images: [ImageAttachment]) throws {
        guard images.count <= 256, Set(images.map { $0.videoSourceID ?? $0.id }).count <= 10, Set(images.map(\.id)).count == images.count,
              images.reduce(0, { $0 + $1.data.count }) <= 24_000_000 else { throw ImageAttachmentError.limit }
        for image in images {
            guard !image.name.isEmpty, image.name.count <= 255, !image.data.isEmpty, image.data.count <= 6_000_000,
                  (image.mimeType == "image/png" && image.data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) ||
                  (image.mimeType == "image/jpeg" && image.data.starts(with: [0xff, 0xd8, 0xff])),
                  let source = CGImageSourceCreateWithData(image.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8_000, height <= 8_000,
                  Int64(width) * Int64(height) <= 40_000_000 else { throw ImageAttachmentError.invalidImage }
        }
    }

    public var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

public enum ImageAttachmentError: LocalizedError {
    case invalidImage, limit, unsupportedProvider
    public var errorDescription: String? {
        switch self {
        case .invalidImage: "Choose a valid image up to 40 megapixels. PNG/JPEG must be at most 6 MB; HEIC/HEIF must be at most 20 MB and is converted locally to JPEG."
        case .limit: "Attach up to 4 images, 6 MB each and 12 MB total per message."
        case .unsupportedProvider: "This provider does not support image input in AIM yet. Choose a vision-capable model from another provider."
        }
    }
}
