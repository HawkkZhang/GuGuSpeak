using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace GuGuTalk.Core.Interop;

internal static partial class NativeMethods
{
    [LibraryImport("user32.dll")]
    internal static partial IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [LibraryImport("user32.dll")]
    internal static partial uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(IntPtr hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool fAttach);

    [LibraryImport("kernel32.dll")]
    internal static partial uint GetCurrentThreadId();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsWindow(IntPtr hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsWindowVisible(IntPtr hWnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool BringWindowToTop(IntPtr hWnd);

    internal const int SW_RESTORE = 9;
    internal const int SW_SHOW = 5;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsIconic(IntPtr hWnd);

    [LibraryImport("user32.dll")]
    internal static partial short GetAsyncKeyState(int vKey);

    [LibraryImport("user32.dll", EntryPoint = "MapVirtualKeyW")]
    internal static partial uint MapVirtualKey(uint uCode, uint uMapType);

    internal const uint MAPVK_VK_TO_VSC = 0;

    [LibraryImport("user32.dll")]
    internal static partial IntPtr GetFocus();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    internal static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    internal const uint WM_PASTE = 0x0302;
    internal const uint EM_REPLACESEL = 0x00C2;

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    // Clipboard
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CloseClipboard();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern IntPtr GetClipboardData(uint uFormat);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsClipboardFormatAvailable(uint format);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [LibraryImport("kernel32.dll")]
    internal static partial IntPtr GlobalLock(IntPtr hMem);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GlobalUnlock(IntPtr hMem);

    [LibraryImport("kernel32.dll")]
    internal static partial UIntPtr GlobalSize(IntPtr hMem);

    internal const uint CF_UNICODETEXT = 13;
    internal const uint GMEM_MOVEABLE = 0x0002;

    internal const int INPUT_KEYBOARD = 1;
    internal const uint KEYEVENTF_KEYUP = 0x0002;
    internal const uint KEYEVENTF_UNICODE = 0x0004;
    internal const uint KEYEVENTF_SCANCODE = 0x0008;

    internal const ushort VK_CONTROL = 0x11;
    internal const ushort VK_V = 0x56;
    internal const ushort VK_LWIN = 0x5B;
    internal const ushort VK_RWIN = 0x5C;

    [StructLayout(LayoutKind.Sequential)]
    internal struct INPUT
    {
        public int type;
        public INPUTUNION u;
    }

    // Win32 INPUT.union must be sized to its LARGEST member (MOUSEINPUT) — 32
    // bytes on x64 — so the whole INPUT struct is 40 bytes. SendInput's cbSize
    // is checked exactly against this; if we declared the union with only
    // KEYBDINPUT, Marshal.SizeOf<INPUT>() returns 32 and SendInput silently
    // refuses to inject anything (ERROR_INVALID_PARAMETER). Declare all three
    // members at offset 0 so KEYBDINPUT keeps its current offsets/usage but
    // the union is padded out to MOUSEINPUT's size.
    [StructLayout(LayoutKind.Explicit)]
    internal struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    internal static (string? Title, string? ProcessName) GetForegroundWindowInfo()
    {
        var hWnd = GetForegroundWindow();
        return GetWindowInfo(hWnd);
    }

    internal static (string? Title, string? ProcessName) GetWindowInfo(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return (null, null);

        var sb = new StringBuilder(512);
        GetWindowText(hWnd, sb, sb.Capacity);
        string? title = sb.Length > 0 ? sb.ToString() : null;

        string? processName = null;
        try
        {
            GetWindowThreadProcessId(hWnd, out uint pid);
            using var process = Process.GetProcessById((int)pid);
            processName = process.ProcessName;
        }
        catch { }

        return (title, processName);
    }

    /// <summary>
    /// SetForegroundWindow has restrictions in modern Windows -- the standard
    /// workaround is AttachThreadInput between the calling thread and the
    /// target window's thread for the duration of the call. Returns true if
    /// the target HWND ended up foreground.
    /// </summary>
    internal static bool ForceForegroundWindow(IntPtr targetHwnd)
    {
        if (targetHwnd == IntPtr.Zero || !IsWindow(targetHwnd)) return false;
        if (GetForegroundWindow() == targetHwnd) return true;

        if (IsIconic(targetHwnd))
        {
            ShowWindow(targetHwnd, SW_RESTORE);
        }

        uint targetThread = GetWindowThreadProcessId(targetHwnd, out _);
        uint currentThread = GetCurrentThreadId();
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out _);

        bool attachedTarget = false;
        bool attachedForeground = false;
        try
        {
            if (targetThread != currentThread)
            {
                attachedTarget = AttachThreadInput(currentThread, targetThread, true);
            }
            if (foregroundThread != 0 && foregroundThread != currentThread && foregroundThread != targetThread)
            {
                attachedForeground = AttachThreadInput(currentThread, foregroundThread, true);
            }

            BringWindowToTop(targetHwnd);
            SetForegroundWindow(targetHwnd);
        }
        finally
        {
            if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
        }

        return GetForegroundWindow() == targetHwnd;
    }

    internal static bool SendUnicodeText(string text)
    {
        if (string.IsNullOrEmpty(text)) return true;

        var inputs = new List<INPUT>(text.Length * 2);
        foreach (char c in text)
        {
            inputs.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                u = new INPUTUNION { ki = new KEYBDINPUT { wScan = c, dwFlags = KEYEVENTF_UNICODE } }
            });
            inputs.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                u = new INPUTUNION { ki = new KEYBDINPUT { wScan = c, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } }
            });
        }

        var arr = inputs.ToArray();
        uint sent = SendInput((uint)arr.Length, arr, Marshal.SizeOf<INPUT>());
        return sent == arr.Length;
    }

    internal static void SendCtrlV()
    {
        // Chromium/Electron apps (Chrome, Cursor, VS Code, 讯飞/微信 newer
        // clients) rebuild key events from the SCAN CODE, not the virtual
        // key. A synthetic Ctrl+V carrying only wVk is silently ignored by
        // them. We send both wVk and the mapped wScan with KEYEVENTF_SCANCODE
        // so the keystroke survives Chromium's input pipeline as well as
        // classic Win32 edit controls.
        ushort scanCtrl = (ushort)MapVirtualKey(VK_CONTROL, MAPVK_VK_TO_VSC);
        ushort scanV = (ushort)MapVirtualKey(VK_V, MAPVK_VK_TO_VSC);

        var inputs = new INPUT[]
        {
            new() { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = VK_CONTROL, wScan = scanCtrl, dwFlags = KEYEVENTF_SCANCODE } } },
            new() { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = VK_V, wScan = scanV, dwFlags = KEYEVENTF_SCANCODE } } },
            new() { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = VK_V, wScan = scanV, dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP } } },
            new() { type = INPUT_KEYBOARD, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = VK_CONTROL, wScan = scanCtrl, dwFlags = KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP } } }
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    internal static string? GetClipboardText()
    {
        if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
        if (!OpenClipboard(IntPtr.Zero)) return null;

        try
        {
            var hData = GetClipboardData(CF_UNICODETEXT);
            if (hData == IntPtr.Zero) return null;

            var pData = GlobalLock(hData);
            if (pData == IntPtr.Zero) return null;

            try
            {
                return Marshal.PtrToStringUni(pData);
            }
            finally
            {
                GlobalUnlock(hData);
            }
        }
        finally
        {
            CloseClipboard();
        }
    }

    internal static bool SetClipboardText(string text)
    {
        if (!OpenClipboard(IntPtr.Zero)) return false;

        try
        {
            EmptyClipboard();

            int byteCount = (text.Length + 1) * 2; // UTF-16 + null terminator
            IntPtr hGlobal = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)byteCount);
            if (hGlobal == IntPtr.Zero) return false;

            IntPtr pGlobal = GlobalLock(hGlobal);
            if (pGlobal == IntPtr.Zero) return false;

            try
            {
                Marshal.Copy(text.ToCharArray(), 0, pGlobal, text.Length);
                Marshal.WriteInt16(pGlobal, text.Length * 2, 0); // null terminator
            }
            finally
            {
                GlobalUnlock(hGlobal);
            }

            return SetClipboardData(CF_UNICODETEXT, hGlobal) != IntPtr.Zero;
        }
        finally
        {
            CloseClipboard();
        }
    }
}
