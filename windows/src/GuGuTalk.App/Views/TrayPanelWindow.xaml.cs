using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Forms;
using System.Windows.Interop;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Services;
using GuGuTalk.Core.Settings;

namespace GuGuTalk.App.Views;

public partial class TrayPanelWindow : Window
{
    private readonly AppSettings _settings;
    private readonly RecognitionOrchestrator _orchestrator;
    private readonly Action _openSettings;
    private readonly Action _exitApp;
    private readonly List<ToggleButton> _modeButtons = new();

    public TrayPanelWindow(
        AppSettings settings,
        RecognitionOrchestrator orchestrator,
        Action openSettings,
        Action exitApp)
    {
        InitializeComponent();
        _settings = settings;
        _orchestrator = orchestrator;
        _openSettings = openSettings;
        _exitApp = exitApp;

        BuildModeChoiceBar();
        UpdateContent();

        _settings.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(UpdateContent);
        _orchestrator.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(UpdateContent);
    }

    public void ShowNearTray()
    {
        // Force a layout pass so ActualWidth/Height (in DIPs) are valid.
        Show();
        UpdateLayout();

        // On a PerMonitorV2 process, Control.MousePosition and Screen.WorkingArea
        // are in PHYSICAL pixels, while WPF's Left/Top/ActualWidth are in DIPs.
        // Mixing them puts the panel in the seam between monitors. So compute the
        // whole placement in physical pixels and position via SetWindowPos, which
        // takes physical coordinates directly — no DIP interpretation by WPF.
        var cursor = Control.MousePosition;
        var screen = Screen.FromPoint(cursor);
        var area = screen.WorkingArea; // physical px

        uint dpi = GetDpiForPoint(cursor);
        double scale = dpi / 96.0;
        int panelW = (int)Math.Ceiling(ActualWidth * scale);
        int panelH = (int)Math.Ceiling(ActualHeight * scale);

        int left = cursor.X - panelW / 2;
        int top = cursor.Y - panelH - (int)(8 * scale);

        // Clamp inside the target monitor's work area (physical px).
        if (left + panelW > area.Right) left = area.Right - panelW - (int)(4 * scale);
        if (left < area.Left) left = area.Left + (int)(4 * scale);
        if (top < area.Top) top = cursor.Y + (int)(12 * scale);

        var hwnd = new WindowInteropHelper(this).Handle;
        SetWindowPos(hwnd, IntPtr.Zero, left, top, panelW, panelH,
            SWP_NOZORDER | SWP_NOACTIVATE);
        Activate();
    }

    private static uint GetDpiForPoint(System.Drawing.Point pt)
    {
        // Per-monitor DPI of the monitor under the cursor. Falls back to 96.
        var hMon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        if (hMon != IntPtr.Zero &&
            GetDpiForMonitor(hMon, MDT_EFFECTIVE_DPI, out uint dpiX, out _) == 0)
        {
            return dpiX;
        }
        return 96;
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const int MDT_EFFECTIVE_DPI = 0;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(System.Drawing.Point pt, uint dwFlags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    private void BuildModeChoiceBar()
    {
        ModeChoiceBar.Children.Clear();
        _modeButtons.Clear();

        foreach (var mode in new[] { RecognitionMode.Local, RecognitionMode.Doubao, RecognitionMode.Qwen })
        {
            var btn = new ToggleButton
            {
                Content = mode.Title(),
                Style = (Style)FindResource("ChoiceBarSegment"),
                Tag = mode
            };
            btn.Click += OnModeClicked;
            _modeButtons.Add(btn);
            ModeChoiceBar.Children.Add(btn);
        }
    }

    private void OnModeClicked(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleButton btn && btn.Tag is RecognitionMode mode)
        {
            _settings.PreferredMode = mode;
            _settings.Save();
            UpdateContent();
        }
    }

    private void UpdateContent()
    {
        // Mode badge + segmented control selection
        ModeBadge.Text = _settings.PreferredMode.Title();
        foreach (var btn in _modeButtons)
        {
            btn.IsChecked = btn.Tag is RecognitionMode m && m == _settings.PreferredMode;
        }

        // Status card text
        bool hasError = !string.IsNullOrEmpty(_orchestrator.PreviewError);
        bool isWorking = _orchestrator.IsRecording || _orchestrator.IsPostProcessing;
        if (hasError)
        {
            StatusText.Text = "出错了";
            StatusDot.Fill = (System.Windows.Media.Brush)FindResource("DangerRedBrush");
        }
        else if (isWorking)
        {
            StatusText.Text = _orchestrator.IsRecording ? "正在聆听" : "处理中";
            StatusDot.Fill = (System.Windows.Media.Brush)FindResource("IconAquaBrush");
        }
        else
        {
            StatusText.Text = "就绪";
            StatusDot.Fill = (System.Windows.Media.Brush)FindResource("ReadyGreenBrush");
        }

        HotkeyText.Text = $"按住 {_settings.HoldToTalkHotkey.DisplayName} 说话";
    }

    private void OnOpenSettingsClicked(object sender, RoutedEventArgs e)
    {
        Hide();
        _openSettings();
    }

    private void OnExitClicked(object sender, RoutedEventArgs e)
    {
        Hide();
        _exitApp();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        Hide();
    }
}
