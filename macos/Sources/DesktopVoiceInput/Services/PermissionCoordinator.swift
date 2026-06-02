import ApplicationServices
import AVFoundation
import Combine
import Foundation

@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var speechRecognition: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined
    @Published private(set) var inputMonitoring: PermissionState = .notDetermined

    func refreshAll(promptForSystemDialogs: Bool) async {
        microphone = await refreshMicrophone(prompt: promptForSystemDialogs)
        speechRecognition = .authorized
        accessibility = refreshAccessibility(prompt: promptForSystemDialogs)
        inputMonitoring = refreshInputMonitoring(prompt: promptForSystemDialogs)
    }

    func state(for permission: AppPermissionKind) -> PermissionState {
        switch permission {
        case .microphone:
            microphone
        case .speechRecognition:
            speechRecognition
        case .accessibility:
            accessibility
        case .inputMonitoring:
            inputMonitoring
        }
    }

    func missingPermissions(for mode: RecognitionMode) -> [AppPermissionKind] {
        [.microphone, .accessibility, .inputMonitoring].filter { !state(for: $0).isUsable }
    }

    func requestMissingPermissions(for mode: RecognitionMode) async {
        for permission in missingPermissions(for: mode) {
            switch permission {
            case .microphone:
                microphone = await refreshMicrophone(prompt: true)
            case .speechRecognition:
                speechRecognition = .authorized
            case .accessibility:
                accessibility = refreshAccessibility(prompt: true)
            case .inputMonitoring:
                inputMonitoring = refreshInputMonitoring(prompt: true)
            }
        }
    }

    func allRequiredForCaptureReady() -> Bool {
        microphone.isUsable && accessibility.isUsable && inputMonitoring.isUsable
    }

    func refreshMicrophone(prompt: Bool) async -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            guard prompt else { return .notDetermined }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .authorized : .denied
        @unknown default:
            return .unsupported
        }
    }

    func refreshSpeechRecognition(prompt: Bool) async -> PermissionState {
        .authorized
    }

    func refreshAccessibility(prompt: Bool) -> PermissionState {
        let trusted = AXIsProcessTrusted()

        if !trusted && prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        return trusted ? .authorized : .denied
    }

    func refreshInputMonitoring(prompt: Bool) -> PermissionState {
        let hasAccess = CGPreflightListenEventAccess()

        if !hasAccess && prompt {
            let granted = CGRequestListenEventAccess()
            return granted ? .authorized : .denied
        }

        return hasAccess ? .authorized : .denied
    }
}
