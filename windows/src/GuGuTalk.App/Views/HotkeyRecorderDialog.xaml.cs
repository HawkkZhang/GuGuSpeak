using System.Media;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using GuGuTalk.Core.Models;
using GuGuTalkModifiers = GuGuTalk.Core.Models.ModifierKeys;
using WpfModifiers = System.Windows.Input.ModifierKeys;

namespace GuGuTalk.App.Views;

public partial class HotkeyRecorderDialog : Window
{
    public HotkeyConfiguration? Result { get; private set; }
    private bool _hasNewCapture;

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

        if (key == Key.Escape)
        {
            DialogResult = false;
            Close();
            return;
        }

        // Modifier-only press: just preview, no commit
        if (IsModifierKey(key))
        {
            UpdatePreview(GetModifiers(), null);
            return;
        }

        var mods = GetModifiers();

        // Reject bare main key without any modifier
        if (mods == GuGuTalkModifiers.None)
        {
            ShakeAndBeep();
            return;
        }

        int vk = KeyInterop.VirtualKeyFromKey(key);
        string display = FormatHotkey(vk, mods);
        Result = new HotkeyConfiguration(vk, mods, display);
        _hasNewCapture = true;

        UpdatePreview(mods, key);
        ConfirmButton.IsEnabled = true;
    }

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        if (!_hasNewCapture)
        {
            ShakeAndBeep();
            return;
        }
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

    /// <summary>
    /// Tactile feedback when the captured combo is invalid: shake the prompt
    /// 4 frames horizontally and ding the system beep, mirroring the Mac
    /// hotkey recorder's behavior.
    /// </summary>
    private void ShakeAndBeep()
    {
        SystemSounds.Beep.Play();
        var keyframes = new DoubleAnimationUsingKeyFrames();
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        double[] offsets = { -8, 7, -5, 3, 0 };
        for (int i = 0; i < offsets.Length; i++)
        {
            keyframes.KeyFrames.Add(new EasingDoubleKeyFrame(
                offsets[i],
                KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(80 * (i + 1))),
                ease));
        }
        PromptShakeTransform.BeginAnimation(TranslateTransform.XProperty, keyframes);
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
