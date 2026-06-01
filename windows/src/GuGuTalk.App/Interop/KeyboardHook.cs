using System.Runtime.InteropServices;
using GuGuTalk.Core.Models;

namespace GuGuTalk.App.Interop;

internal sealed class KeyboardHook : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const uint LLKHF_INJECTED = 0x10;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    private IntPtr _hookId;
    private readonly LowLevelKeyboardProc _proc;

    public event Action<int, bool, ModifierKeys>? KeyEvent;

    public KeyboardHook()
    {
        _proc = HookCallback;
    }

    public void Install()
    {
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
    }

    public void Dispose()
    {
        if (_hookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            // KBDLLHOOKSTRUCT layout: vkCode(0), scanCode(4), flags(8), time(12), dwExtraInfo(16).
            // Skip events we (or any other app) injected via SendInput. Running the
            // full hotkey handler synchronously on an injected event blocks the LL
            // hook long enough that Windows silently DROPS our own SendInput paste
            // (manifesting as sent != requested). Injected keystrokes must pass
            // straight through to the next hook.
            uint flags = (uint)Marshal.ReadInt32(lParam, 8);
            bool injected = (flags & LLKHF_INJECTED) != 0;
            if (!injected)
            {
                int vkCode = Marshal.ReadInt32(lParam);
                int msg = (int)wParam;
                bool isDown = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
                var modifiers = GetCurrentModifiers();
                KeyEvent?.Invoke(vkCode, isDown, modifiers);
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private static ModifierKeys GetCurrentModifiers()
    {
        var mods = ModifierKeys.None;
        if ((GetAsyncKeyState(0xA2) & 0x8000) != 0 || (GetAsyncKeyState(0xA3) & 0x8000) != 0)
            mods |= ModifierKeys.Control;
        if ((GetAsyncKeyState(0xA4) & 0x8000) != 0 || (GetAsyncKeyState(0xA5) & 0x8000) != 0)
            mods |= ModifierKeys.Alt;
        if ((GetAsyncKeyState(0xA0) & 0x8000) != 0 || (GetAsyncKeyState(0xA1) & 0x8000) != 0)
            mods |= ModifierKeys.Shift;
        if ((GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0)
            mods |= ModifierKeys.Win;
        return mods;
    }
}
