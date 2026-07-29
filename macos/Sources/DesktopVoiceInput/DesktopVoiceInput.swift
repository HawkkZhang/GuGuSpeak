import AppKit
import SwiftUI

@main
struct DesktopVoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = VoiceInputAppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appModel: appModel)
                .preferredColorScheme(appModel.settings.appearancePreference.colorScheme)
                .id(appModel.appearanceRevision)
                .onAppear {
                    AppDelegate.shared?.registerAppModel(appModel)
                }
        } label: {
            MenuBarLabel(appModel: appModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏标签 - 使用 onAppear 来注册 appModel
private struct MenuBarLabel: View {
    let appModel: VoiceInputAppModel

    var body: some View {
        Group {
            if let icon = Self.bundleIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "waveform")
            }
        }
            .accessibilityLabel("GuGuTalk")
            .onAppear {
                AppDelegate.shared?.registerAppModel(appModel)
            }
    }

    private static let bundleIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon")?.copy() as? NSImage else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
