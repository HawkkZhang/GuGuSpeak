import Foundation

enum AppPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            "麦克风"
        case .speechRecognition:
            "语音识别"
        case .accessibility:
            "辅助功能"
        }
    }

    var guidance: String {
        switch self {
        case .microphone:
            "采集说话声音。未授权时无法录音。"
        case .speechRecognition:
            "历史 Apple Speech 本地识别权限。当前流式本地模式不再需要。"
        case .accessibility:
            "把识别结果写回当前输入框。未授权时只能预览。"
        }
    }

    var settingsURLStrings: [String] {
        switch self {
        case .microphone:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ]
        case .speechRecognition:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            ]
        case .accessibility:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?PrivacyAccessibilityServicesType"
            ]
        }
    }

    var fallbackSettingsURLStrings: [String] {
        [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
    }

    var canPromptInApp: Bool {
        switch self {
        case .microphone, .accessibility:
            true
        case .speechRecognition:
            false
        }
    }
}
