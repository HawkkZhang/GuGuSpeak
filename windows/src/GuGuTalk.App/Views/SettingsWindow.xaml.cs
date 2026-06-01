using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Services;
using GuGuTalk.Core.Settings;

namespace GuGuTalk.App.Views;

public partial class SettingsWindow : Window
{
    private readonly AppSettings _settings;
    private readonly IHotkeyManager? _hotkeyManager;
    private readonly IPermissionCoordinator _permissions;
    private readonly StackPanel[] _pages;

    public SettingsWindow(
        AppSettings settings,
        IHotkeyManager? hotkeyManager = null,
        IPermissionCoordinator? permissions = null)
    {
        InitializeComponent();
        _settings = settings;
        _hotkeyManager = hotkeyManager;
        _permissions = permissions ?? new PermissionCoordinator();
        _pages = [GeneralPage, ProviderPage, HotkeyPage, PostProcessPage, PermissionsPage, AboutPage];

        LoadSettings();
        ShowPage(0);
        _ = RefreshPermissionsAsync();
    }

    /// <summary>
    /// Make sure the window always fits inside the current monitor's work area
    /// and its title bar stays on-screen, even on small or DPI-scaled displays.
    /// Without this a 640-DIP-tall window becomes 800px at 125% scaling and the
    /// title bar gets pushed off the top edge — leaving it un-draggable and
    /// cut off.
    /// </summary>
    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var src = PresentationSource.FromVisual(this);
        if (src?.CompositionTarget is null) return;

        // Device pixels -> DIPs for this window's monitor.
        double scaleX = src.CompositionTarget.TransformToDevice.M11;
        double scaleY = src.CompositionTarget.TransformToDevice.M22;
        if (scaleX <= 0) scaleX = 1;
        if (scaleY <= 0) scaleY = 1;

        var screen = System.Windows.Forms.Screen.FromHandle(
            new System.Windows.Interop.WindowInteropHelper(this).Handle);
        double areaW = screen.WorkingArea.Width / scaleX;
        double areaH = screen.WorkingArea.Height / scaleY;
        double areaLeft = screen.WorkingArea.Left / scaleX;
        double areaTop = screen.WorkingArea.Top / scaleY;

        // Shrink to fit, leaving a small margin.
        if (Width > areaW - 16) Width = Math.Max(MinWidth, areaW - 16);
        if (Height > areaH - 16) Height = Math.Max(MinHeight, areaH - 16);

        // Re-center, then clamp so the title bar is never above the work area.
        Left = areaLeft + Math.Max(0, (areaW - Width) / 2);
        Top = areaTop + Math.Max(0, (areaH - Height) / 2);
    }

    private void HoldHotkey_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new HotkeyRecorderDialog("录制 \"按住说话\" 热键", _settings.HoldToTalkHotkey)
        {
            Owner = this
        };
        if (dialog.ShowDialog() == true && dialog.Result is not null)
        {
            _settings.HoldToTalkHotkey = dialog.Result;
            HoldHotkeyDisplay.Text = dialog.Result.DisplayName;
        }
    }

    private void ToggleHotkey_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new HotkeyRecorderDialog("录制 \"切换模式\" 热键", _settings.ToggleToTalkHotkey)
        {
            Owner = this
        };
        if (dialog.ShowDialog() == true && dialog.Result is not null)
        {
            _settings.ToggleToTalkHotkey = dialog.Result;
            ToggleHotkeyDisplay.Text = dialog.Result.DisplayName;
        }
    }

    private void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsInitialized || PageTitle is null) return;
        if (NavList.SelectedIndex >= 0)
            ShowPage(NavList.SelectedIndex);
    }

    private void ShowPage(int index)
    {
        string[] titles = ["通用", "输入引擎", "热键", "后处理", "权限", "关于"];
        PageTitle.Text = titles[index];

        for (int i = 0; i < _pages.Length; i++)
            _pages[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;

        if (index == 4) _ = RefreshPermissionsAsync();
    }

    private async void PermissionsRefresh_Click(object sender, RoutedEventArgs e)
    {
        await RefreshPermissionsAsync();
    }

    private void OpenMicrophoneSettings_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "ms-settings:privacy-microphone",
                UseShellExecute = true
            });
        }
        catch { /* settings URI not available */ }
    }

    private async Task RefreshPermissionsAsync()
    {
        await _permissions.RefreshAllAsync();
        var mic = _permissions.CurrentStates.FirstOrDefault(s => s.Kind == PermissionKind.Microphone);
        var hook = _permissions.CurrentStates.FirstOrDefault(s => s.Kind == PermissionKind.KeyboardHook);

        ApplyPermissionRow(MicStatusDot, MicStatusDescription, MicSettingsButton, mic?.Status,
            granted: "麦克风权限已授予",
            denied: "麦克风权限被拒绝。请在 Windows 设置 > 隐私 > 麦克风 中允许此应用访问。",
            unknown: "正在检查麦克风权限...");

        ApplyPermissionRow(HookStatusDot, HookStatusDescription, null, hook?.Status,
            granted: "全局热键可用",
            denied: "全局热键被安全软件拦截。请将 GuGuTalk 添加到白名单。",
            unknown: "正在检查热键权限...");

        bool allReady = _permissions.AllRequiredReady();
        PermissionsSummary.Text = allReady
            ? "权限已就绪，可以正常使用"
            : "还有权限未就绪，部分功能可能受限";
    }

    private void ApplyPermissionRow(
        System.Windows.Shapes.Ellipse dot,
        TextBlock description,
        Button? actionButton,
        PermissionStatus? status,
        string granted, string denied, string unknown)
    {
        switch (status)
        {
            case PermissionStatus.Granted:
                dot.Fill = (Brush)FindResource("ReadyGreenBrush");
                description.Text = granted;
                if (actionButton is not null) actionButton.Visibility = Visibility.Collapsed;
                break;
            case PermissionStatus.Denied:
                dot.Fill = (Brush)FindResource("DangerRedBrush");
                description.Text = denied;
                if (actionButton is not null) actionButton.Visibility = Visibility.Visible;
                break;
            default:
                dot.Fill = (Brush)FindResource("SignalAmberBrush");
                description.Text = unknown;
                if (actionButton is not null) actionButton.Visibility = Visibility.Collapsed;
                break;
        }
    }

    private void LoadSettings()
    {
        ModeCombo.SelectedIndex = (int)_settings.PreferredMode;
        FollowSystemTheme.IsChecked = _settings.FollowSystemTheme;

        DoubaoAppId.Text = _settings.DoubaoAppId;
        DoubaoAccessKey.Password = _settings.DoubaoAccessKey;
        DoubaoResourceId.Text = _settings.DoubaoResourceId;
        DoubaoEndpoint.Text = _settings.DoubaoEndpoint;

        QwenApiKey.Password = _settings.QwenApiKey;
        QwenModel.Text = _settings.QwenModel;
        QwenEndpoint.Text = _settings.QwenEndpoint;

        HoldEnabled.IsChecked = _settings.HoldToTalkEnabled;
        HoldHotkeyDisplay.Text = _settings.HoldToTalkHotkey.DisplayName;
        ToggleEnabled.IsChecked = _settings.ToggleToTalkEnabled;
        ToggleHotkeyDisplay.Text = _settings.ToggleToTalkHotkey.DisplayName;

        PostProcessEnabled.IsChecked = _settings.PostProcessingEnabled;
        PunctuationCombo.SelectedIndex = (int)_settings.PunctuationMode;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        SaveSettings();
        e.Cancel = true;
        Hide();
    }

    private void SaveSettings()
    {
        _settings.PreferredMode = (RecognitionMode)ModeCombo.SelectedIndex;
        _settings.FollowSystemTheme = FollowSystemTheme.IsChecked == true;

        _settings.DoubaoAppId = DoubaoAppId.Text;
        _settings.DoubaoAccessKey = DoubaoAccessKey.Password;
        _settings.DoubaoResourceId = DoubaoResourceId.Text;
        _settings.DoubaoEndpoint = DoubaoEndpoint.Text;

        _settings.QwenApiKey = QwenApiKey.Password;
        _settings.QwenModel = QwenModel.Text;
        _settings.QwenEndpoint = QwenEndpoint.Text;

        _settings.HoldToTalkEnabled = HoldEnabled.IsChecked == true;
        _settings.ToggleToTalkEnabled = ToggleEnabled.IsChecked == true;

        _settings.PostProcessingEnabled = PostProcessEnabled.IsChecked == true;
        _settings.PunctuationMode = (PunctuationMode)PunctuationCombo.SelectedIndex;

        _settings.Save();
        _hotkeyManager?.ReloadConfiguration();
    }
}
