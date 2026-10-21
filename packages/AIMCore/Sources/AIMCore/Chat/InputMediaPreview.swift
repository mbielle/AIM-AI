import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bounded, metadata-free thumbnail for the public activity journal. Originals
/// and complete prepared images remain in their protected source storage.
public enum InputMediaPreview {
    /// Cheap validation for already prepared thumbnails. Rendering must not
    /// repeatedly decode and recompress an image on the main thread.
    public static func validatedJPEG(_ bytes: Data) -> Data? {
        guard bytes.count <= 262_144,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1280).contains(width), (1...1280).contains(height) else { return nil }
        return bytes
    }
    public static func jpeg(_ bytes: Data, maximumPixels: Int = 960, maximumBytes: Int = 200_000) -> Data? {
        guard bytes.count <= 20_000_000, (1...1280).contains(maximumPixels), (1...262_144).contains(maximumBytes),
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        for quality in [0.72, 0.5, 0.3] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= maximumBytes { return data as Data }
        }
        return nil
    }
}
