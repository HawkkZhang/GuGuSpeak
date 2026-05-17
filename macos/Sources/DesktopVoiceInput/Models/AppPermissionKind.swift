import Foundation

enum AppPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            "麦克风"
        case .speechRecognition:
            "语音识别"
        case .accessibility:
            "辅助功能"
        case .inputMonitoring:
            "输入监控"
        }
    }

    var guidance: String {
        switch self {
        case .microphone:
            "采集说话声音。未授权时无法录音。"
        case .speechRecognition:
            "用于本地语音转文字。本地模式还需要在系统键盘设置里启用听写。"
        case .accessibility:
            "把识别结果写回当前输入框。未授权时只能预览。"
        case .inputMonitoring:
            "监听全局快捷键。未授权时快捷键可能不生效。"
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
        case .inputMonitoring:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
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
        case .microphone, .speechRecognition, .inputMonitoring:
            true
        case .accessibility:
            false
        }
    }
}
