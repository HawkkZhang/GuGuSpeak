import AppKit
import SwiftUI

struct PermissionGuideView: View {
    @ObservedObject var appModel: VoiceInputAppModel
    let compact: Bool

    private let primaryText = DVITheme.ink
    private let secondaryText = DVITheme.secondaryInk
    private let steel = DVITheme.tertiaryInk
    private let ready = DVITheme.ready
    private let caution = DVITheme.caution

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 14) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    DVITheme.controlShape()
                        .fill(appModel.hasMissingPermissions ? DVITheme.stateFill(caution, emphasized: true) : DVITheme.accent)
                    Image(systemName: appModel.hasMissingPermissions ? "hand.raised.fill" : "checkmark")
                        .font(.system(size: compact ? 16 : 18, weight: .semibold))
                        .foregroundStyle(appModel.hasMissingPermissions ? caution : DVITheme.selectedInk)
                }
                .frame(width: compact ? 34 : 38, height: compact ? 34 : 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appModel.hasMissingPermissions ? "还差几项权限才能正常工作" : "权限已经准备好了")
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(appModel.hasMissingPermissions
                         ? "补齐缺失项后即可使用语音输入。"
                         : "现在可以使用快捷键开始输入。")
                        .font(.system(size: compact ? 12 : 13))
                        .foregroundStyle(secondaryText)
                }
            }

            if appModel.hasMissingPermissions {
                ForEach(missingPermissions) { permission in
                    permissionRow(permission)
                }

                // 刷新按钮
                HStack {
                    Spacer()
                    Button {
                        Task {
                            await appModel.refreshPermissionStatus()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("刷新检查")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(DVITheme.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(compact ? 12 : 14)
        .background(DVITheme.panel, in: DVITheme.panelShape())
        .overlay(
            DVITheme.panelShape()
                .stroke(DVITheme.separator.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: DVITheme.overlayShadow.opacity(compact ? 0 : 0.05), radius: 12, x: 0, y: 5)
    }

    private var missingPermissions: [AppPermissionKind] {
        appModel.missingPermissions
    }

    private func permissionRow(_ permission: AppPermissionKind) -> some View {
        let state = appModel.permissionCoordinator.state(for: permission)

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.system(size: compact ? 13 : 14, weight: .medium))
                        .foregroundStyle(primaryText)
                    Text(state.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(steel)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DVITheme.stateFill(state.isUsable ? ready : caution), in: DVITheme.controlShape())
                }

                Text(permission.guidance)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !state.isUsable {
                Button(appModel.actionLabel(for: permission)) {
                    appModel.handlePermissionAction(permission)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DVITheme.selectedInk)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(DVITheme.accent, in: DVITheme.controlShape())
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }
}
