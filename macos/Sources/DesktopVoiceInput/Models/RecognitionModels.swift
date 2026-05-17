import AppKit
import AVFoundation
import Foundation

enum RecognitionMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case local
    case doubao
    case qwen

    static let userSelectableModes: [RecognitionMode] = [.local, .doubao, .qwen]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            "自动"
        case .local:
            "本地"
        case .doubao:
            "豆包"
        case .qwen:
            "千问"
        }
    }
}

enum EndpointingPolicy: String, Codable, Sendable {
    case voiceActivityDetection
    case manual
}

struct DoubaoCredentials: Sendable {
    let appID: String
    let accessKey: String
    let resourceID: String
    let endpoint: String

    var isConfigured: Bool {
        !appID.isEmpty && !accessKey.isEmpty && !resourceID.isEmpty && !endpoint.isEmpty
    }
}

struct QwenCredentials: Sendable {
    let apiKey: String
    let model: String
    let endpoint: String

    var isConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty && !endpoint.isEmpty
    }
}

struct RecognitionConfig: Sendable {
    let languageCode: String
    let sampleRate: Double
    let mode: RecognitionMode
    let partialResultsEnabled: Bool
    let endpointing: EndpointingPolicy
    let doubaoCredentials: DoubaoCredentials
    let qwenCredentials: QwenCredentials
}

struct HotkeyConfiguration: Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let displayName: String
}

struct AudioChunk: @unchecked Sendable {
    let pcmData: Data
    let sampleRate: Double
    let channels: Int
    let audioLevel: Float
    let nativeBuffer: AVAudioPCMBuffer
}

struct ProviderSelection: Sendable {
    let mode: RecognitionMode
    let provider: SpeechProvider
}

struct InsertionResult: Sendable {
    enum Method: String, Sendable {
        case accessibility
        case simulatedKeyboard
        case clipboardPaste
        case failed
    }

    let method: Method
    let targetAppName: String?
    let succeeded: Bool
    let failureReason: String?
}

struct ProviderSwitchInfo: Sendable {
    let from: RecognitionMode
    let to: RecognitionMode
    let reason: String
}

struct SessionFailureInfo: LocalizedError, Sendable {
    let message: String
    let isNoSpeech: Bool

    var errorDescription: String? { message }

    init(message: String, isNoSpeech: Bool = false) {
        self.message = message
        self.isNoSpeech = isNoSpeech
    }
}

enum TranscriptEvent: Sendable {
    case sessionStarted(mode: RecognitionMode)
    case audioLevelUpdated(Float)
    case partialTextUpdated(text: String, revision: Int)
    case finalTextReady(text: String)
    case providerSwitched(ProviderSwitchInfo)
    case sessionFailed(SessionFailureInfo)
    case sessionEnded
}
