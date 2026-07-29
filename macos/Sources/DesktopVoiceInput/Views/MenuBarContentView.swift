import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var appModel: VoiceInputAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            brandHeader
            statusCard

            VStack(alignment: .leading, spacing: 7) {
                Text("识别模式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DVITheme.tertiaryInk)

                DVIChoiceBar(
                    options: RecognitionMode.userSelectableModes,
                    selection: $appModel.settings.preferredMode,
                    label: { $0.title },
                    compact: true
                )
            }

            if appModel.hasMissingPermissions {
                permissionNotice
            }

            actionBar
        }
        .padding(14)
        .frame(width: 306)
        .background(
            DVITheme.panel
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(DVITheme.accentSoft.opacity(0.72))
                        .frame(width: 92, height: 92)
                        .offset(x: 32, y: -44)
                }
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            DVIAppIcon(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("GuGuTalk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DVITheme.ink)
                Text("轻量语音输入")
                    .font(.system(size: 11))
                    .foregroundStyle(DVITheme.secondaryInk)
            }

            Spacer()
        }
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                DVITheme.controlShape()
                    .fill(statusTint.opacity(0.14))
                Image(systemName: appModel.previewState.isRecording ? "waveform" : "mic")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DVITheme.ink)

                Text(hotkeyDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(DVITheme.secondaryInk)
                    .lineLimit(1)
            }

            Spacer()

            Text(appModel.settings.preferredMode.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DVITheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DVITheme.accentSoft, in: DVITheme.controlShape())
        }
        .padding(10)
        .background(DVITheme.elevatedPanel, in: DVITheme.panelShape())
        .overlay(DVITheme.panelShape().stroke(DVITheme.separator.opacity(0.22), lineWidth: 1))
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DVITheme.caution)
            Text("缺少 \(appModel.missingPermissions.count) 项权限")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DVITheme.caution)
            Spacer()
            Button("处理") { openSettingsWindow(to: .permissions) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DVITheme.selectedInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DVITheme.caution, in: DVITheme.controlShape())
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DVITheme.stateFill(DVITheme.caution, emphasized: true), in: DVITheme.controlShape())
        .overlay(DVITheme.controlShape().stroke(DVITheme.stateStroke(DVITheme.caution), lineWidth: 1))
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { openSettingsWindow(to: .general) } label: {
                Text("打开设置")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DVITheme.selectedInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(DVITheme.accent, in: DVITheme.controlShape())
            }
            .buttonStyle(.plain)

            Button { appModel.quit() } label: {
                Text("退出")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DVITheme.secondaryInk)
                    .frame(width: 64)
                    .padding(.vertical, 8)
                    .background(DVITheme.control, in: DVITheme.controlShape())
                    .overlay(DVITheme.controlShape().stroke(DVITheme.separator.opacity(0.26), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusTitle: String {
        if appModel.previewState.isRecording {
            return "正在听写"
        }
        if appModel.hasMissingPermissions {
            return "需要处理权限"
        }
        return "准备就绪"
    }

    private var statusTint: Color {
        if appModel.previewState.isRecording {
            return DVITheme.ready
        }
        if appModel.hasMissingPermissions {
            return DVITheme.caution
        }
        return DVITheme.ready
    }

    private var hotkeyDescription: String {
        if appModel.settings.holdToTalkEnabled {
            return appModel.settings.holdToTalkHotkey.displayName + " 按住说话"
        }
        if appModel.settings.toggleToTalkEnabled {
            return appModel.settings.toggleToTalkHotkey.displayName + " 切换"
        }
        return "未设置快捷键"
    }

    private func openSettingsWindow(to tab: SettingsTab) {
        appModel.showSettingsWindow(tab: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            appModel.bringSettingsWindowForward()
        }
    }
}
