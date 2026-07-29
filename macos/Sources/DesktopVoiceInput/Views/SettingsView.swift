import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appModel: VoiceInputAppModel
    @State private var selectedTab: SettingsTab = .general
    @State private var holdHotkeyFeedback: HotkeyValidationIssue?
    @State private var toggleHotkeyFeedback: HotkeyValidationIssue?
    @State private var personalTerm: String = ""
    @State private var isDoubaoConfigExpanded = false
    @State private var isQwenConfigExpanded = false
    @State private var isAddingCustomMode = false
    @State private var newModeName: String = ""
    @State private var newModePrompt: String = ""
    @FocusState private var isPersonalTermFocused: Bool
    @Namespace private var sidebarAnimation

    private let ready = DVITheme.ready
    private let caution = DVITheme.caution

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(DVITheme.separator.opacity(0.20))
                .frame(width: 1)
                .ignoresSafeArea()
            contentArea
        }
        .background(settingsBackground)
        .foregroundStyle(DVITheme.ink)
        .tint(DVITheme.accent)
        .environment(\.controlActiveState, .active)
        .onAppear {
            selectedTab = appModel.requestedSettingsTab
            bringSettingsWindowForward()
            // 检测是否已配置，如果未配置则自动展开
            isDoubaoConfigExpanded = appModel.settings.doubaoAppID.isEmpty || appModel.settings.doubaoAccessKey.isEmpty
            isQwenConfigExpanded = appModel.settings.qwenAPIKey.isEmpty
        }
        .onChange(of: appModel.requestedSettingsTab) { tab in
            withAnimation(.easeOut(duration: 0.2)) {
                selectedTab = tab
            }
            bringSettingsWindowForward()
        }
        .onChange(of: appModel.settingsFocusRequest) { _ in
            bringSettingsWindowForward()
        }
    }

    private var settingsBackground: some View {
        ZStack {
            DVITheme.window
            LinearGradient(
                colors: [
                    DVITheme.accentSoft.opacity(0.36),
                    Color.clear,
                    DVITheme.brandWarm.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DVIAppIcon(size: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("GuGuTalk")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DVITheme.ink)
                        .lineLimit(1)
                    Text("语音输入")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DVITheme.secondaryInk)
                        .lineLimit(1)
                }
            }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    sidebarItem(tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .frame(width: 186)
        .background(DVITheme.sidebar)
    }

    private func sidebarItem(_ tab: SettingsTab) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 13, weight: selectedTab == tab ? .medium : .regular))

                Spacer()

                if tab == .permissions, appModel.hasMissingPermissions {
                    DVITheme.statusMarkShape()
                        .fill(caution)
                        .frame(width: 5, height: 12)
                }
            }
            .foregroundStyle(selectedTab == tab ? DVITheme.selectedInk : DVITheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if selectedTab == tab {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DVITheme.accent)
                        .matchedGeometryEffect(id: "sidebar_highlight", in: sidebarAnimation)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader

                switch selectedTab {
                case .general: generalContent
                case .postProcessing: postProcessingContent
                case .permissions: permissionsContent
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selectedTab)
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedTab.heading)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(DVITheme.ink)
            Text(selectedTab.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(DVITheme.secondaryInk)
        }
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeader("语音输入")
            SettingsPanel {
                settingsRow(label: "输入引擎") {
                    DVIChoiceBar(
                        options: RecognitionMode.userSelectableModes,
                        selection: $appModel.settings.preferredMode,
                        label: { $0.title }
                    )
                    .frame(width: 264)
                }

                if appModel.settings.preferredMode != .local || !isCurrentProviderConfigured {
                    Divider()
                    providerStatus(mode: appModel.settings.preferredMode, isConfigured: isCurrentProviderConfigured)
                }

                if appModel.settings.preferredMode == .doubao {
                    Divider()
                    providerConfigDisclosure(title: "豆包服务参数", isExpanded: $isDoubaoConfigExpanded) {
                        VStack(spacing: 12) {
                            providerField(label: "App ID", text: $appModel.settings.doubaoAppID, secure: false)
                            providerField(label: "Access Token", text: $appModel.settings.doubaoAccessKey, secure: true)
                            providerField(label: "Resource ID", text: $appModel.settings.doubaoResourceID, secure: false)
                            providerField(label: "Endpoint", text: $appModel.settings.doubaoEndpoint, secure: false)
                        }
                    }
                }

                if appModel.settings.preferredMode == .qwen {
                    Divider()
                    providerConfigDisclosure(title: "千问服务参数", isExpanded: $isQwenConfigExpanded) {
                        VStack(spacing: 12) {
                            providerField(label: "API Key", text: $appModel.settings.qwenAPIKey, secure: true)
                            providerField(label: "Model", text: $appModel.settings.qwenModel, secure: false)
                            providerField(label: "Endpoint", text: $appModel.settings.qwenEndpoint, secure: false)
                        }
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: appModel.settings.preferredMode)

            SectionHeader("快捷键")
            SettingsPanel {
                hotkeyModeRow(
                    title: "按住说话",
                    description: "适合短句，松开后插入",
                    hotkey: $appModel.settings.holdToTalkHotkey,
                    isEnabled: $appModel.settings.holdToTalkEnabled,
                    feedback: $holdHotkeyFeedback,
                    slot: .holdToTalk,
                    otherHotkey: appModel.settings.toggleToTalkHotkey
                )

                Divider()

                hotkeyModeRow(
                    title: "点按说话",
                    description: "适合长句，再按一次结束",
                    hotkey: $appModel.settings.toggleToTalkHotkey,
                    isEnabled: $appModel.settings.toggleToTalkEnabled,
                    feedback: $toggleHotkeyFeedback,
                    slot: .toggleToTalk,
                    otherHotkey: appModel.settings.holdToTalkHotkey
                )
            }

            SectionHeader("外观")
            SettingsPanel {
                settingsRow(label: "主题") {
                    DVIChoiceBar(
                        options: AppearancePreference.allCases,
                        selection: $appModel.settings.appearancePreference,
                        label: { $0.title }
                    )
                    .frame(width: 264)
                }
            }
        }
    }

    // MARK: - Post Processing

    private var postProcessingContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("标点处理")
            SettingsPanel {
                DVIChoiceBar(
                    options: PunctuationMode.allCases,
                    selection: $appModel.settings.punctuationMode,
                    label: { $0.title }
                )
            }

            SectionHeader("个性词")
            SettingsPanel {
                HStack(spacing: 8) {
                    TextField("输入正确写法", text: $personalTerm)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .focused($isPersonalTermFocused)
                        .background(DVITheme.controlElevated, in: DVITheme.controlShape())
                        .overlay(
                            DVITheme.controlShape()
                                .stroke(
                                    isPersonalTermFocused ? DVITheme.accent : DVITheme.separator.opacity(0.28),
                                    lineWidth: isPersonalTermFocused ? 1.5 : 1
                                )
                                .allowsHitTesting(false)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded { isPersonalTermFocused = true }
                        )
                        .onSubmit(addPersonalTerm)
                    Button(action: addPersonalTerm) {
                        Text("添加")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DVITheme.selectedInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(DVITheme.accent, in: DVITheme.controlShape())
                    }
                    .buttonStyle(.plain)
                    .disabled(personalTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !appModel.hotwordStore.terms.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appModel.hotwordStore.terms) { term in
                            HStack(spacing: 8) {
                                Text(term.text)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button { appModel.hotwordStore.removeTerm(id: term.id) } label: {
                                    Image(systemName: "trash").font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DVITheme.tertiaryInk)
                                .help("删除个性词")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            SectionHeader("智能后处理")
            SettingsPanel {
                HStack {
                    Text("启用智能后处理")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DVITheme.ink)
                    Spacer()
                    DVISwitch(isOn: $appModel.settings.postProcessingEnabled)
                }

                if appModel.settings.postProcessingEnabled {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("处理模式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DVITheme.secondaryInk)
                        DVIChoiceBar(options: PostProcessingPreset.allCases, selection: Binding(
                            get: { appModel.settings.postProcessingPreset ?? .removeFillers },
                            set: {
                                appModel.settings.postProcessingPreset = $0
                                appModel.settings.selectedCustomModeName = nil
                            }
                        ), label: { $0.title })
                    }

                    // 自定义模式列表
                    if !appModel.settings.customModes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("自定义")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DVITheme.secondaryInk)

                            ForEach(appModel.settings.customModes) { mode in
                                HStack(spacing: 8) {
                                    Button {
                                        appModel.settings.selectedCustomModeName = mode.name
                                        appModel.settings.postProcessingPreset = nil
                                    } label: {
                                        Text(mode.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(appModel.settings.selectedCustomModeName == mode.name ? DVITheme.selectedInk : DVITheme.ink)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                appModel.settings.selectedCustomModeName == mode.name
                                                    ? DVITheme.accent
                                                    : DVITheme.control,
                                                in: DVITheme.controlShape()
                                            )
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    Button {
                                        appModel.settings.removeCustomMode(name: mode.name)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10))
                                            .foregroundStyle(DVITheme.tertiaryInk)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // 选中自定义模式时显示 prompt 编辑
                    if let customName = appModel.settings.selectedCustomModeName,
                       let mode = appModel.settings.customModes.first(where: { $0.name == customName }) {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Prompt")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DVITheme.secondaryInk)
                            TextEditor(text: Binding(
                                get: { mode.prompt },
                                set: { appModel.settings.updateCustomMode(name: customName, prompt: $0) }
                            ))
                            .font(.system(size: 12))
                            .frame(height: 72)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(DVITheme.controlElevated, in: DVITheme.controlShape())
                            .overlay(
                                DVITheme.controlShape()
                                    .stroke(DVITheme.separator.opacity(0.3), lineWidth: 1)
                                    .allowsHitTesting(false)
                            )
                        }
                    }

                    // 添加自定义模式
                    Divider()
                    if isAddingCustomMode {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("模式名称", text: $newModeName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(DVITheme.controlElevated, in: DVITheme.controlShape())
                                .overlay(
                                    DVITheme.controlShape()
                                        .stroke(DVITheme.separator.opacity(0.28), lineWidth: 1)
                                        .allowsHitTesting(false)
                                )
                            TextEditor(text: $newModePrompt)
                                .font(.system(size: 12))
                                .frame(height: 60)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(DVITheme.controlElevated, in: DVITheme.controlShape())
                                .overlay(
                                    DVITheme.controlShape()
                                        .stroke(DVITheme.separator.opacity(0.3), lineWidth: 1)
                                        .allowsHitTesting(false)
                                )
                            HStack {
                                Button {
                                    let name = newModeName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let prompt = newModePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !name.isEmpty, !prompt.isEmpty else { return }
                                    appModel.settings.addCustomMode(name: name, prompt: prompt)
                                    appModel.settings.selectedCustomModeName = name
                                    appModel.settings.postProcessingPreset = nil
                                    newModeName = ""
                                    newModePrompt = ""
                                    isAddingCustomMode = false
                                } label: {
                                    Text("添加")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(DVITheme.selectedInk)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(DVITheme.accent, in: DVITheme.controlShape())
                                }
                                .buttonStyle(.plain)
                                .disabled(newModeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newModePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button {
                                    newModeName = ""
                                    newModePrompt = ""
                                    isAddingCustomMode = false
                                } label: {
                                    Text("取消")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(DVITheme.secondaryInk)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(DVITheme.control, in: DVITheme.controlShape())
                                        .overlay(DVITheme.controlShape().stroke(DVITheme.separator.opacity(0.26), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        Button {
                            isAddingCustomMode = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 12))
                                Text("添加自定义模式")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(DVITheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: appModel.settings.postProcessingEnabled)
            .animation(.easeOut(duration: 0.2), value: appModel.settings.postProcessingPreset)

            if appModel.settings.postProcessingEnabled {
                SectionHeader("LLM 服务")
                SettingsPanel {
                    llmConfigStatus
                    settingsRow(label: "协议") {
                        DVIChoiceBar(
                            options: LLMProtocolType.allCases,
                            selection: $appModel.settings.llmProtocolType,
                            label: { $0.title }
                        )
                        .frame(width: 200)
                    }
                    providerField(label: "Endpoint", text: $appModel.settings.llmEndpoint, secure: false)
                    providerField(label: "API Key", text: $appModel.settings.llmAPIKey, secure: true)
                    providerField(label: "Model", text: $appModel.settings.llmModel, secure: false)
                    Text(appModel.settings.llmProtocolType.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DVITheme.tertiaryInk)
                }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            PermissionGuideView(appModel: appModel, compact: false)
        }
    }

    // MARK: - Helpers

    private func addPersonalTerm() {
        let value = personalTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        appModel.hotwordStore.addTerm(value)
        personalTerm = ""
    }

    private var isCurrentProviderConfigured: Bool {
        switch appModel.settings.preferredMode {
        case .local:
            return true
        case .doubao:
            return appModel.settings.recognitionConfig.doubaoCredentials.isConfigured
        case .qwen:
            return appModel.settings.recognitionConfig.qwenCredentials.isConfigured
        case .auto:
            return true
        }
    }

    private var llmConfigStatus: some View {
        let ok = appModel.settings.llmProviderConfig.isConfigured
        return HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ok ? ready : caution)
            Text(ok ? "服务已配置" : "需要配置服务")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ok ? DVITheme.secondaryInk : caution)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DVITheme.stateFill(ok ? ready : caution), in: DVITheme.controlShape())
        .overlay(DVITheme.controlShape().stroke(DVITheme.stateStroke(ok ? ready : caution), lineWidth: 1))
    }

    private func providerConfigDisclosure<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.20)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DVITheme.accentStrong)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DVITheme.ink)
                    Spacer()
                    Text(isExpanded.wrappedValue ? "收起" : "配置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DVITheme.accentStrong)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DVITheme.accentSoft.opacity(0.70), in: DVITheme.controlShape())
                .overlay(DVITheme.controlShape().stroke(DVITheme.accent.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func hotkeyModeRow(
        title: String,
        description: String,
        hotkey: Binding<HotkeyConfiguration>,
        isEnabled: Binding<Bool>,
        feedback: Binding<HotkeyValidationIssue?>,
        slot: HotkeySlot,
        otherHotkey: HotkeyConfiguration
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DVITheme.ink)
                        .lineLimit(1)

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(DVITheme.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                DVISwitch(isOn: isEnabled)

                HotkeyRecorderButton(
                    appModel: appModel,
                    hotkey: hotkey,
                    feedback: feedback,
                    validation: { appModel.settings.validationIssue(for: slot, candidate: $0) },
                    accent: DVITheme.accent
                )
                .disabled(!isEnabled.wrappedValue)
                .opacity(isEnabled.wrappedValue ? 1 : 0.48)
            }

            VStack(alignment: .leading, spacing: 8) {
                // 实时显示冲突和警告
                let conflictInfo = hotkey.wrappedValue.conflictInfo(comparing: otherHotkey)
                if conflictInfo.severity != .none {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: conflictInfo.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(conflictInfo.severity == .error ? DVITheme.caution : DVITheme.accent)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 4) {
                            if let title = conflictInfo.title {
                                Text(title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(conflictInfo.severity == .error ? DVITheme.caution : DVITheme.accent)
                            }
                            ForEach(conflictInfo.details, id: \.self) { detail in
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(DVITheme.secondaryInk)
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        DVITheme.stateFill(conflictInfo.severity == .error ? DVITheme.caution : DVITheme.accent),
                        in: DVITheme.controlShape()
                    )
                    .overlay(DVITheme.controlShape().stroke(DVITheme.stateStroke(conflictInfo.severity == .error ? DVITheme.caution : DVITheme.accent), lineWidth: 1))
                }

                if let issue = feedback.wrappedValue {
                    HStack(spacing: 6) {
                        Image(systemName: issue.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(issue.severity == .error ? DVITheme.caution : DVITheme.accent)
                        Text(issue.message)
                            .font(.system(size: 10))
                            .foregroundStyle(DVITheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(
                        DVITheme.stateFill(issue.severity == .error ? DVITheme.caution : DVITheme.accent),
                        in: DVITheme.controlShape()
                    )
                    .overlay(DVITheme.controlShape().stroke(DVITheme.stateStroke(issue.severity == .error ? DVITheme.caution : DVITheme.accent), lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func providerField(label: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(DVITheme.secondaryInk)
            Group { if secure { SecureField(label, text: text) } else { TextField(label, text: text) } }
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(DVITheme.controlElevated, in: DVITheme.controlShape())
                .overlay(
                    DVITheme.controlShape()
                        .stroke(DVITheme.separator.opacity(0.28), lineWidth: 1)
                        .allowsHitTesting(false)
                )
        }
    }

    private func settingsRow<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DVITheme.ink)
            Spacer(minLength: 20)
            content()
        }
        .padding(.vertical, 2)
    }

    private func providerStatus(mode: RecognitionMode, isConfigured: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isConfigured ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isConfigured ? ready : caution)
            Text(providerStatusText(mode: mode, isConfigured: isConfigured))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isConfigured ? DVITheme.secondaryInk : caution)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DVITheme.stateFill(isConfigured ? ready : caution), in: DVITheme.controlShape())
        .overlay(DVITheme.controlShape().stroke(DVITheme.stateStroke(isConfigured ? ready : caution), lineWidth: 1))
    }

    private func providerStatusText(mode: RecognitionMode, isConfigured: Bool) -> String {
        switch mode {
        case .local:
            return "本地流式中英模型"
        case .doubao:
            return isConfigured ? "豆包参数已就绪" : "需要填写豆包参数"
        case .qwen:
            return isConfigured ? "千问参数已就绪" : "需要填写千问 API Key"
        case .auto:
            return "自动选择可用引擎"
        }
    }

    private func permissionRow(permission: AppPermissionKind, state: PermissionState) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: state.isUsable ? "checkmark" : "exclamationmark.triangle.fill").foregroundStyle(state.isUsable ? ready : caution).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .medium))
                if !state.isUsable { Text(permission.guidance).font(.system(size: 12)).foregroundStyle(DVITheme.secondaryInk).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            if state.isUsable {
                Text(state.title).font(.system(size: 12, weight: .medium)).foregroundStyle(DVITheme.secondaryInk)
            } else {
                Button(appModel.actionLabel(for: permission)) {
                    appModel.handlePermissionAction(permission)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DVITheme.selectedInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(DVITheme.accent, in: DVITheme.controlShape())
            }
        }.padding(.vertical, 4)
    }

    private func bringSettingsWindowForward() {
        activateSettingsWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { activateSettingsWindow() }
    }

    private func activateSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) { window.makeKeyAndOrderFront(nil); window.orderFrontRegardless() }
    }
}

// MARK: - Types

enum SettingsTab: CaseIterable {
    case general, postProcessing, permissions
    var title: String {
        switch self { case .general: "输入"; case .postProcessing: "整理"; case .permissions: "权限" }
    }
    var heading: String {
        switch self {
        case .general: "输入"
        case .postProcessing: "文本整理"
        case .permissions: "权限"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "选择识别引擎，设置开始说话的方式。"
        case .postProcessing: "让最终上屏的文字更干净。"
        case .permissions: "补齐录音、快捷键和文本插入所需权限。"
        }
    }
    var icon: String {
        switch self { case .general: "slider.horizontal.3"; case .postProcessing: "wand.and.stars"; case .permissions: "lock.shield" }
    }
}

// MARK: - Components

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 7) {
            DVITheme.statusMarkShape()
                .fill(DVITheme.accent)
                .frame(width: 5, height: 14)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DVITheme.secondaryInk)
        }
        .padding(.bottom, -6)
    }
}

private struct SettingsPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DVITheme.panel, in: DVITheme.panelShape())
            .overlay(DVITheme.panelShape().stroke(DVITheme.separator.opacity(0.22), lineWidth: 1))
            .shadow(color: DVITheme.overlayShadow.opacity(0.06), radius: 12, x: 0, y: 5)
    }
}

private struct HotkeyRecorderButton: View {
    let appModel: VoiceInputAppModel
    @Binding var hotkey: HotkeyConfiguration
    @Binding var feedback: HotkeyValidationIssue?
    let validation: (HotkeyConfiguration) -> HotkeyValidationIssue?
    let accent: Color
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var liveKeyCode: UInt16? = nil
    @State private var shakeOffset: CGFloat = 0
    @State private var isRejected = false
    @State private var capturedHotkey: HotkeyConfiguration?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    LiveHotkeyDisplay(modifiers: liveModifiers, keyCode: liveKeyCode, accent: accent, isRejected: isRejected)
                } else {
                    HotkeyDisplay(hotkey: hotkey)
                    Spacer(minLength: 6)
                    Text("更改")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DVITheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: 180)
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .background(isRecording ? DVITheme.stateFill(accent, emphasized: true) : DVITheme.controlElevated, in: DVITheme.controlShape())
        .overlay(DVITheme.controlShape().stroke(isRecording ? DVITheme.stateStroke(accent, emphasized: true) : DVITheme.separator.opacity(0.30), lineWidth: 1))
        .offset(x: shakeOffset)
        .animation(.easeOut(duration: 0.16), value: isRecording)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        feedback = nil
        isRejected = false
        liveModifiers = []
        liveKeyCode = nil
        capturedHotkey = nil
        isRecording = true
        appModel.suspendHotkeys()
        NSApp.activate(ignoringOtherApps: true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }

                liveKeyCode = event.keyCode
                liveModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

                // 捕获快捷键
                if let captured = HotkeyConfiguration.capture(from: event) {
                    if let issue = validation(captured), issue.severity == .error {
                        // 被拒绝的按键：显示红色 + 抖动 + 蜂鸣音
                        isRejected = true
                        capturedHotkey = nil
                        triggerShake()
                        NSSound.beep()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isRejected = false
                            liveKeyCode = nil
                            liveModifiers = []
                        }
                        return nil
                    }

                    // 保存捕获的快捷键，等待释放
                    capturedHotkey = captured
                }
                return nil

            } else if event.type == .keyUp {
                // 主键释放
                if event.keyCode == liveKeyCode {
                    liveKeyCode = nil

                    // 如果修饰键也都释放了，保存快捷键
                    if liveModifiers.isEmpty, let captured = capturedHotkey {
                        hotkey = captured
                        feedback = validation(captured)
                        stopRecording()
                    }
                }
                return nil

            } else if event.type == .flagsChanged {
                let newModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

                // 修饰键释放
                if newModifiers.isEmpty {
                    liveModifiers = []

                    // 如果主键也释放了，保存快捷键
                    if liveKeyCode == nil, let captured = capturedHotkey {
                        hotkey = captured
                        feedback = validation(captured)
                        stopRecording()
                    }
                } else {
                    liveModifiers = newModifiers

                    // 捕获修饰键作为单键
                    if let captured = HotkeyConfiguration.capture(from: event) {
                        if let issue = validation(captured), issue.severity == .error {
                            isRejected = true
                            capturedHotkey = nil
                            triggerShake()
                            NSSound.beep()

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                isRejected = false
                                liveKeyCode = nil
                                liveModifiers = []
                            }
                            return nil
                        }

                        // 立即保存捕获的修饰键，等待释放
                        capturedHotkey = captured
                    }
                }
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        isRejected = false
        liveModifiers = []
        liveKeyCode = nil
        capturedHotkey = nil
        appModel.resumeHotkeys()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func triggerShake() {
        withAnimation(.easeOut(duration: 0.08)) {
            shakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.08)) {
                shakeOffset = -10
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.08)) {
                shakeOffset = 5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.10)) {
                shakeOffset = 0
            }
        }
    }
}

private struct HotkeyDisplay: View {
    let hotkey: HotkeyConfiguration

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(hotkey.keyComponents.enumerated()), id: \.offset) { index, key in
                KeyCapView(label: key, isActive: false)
                if index < hotkey.keyComponents.count - 1 {
                    Text("+")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DVITheme.tertiaryInk)
                }
            }
        }
    }
}

private struct LiveHotkeyDisplay: View {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: UInt16?
    let accent: Color
    let isRejected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if modifiers.contains(.control) {
                KeyCapView(label: "⌃", isActive: true, accent: isRejected ? DVITheme.danger : accent)
                Text("+").font(.system(size: 10, weight: .medium)).foregroundStyle(isRejected ? DVITheme.danger : accent)
            }
            if modifiers.contains(.option) {
                KeyCapView(label: "⌥", isActive: true, accent: isRejected ? DVITheme.danger : accent)
                Text("+").font(.system(size: 10, weight: .medium)).foregroundStyle(isRejected ? DVITheme.danger : accent)
            }
            if modifiers.contains(.shift) {
                KeyCapView(label: "⇧", isActive: true, accent: isRejected ? DVITheme.danger : accent)
                Text("+").font(.system(size: 10, weight: .medium)).foregroundStyle(isRejected ? DVITheme.danger : accent)
            }
            if modifiers.contains(.command) {
                KeyCapView(label: "⌘", isActive: true, accent: isRejected ? DVITheme.danger : accent)
                Text("+").font(.system(size: 10, weight: .medium)).foregroundStyle(isRejected ? DVITheme.danger : accent)
            }
            if modifiers.contains(.function) {
                KeyCapView(label: "fn", isActive: true, accent: isRejected ? DVITheme.danger : accent)
                if keyCode != nil {
                    Text("+").font(.system(size: 10, weight: .medium)).foregroundStyle(isRejected ? DVITheme.danger : accent)
                }
            }

            if let keyCode {
                let keyName = HotkeyFormatter.displayName(forKeyCode: keyCode, modifiers: [])
                KeyCapView(label: keyName, isActive: true, accent: isRejected ? DVITheme.danger : accent)
            } else if modifiers.isEmpty {
                Text("按下按键...")
                    .font(.system(size: 11))
                    .foregroundStyle(DVITheme.secondaryInk)
            }
        }
    }
}

private struct KeyCapView: View {
    let label: String
    var isActive: Bool = false
    var accent: Color = .accentColor

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isActive ? accent : DVITheme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                isActive
                    ? accent.opacity(0.12)
                    : DVITheme.controlElevated
            )
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        isActive
                            ? accent.opacity(0.4)
                            : DVITheme.separator.opacity(0.3),
                        lineWidth: 1
                    )
            )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity; var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0
        for s in subviews { let sz = s.sizeThatFits(.unspecified); if x + sz.width > w, x > 0 { x = 0; y += h + spacing; h = 0 }; x += sz.width + spacing; h = max(h, sz.height) }
        return CGSize(width: w, height: y + h)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, h: CGFloat = 0
        for s in subviews { let sz = s.sizeThatFits(.unspecified); if x + sz.width > b.maxX, x > b.minX { x = b.minX; y += h + spacing; h = 0 }; s.place(at: CGPoint(x: x, y: y), proposal: .unspecified); x += sz.width + spacing; h = max(h, sz.height) }
    }
}
