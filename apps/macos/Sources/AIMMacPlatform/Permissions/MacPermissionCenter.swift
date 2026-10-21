import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Speech

public enum MacPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case screenRecording
    case microphone
    case speechRecognition
    case camera

    public var id: String { rawValue }
}

public enum MacPermissionState: String, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
}

public protocol MacPermissionChecking: Sendable {
    func state(for kind: MacPermissionKind) async -> MacPermissionState
    func request(_ kind: MacPermissionKind) async -> MacPermissionState
}

/// Synthetic adapter: unit tests never query Speech/AV/AX or prompt the user.
public struct UnavailableMacPermissions: MacPermissionChecking {
    public init() {}
    public func state(for kind: MacPermissionKind) async -> MacPermissionState { .notDetermined }
    public func request(_ kind: MacPermissionKind) async -> MacPermissionState { .denied }
}

public actor MacPermissionCenter: MacPermissionChecking {
    public init() {}

    public func state(for kind: MacPermissionKind) -> MacPermissionState {
        switch kind {
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            Self.map(SFSpeechRecognizer.authorizationStatus())
        case .camera:
            Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    @discardableResult
    public func request(_ kind: MacPermissionKind) async -> MacPermissionState {
        switch kind {
        case .accessibility:
            // Using the documented raw key avoids importing the C global as
            // mutable shared state under Swift 6 strict concurrency.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .speechRecognition:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: Self.map(status))
                }
            }
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> MacPermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> MacPermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}
