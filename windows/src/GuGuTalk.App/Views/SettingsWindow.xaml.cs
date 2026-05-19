using System.Windows;
using System.Windows.Controls;
using GuGuTalk.Core.Services;
using GuGuTalk.Core.Settings;

namespace GuGuTalk.App.Views;

public partial class SettingsWindow : Window
{
    private readonly AppSettings _settings;
    private readonly IHotkeyManager? _hotkeyManager;
    private readonly StackPanel[] _pages;

    public SettingsWindow(AppSettings settings, IHotkeyManager? hotkeyManager = null)
    {
        InitializeComponent();
        _settings = settings;
        _hotkeyManager = hotkeyManager;
        _pages = [GeneralPage, ProviderPage, HotkeyPage, PostProcessPage, AboutPage];

        LoadSettings();
        ShowPage(0);
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
        // SelectionChanged fires during XAML EndInit, before constructor completes
        // and named elements are wired up. Skip until everything is ready.
        if (!IsInitialized || PageTitle is null) return;
        if (NavList.SelectedIndex >= 0)
            ShowPage(NavList.SelectedIndex);
    }

    private void ShowPage(int index)
    {
        string[] titles = ["通用", "输入引擎", "热键", "后处理", "关于"];
        PageTitle.Text = titles[index];

        for (int i = 0; i < _pages.Length; i++)
            _pages[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
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
        _settings.PreferredMode = (GuGuTalk.Core.Models.RecognitionMode)ModeCombo.SelectedIndex;
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
        _settings.PunctuationMode = (GuGuTalk.Core.Models.PunctuationMode)PunctuationCombo.SelectedIndex;

        _settings.Save();
        _hotkeyManager?.ReloadConfiguration();
    }
}
