using System.Windows;
using System.Windows.Input;
using GuGuTalk.Core.Models;
using GuGuTalkModifiers = GuGuTalk.Core.Models.ModifierKeys;
using WpfModifiers = System.Windows.Input.ModifierKeys;

namespace GuGuTalk.App.Views;

public partial class HotkeyRecorderDialog : Window
{
    public HotkeyConfiguration? Result { get; private set; }

    public HotkeyRecorderDialog(string title, HotkeyConfiguration current)
    {
        InitializeComponent();
        Title = title;
        TitleText.Text = title;
        CurrentText.Text = $"当前：{current.DisplayName}";
        PromptText.Text = "按下新的热键组合...";
        Result = current;
        Focus();
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;

        // Ignore pure modifier presses
        if (IsModifierKey(key))
        {
            UpdatePreview(GetModifiers(), null);
            return;
        }

        if (key == Key.Escape)
        {
            DialogResult = false;
            Close();
            return;
        }

        var mods = GetModifiers();
        int vk = KeyInterop.VirtualKeyFromKey(key);
        string display = FormatHotkey(vk, mods);
        Result = new HotkeyConfiguration(vk, mods, display);

        UpdatePreview(mods, key);
        ConfirmButton.IsEnabled = true;
    }

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private void UpdatePreview(GuGuTalkModifiers mods, Key? key)
    {
        var parts = new List<string>();
        if (mods.HasFlag(GuGuTalkModifiers.Control)) parts.Add("Ctrl");
        if (mods.HasFlag(GuGuTalkModifiers.Alt)) parts.Add("Alt");
        if (mods.HasFlag(GuGuTalkModifiers.Shift)) parts.Add("Shift");
        if (mods.HasFlag(GuGuTalkModifiers.Win)) parts.Add("Win");
        if (key.HasValue) parts.Add(KeyToDisplay(key.Value));
        PromptText.Text = parts.Count > 0 ? string.Join("+", parts) : "按下新的热键组合...";
    }

    private static GuGuTalkModifiers GetModifiers()
    {
        var mods = GuGuTalkModifiers.None;
        var k = Keyboard.Modifiers;
        if (k.HasFlag(WpfModifiers.Control)) mods |= GuGuTalkModifiers.Control;
        if (k.HasFlag(WpfModifiers.Alt)) mods |= GuGuTalkModifiers.Alt;
        if (k.HasFlag(WpfModifiers.Shift)) mods |= GuGuTalkModifiers.Shift;
        if (k.HasFlag(WpfModifiers.Windows)) mods |= GuGuTalkModifiers.Win;
        return mods;
    }

    private static bool IsModifierKey(Key key) => key
        is Key.LeftCtrl or Key.RightCtrl
        or Key.LeftAlt or Key.RightAlt
        or Key.LeftShift or Key.RightShift
        or Key.LWin or Key.RWin
        or Key.System;

    private static string FormatHotkey(int vk, GuGuTalkModifiers mods)
    {
        var parts = new List<string>();
        if (mods.HasFlag(GuGuTalkModifiers.Control)) parts.Add("Ctrl");
        if (mods.HasFlag(GuGuTalkModifiers.Alt)) parts.Add("Alt");
        if (mods.HasFlag(GuGuTalkModifiers.Shift)) parts.Add("Shift");
        if (mods.HasFlag(GuGuTalkModifiers.Win)) parts.Add("Win");
        var key = KeyInterop.KeyFromVirtualKey(vk);
        parts.Add(KeyToDisplay(key));
        return string.Join("+", parts);
    }

    private static string KeyToDisplay(Key key) => key switch
    {
        Key.Space => "Space",
        Key.Oem3 => "`",
        Key.OemMinus => "-",
        Key.OemPlus => "=",
        _ => key.ToString()
    };
}
