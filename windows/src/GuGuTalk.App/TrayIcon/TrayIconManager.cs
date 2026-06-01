using System.Windows;
using GuGuTalk.App.Views;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Services;
using GuGuTalk.Core.Settings;
using Hardcodet.Wpf.TaskbarNotification;

namespace GuGuTalk.App.TrayIcon;

public sealed class TrayIconManager : IDisposable
{
    private TaskbarIcon? _trayIcon;
    private TrayPanelWindow? _panelWindow;
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
        System.Drawing.Icon? icon = LoadAppIcon();

        _trayIcon = new TaskbarIcon
        {
            Icon = icon,
            ToolTipText = "GuGuTalk - 语音输入"
        };

        // Windows convention: left-click opens the full settings window,
        // right-click opens the quick panel.
        _trayIcon.TrayLeftMouseUp += (_, _) => _openSettings();
        _trayIcon.TrayRightMouseUp += (_, _) => TogglePanel();
        _trayIcon.TrayMouseDoubleClick += (_, _) => _openSettings();
    }

    private static System.Drawing.Icon LoadAppIcon()
    {
        // Prefer the bundled multi-size .ico (crisp at every DPI). Fall back to
        // the icon embedded in the exe, then to the system default.
        try
        {
            var baseDir = AppContext.BaseDirectory;
            var icoPath = System.IO.Path.Combine(baseDir, "Assets", "app-icon.ico");
            if (System.IO.File.Exists(icoPath))
                return new System.Drawing.Icon(icoPath);
        }
        catch { /* fall through */ }

        try
        {
            var exePath = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exePath))
            {
                var extracted = System.Drawing.Icon.ExtractAssociatedIcon(exePath);
                if (extracted is not null)
                    return extracted;
            }
        }
        catch { /* fall through */ }

        return System.Drawing.SystemIcons.Application;
    }

    private void TogglePanel()
    {
        if (_panelWindow is null)
        {
            _panelWindow = new TrayPanelWindow(_settings, _orchestrator, _openSettings, _exitApp);
        }

        if (_panelWindow.IsVisible)
        {
            _panelWindow.Hide();
        }
        else
        {
            _panelWindow.ShowNearTray();
        }
    }

    public void ShowBalloon(string title, string message)
    {
        _trayIcon?.ShowBalloonTip(title, message, BalloonIcon.Info);
    }

    public void Dispose()
    {
        _panelWindow?.Close();
        _trayIcon?.Dispose();
    }
}
