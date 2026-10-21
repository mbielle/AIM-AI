import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CapturedWindowImage: Sendable {
    public let png: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let windowFrame: CGRect
    public let capturedAt: Date
}

public actor MacScreenCaptureService {
    public init() {}

    public func capture(windowID: CGWindowID, maximumWidth: Int = 1_920) async throws -> Data {
        try await captureWithGeometry(windowID: windowID, maximumWidth: maximumWidth).png
    }

    public func captureWithGeometry(windowID: CGWindowID, maximumWidth: Int = 1_920) async throws -> CapturedWindowImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(1, CGFloat(maximumWidth) / max(window.frame.width, 1))
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let capturedAt = Date.now
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encodingFailed
        }
        return CapturedWindowImage(png: data, pixelWidth: image.width,
            pixelHeight: image.height, windowFrame: window.frame, capturedAt: capturedAt)
    }
}

public enum ScreenCaptureError: LocalizedError {
    case permissionRequired
    case windowNotFound
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .permissionRequired: "Screen Recording permission is required."
        case .windowNotFound: "The selected window is no longer available."
        case .encodingFailed: "The window image could not be encoded."
        }
    }
}
