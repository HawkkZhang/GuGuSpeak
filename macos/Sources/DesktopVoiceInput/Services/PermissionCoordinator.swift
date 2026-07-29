import ApplicationServices
import AVFoundation
import Combine
import Foundation

@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var speechRecognition: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined

    private var didRequestAccessibilityPrompt = false

    func refreshAll(promptForSystemDialogs: Bool) async {
        microphone = await refreshMicrophone(prompt: promptForSystemDialogs)
        speechRecognition = .authorized
        accessibility = refreshAccessibility(prompt: promptForSystemDialogs)
    }

    func state(for permission: AppPermissionKind) -> PermissionState {
        switch permission {
        case .microphone:
            microphone
        case .speechRecognition:
            speechRecognition
        case .accessibility:
            accessibility
        }
    }

    func missingPermissions(for mode: RecognitionMode) -> [AppPermissionKind] {
        [.microphone, .accessibility].filter { !state(for: $0).isUsable }
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
            }
        }
    }

    func allRequiredForCaptureReady() -> Bool {
        microphone.isUsable && accessibility.isUsable
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
        if AXIsProcessTrusted() {
            return .authorized
        }

        guard prompt else {
            return didRequestAccessibilityPrompt ? .denied : .notDetermined
        }
        _ = requestAccessibilityPromptIfNeeded()
        return accessibility
    }

    @discardableResult
    func requestAccessibilityPromptIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            accessibility = .authorized
            return false
        }

        guard !didRequestAccessibilityPrompt else {
            accessibility = .denied
            return false
        }

        didRequestAccessibilityPrompt = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
        return true
    }
}
