using GuGuTalk.Core.Interop;
using GuGuTalk.Core.Models;
using Serilog;

namespace GuGuTalk.Core.Services;

public sealed class TextInsertionService : ITextInsertionService
{
    private static readonly ILogger Logger = Log.ForContext<TextInsertionService>();

    public InsertionResult Insert(string text, IntPtr targetHwnd = default)
    {
        if (string.IsNullOrEmpty(text))
            return new InsertionResult(InsertionMethod.Failed, null, false, "文本为空");

        WaitForModifiersReleased();

        if (targetHwnd != IntPtr.Zero)
        {
            var (capTitle, capProc) = NativeMethods.GetWindowInfo(targetHwnd);
            bool restored = NativeMethods.ForceForegroundWindow(targetHwnd);
            Logger.Information("恢复目标窗口前台 hwnd={Hwnd:X} title={Title} proc={Proc} success={Ok}",
                targetHwnd.ToInt64(), capTitle ?? "未知", capProc ?? "未知", restored);
            // Give the target a moment to actually take focus on its editable
            // control before we start typing into it.
            Thread.Sleep(60);
        }

        var (title, processName) = NativeMethods.GetForegroundWindowInfo();
        Logger.Information("开始插入文本，目标: {Title} ({Process})，长度: {Len}",
            title ?? "未知", processName ?? "未知", text.Length);

        // Universal primary: SendInput Unicode. KEYEVENTF_UNICODE synthesizes a
        // WM_CHAR for every character, which is accepted by essentially every
        // text surface on Windows — terminals (Windows Terminal / conhost),
        // Chromium/Electron apps (Chrome, Cursor, VS Code, 讯飞/新版微信), and
        // classic Win32 edit controls alike. This is what AutoHotkey and other
        // dictation tools use to reach ALL apps including terminals, and it
        // needs no clipboard, so there is no clipboard pollution or restore
        // race. Clipboard paste is only a fallback for the rare surface that
        // ignores injected characters.
        if (TrySendInput(text))
        {
            Logger.Information("SendInput Unicode 插入成功");
            return new InsertionResult(InsertionMethod.SendInput, title, true, null);
        }

        Logger.Warning("SendInput 未能投递，回退到剪贴板 Ctrl+V");
        if (TryCtrlV(text))
        {
            Logger.Information("Ctrl+V 模拟粘贴成功");
            return new InsertionResult(InsertionMethod.Clipboard, title, true, null);
        }

        Logger.Warning("Ctrl+V 失败，回退到 WM_PASTE");
        if (TryWmPaste(text))
        {
            Logger.Information("WM_PASTE 直接投递成功");
            return new InsertionResult(InsertionMethod.Clipboard, title, true, null);
        }

        Logger.Error("所有插入方法都失败");
        return new InsertionResult(InsertionMethod.Failed, title, false,
            "无法写入当前应用，请手动复制预览文本。");
    }

    /// <summary>
    /// Set clipboard text, then send WM_PASTE directly to the target's focused
    /// control via SendMessage. This bypasses keystroke simulation entirely.
    /// </summary>
    private static bool TryWmPaste(string text)
    {
        try
        {
            string? saved = NativeMethods.GetClipboardText();
            if (!NativeMethods.SetClipboardText(text))
            {
                Logger.Warning("WM_PASTE: SetClipboardText 失败");
                return false;
            }

            IntPtr focusedControl = GetTargetFocusedControl();
            if (focusedControl == IntPtr.Zero)
            {
                Logger.Warning("WM_PASTE: 无法获取目标焦点控件");
                RestoreClipboard(saved);
                return false;
            }

            Logger.Information("WM_PASTE 发送到控件 hwnd={Hwnd:X}", focusedControl.ToInt64());
            NativeMethods.SendMessage(focusedControl, NativeMethods.WM_PASTE, IntPtr.Zero, IntPtr.Zero);
            Thread.Sleep(100);

            RestoreClipboard(saved);
            return true;
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "WM_PASTE 失败");
            return false;
        }
    }

    /// <summary>
    /// Fallback: set clipboard and simulate Ctrl+V keystrokes.
    /// </summary>
    private static bool TryCtrlV(string text)
    {
        try
        {
            string? saved = NativeMethods.GetClipboardText();
            if (!NativeMethods.SetClipboardText(text)) return false;
            Thread.Sleep(50);
            NativeMethods.SendCtrlV();
            Thread.Sleep(500);
            RestoreClipboard(saved);
            return true;
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Ctrl+V 模拟失败");
            return false;
        }
    }

    /// <summary>
    /// Gets the focused control handle within the foreground window by
    /// temporarily attaching to its thread.
    /// </summary>
    private static IntPtr GetTargetFocusedControl()
    {
        IntPtr foreground = NativeMethods.GetForegroundWindow();
        if (foreground == IntPtr.Zero) return IntPtr.Zero;

        uint foregroundThread = NativeMethods.GetWindowThreadProcessId(foreground, out _);
        uint currentThread = NativeMethods.GetCurrentThreadId();

        if (foregroundThread == currentThread)
            return NativeMethods.GetFocus();

        IntPtr focused = IntPtr.Zero;
        if (NativeMethods.AttachThreadInput(currentThread, foregroundThread, true))
        {
            focused = NativeMethods.GetFocus();
            NativeMethods.AttachThreadInput(currentThread, foregroundThread, false);
        }

        // If GetFocus returned null, fall back to the foreground window itself
        return focused != IntPtr.Zero ? focused : foreground;
    }

    private static void RestoreClipboard(string? saved)
    {
        if (saved is not null)
        {
            Thread.Sleep(50);
            NativeMethods.SetClipboardText(saved);
        }
    }

    private static bool TrySendInput(string text)
    {
        try
        {
            return NativeMethods.SendUnicodeText(text);
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "SendInput 失败");
            return false;
        }
    }

    private static void WaitForModifiersReleased()
    {
        const int VK_CONTROL = 0x11;
        const int VK_MENU = 0x12;
        const int VK_SHIFT = 0x10;

        int waited = 0;
        while (waited < 500)
        {
            bool ctrlDown = (NativeMethods.GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
            bool altDown = (NativeMethods.GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
            bool shiftDown = (NativeMethods.GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
            if (!ctrlDown && !altDown && !shiftDown) break;
            Thread.Sleep(10);
            waited += 10;
        }
        if (waited > 0)
        {
            Logger.Information("等待修饰键释放 {Ms}ms", waited);
        }
    }
}