using System.Windows;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Services;
using GuGuTalk.Core.Settings;
using Hardcodet.Wpf.TaskbarNotification;

namespace GuGuTalk.App.TrayIcon;

public sealed class TrayIconManager : IDisposable
{
    private TaskbarIcon? _trayIcon;
    private readonly AppSettings _settings;
    private readonly RecognitionOrchestrator _orchestrator;
    private readonly Action _openSettings;
    private readonly Action _exitApp;

    public TrayIconManager(
        AppSettings settings,
        RecognitionOrchestrator orchestrator,
        Action openSettings,
        Action exitApp)
    {
        _settings = settings;
        _orchestrator = orchestrator;
        _openSettings = openSettings;
        _exitApp = exitApp;
    }

    public void Initialize()
    {
        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "GuGuTalk - 语音输入",
            MenuActivation = PopupActivationMode.RightClick
        };

        _trayIcon.TrayMouseDoubleClick += (_, _) => _openSettings();

        var contextMenu = new System.Windows.Controls.ContextMenu();

        var statusItem = new System.Windows.Controls.MenuItem { Header = "GuGuTalk 就绪", IsEnabled = false };
        contextMenu.Items.Add(statusItem);
        contextMenu.Items.Add(new System.Windows.Controls.Separator());

        var modeItem = new System.Windows.Controls.MenuItem
        {
            Header = $"识别引擎：{_settings.PreferredMode.Title()}"
        };
        contextMenu.Items.Add(modeItem);

        var hotkeyItem = new System.Windows.Controls.MenuItem
        {
            Header = $"按住说话：{_settings.HoldToTalkHotkey.DisplayName}",
            IsEnabled = false
        };
        contextMenu.Items.Add(hotkeyItem);
        contextMenu.Items.Add(new System.Windows.Controls.Separator());

        var settingsItem = new System.Windows.Controls.MenuItem { Header = "设置..." };
        settingsItem.Click += (_, _) => _openSettings();
        contextMenu.Items.Add(settingsItem);

        var exitItem = new System.Windows.Controls.MenuItem { Header = "退出" };
        exitItem.Click += (_, _) => _exitApp();
        contextMenu.Items.Add(exitItem);

        _trayIcon.ContextMenu = contextMenu;
    }

    public void ShowBalloon(string title, string message)
    {
        _trayIcon?.ShowBalloonTip(title, message, BalloonIcon.Info);
    }

    public void Dispose()
    {
        _trayIcon?.Dispose();
    }
}
