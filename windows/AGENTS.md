# Agent Instructions (Windows)

Windows 版 GuGuTalk 的开发规范。**先读仓库根目录的 [`AGENTS.md`](../AGENTS.md)**。

## 技术栈

- **语言**: C# 12 / .NET 8
- **UI**: WPF（XAML + code-behind + MVVM via CommunityToolkit.Mvvm）
- **音频**: NAudio (WASAPI 共享模式)
- **本地识别**: sherpa-onnx (.NET 绑定)
- **文字插入**: FlaUI (UIAutomation) + SendInput + 剪贴板（三层降级）
- **托盘**: Hardcodet.NotifyIcon.Wpf
- **日志**: Serilog
- **打包**: WiX Toolset 5

## 项目结构（src/）

```
src/
├── GuGuTalk.Core/          ← 业务逻辑（class library, 无 UI 依赖）
│   ├── Models/             ← 数据模型（record 类型）
│   ├── Services/           ← 业务服务（Audio / Hotkey / TextInsert / Orchestrator / PostProcessor / LLM / Hotword / Permission）
│   ├── Providers/          ← Speech provider 实现（Doubao / Qwen + 接口）
│   ├── Settings/           ← AppSettings (JSON 持久化)
│   └── Interop/            ← P/Invoke (Win32 API)
├── GuGuTalk.App/           ← WPF 应用 (WinExe)
│   ├── App.xaml(.cs)       ← 启动入口、依赖装配
│   ├── ViewModels/         ← MVVM
│   ├── Views/              ← 窗口（Settings / Overlay / HotkeyRecorder + Controls/）
│   ├── Theme/              ← Colors.xaml + Styles.xaml
│   ├── TrayIcon/           ← 系统托盘
│   ├── Interop/            ← App 层 P/Invoke (KeyboardHook)
│   └── Assets/             ← 图标
└── GuGuTalk.LocalAsr/      ← sherpa-onnx 封装（独立项目，方便未来切换实现）
```

## 分层规则

- **Core 不依赖 WPF**。不能 `using System.Windows.*`。剪贴板用 P/Invoke 实现（已在 `Core/Interop/NativeMethods.cs`）。
- **App 依赖 Core**。UI 通过 ObservableObject + INotifyPropertyChanged 绑定 RecognitionOrchestrator 状态。
- **LocalAsr 依赖 Core**。只通过 ISpeechProvider 接口暴露能力。

## 构建

```powershell
# 还原 + 构建
dotnet restore
dotnet build GuGuTalk.sln -c Release

# 运行（开发）
dotnet run --project src/GuGuTalk.App

# 测试
dotnet test
```

**首次构建会自动下载 sherpa-onnx SenseVoice int8 模型包**（约 155MB，解压后约 240MB），缓存到 `.modelcache/`。CI 应缓存这个目录。

## 打包

```powershell
dotnet publish src/GuGuTalk.App -c Release -r win-x64 --self-contained false
dotnet build installer/GuGuTalk.Installer.wixproj -c Release
```

生成的 `.msi` 文件**已包含识别模型**，用户安装后开箱即用。

## 模型管理

- 默认模型：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`
- 构建时下载到：`src/GuGuTalk.LocalAsr/bundled-models/`（gitignored）
- 运行时搜索顺序（`ModelManager.GetTokensPath()`）：
  1. 用户目录：`%LOCALAPPDATA%\GuGuTalk\models\`（用户可放替换模型）
  2. 安装目录：`<exe>\models\`（MSI 内置）
- 当前 provider 使用 sherpa-onnx OfflineRecognizer + SenseVoice；替换模型需提供 `tokens.txt` 和 `model.int8.onnx`/`model.onnx`

## P/Invoke 注意事项

- 公共 P/Invoke 放在 `GuGuTalk.Core/Interop/NativeMethods.cs`，用 `LibraryImport` 优先（源生成器，性能更好），需要 `CharSet` 时退回 `DllImport`
- 钩子相关（`SetWindowsHookEx` 等）放在 `App/Interop/KeyboardHook.cs`，因为只有 App 进程有消息循环
- **修饰键状态**用 `GetAsyncKeyState`，不要尝试在低级钩子里读 lParam.flags（不可靠）
- SendInput 发 Unicode 字符时 `wVk = 0`，flag 用 `KEYEVENTF_UNICODE`
- 剪贴板操作必须 `OpenClipboard` → ... → `CloseClipboard` 配对，否则会卡

## 文字插入策略

`TextInsertionService` 三层降级，**默认顺序：剪贴板 → UIAutomation → SendInput**。

- 剪贴板优先：因为对中文最稳，几乎所有应用都支持 Ctrl+V
- 但**微信例外**（进程名 `WeChat` / `WeChatAppEx` / `Weixin`）：用 UIAutomation 优先，因为微信对剪贴板粘贴有特殊处理（图片/文件混入等）
- 修改这个顺序前考虑：什么应用打破了它？换顺序会不会让原本工作的应用坏掉？

## 热键约定

- 默认 Hold: `Ctrl + ` `（反引号）
- 默认 Toggle: `Alt + Space`
- 不要用 `Fn` 作为默认热键：Windows 上 Fn 键不发送可拦截的键码（很多笔记本上是固件级处理）
- 设置里通过 `HotkeyRecorderDialog` 录制，Esc 取消

## 设置持久化

`%LOCALAPPDATA%\GuGuTalk\settings.json` — JSON 格式，CommunityToolkit.Mvvm 的 `[ObservableProperty]` 自动通知。

不要把以下内容存到这里：
- API Key、Access Key（**应该**存在这里没错，但不要在日志里输出值，只输出"已配置/未配置"）
- 用户文档路径之类的运行时上下文

## 日志

```csharp
private static readonly ILogger Logger = Log.ForContext<MyClass>();
Logger.Information("识别开始 mode={Mode}", config.Mode.Title());
```

日志位置：`%LOCALAPPDATA%\GuGuTalk\logs\gugutalk-<date>.log`（按天滚动，保留 7 天）

**不要 log API key、access token、accessibility 文件路径等敏感信息**。

## 常见任务

### 添加一个新的 speech provider

1. 在 `Core/Models/RecognitionMode.cs` 加枚举
2. 在 `Core/Providers/` 实现 `ISpeechProvider`（参考 `QwenSpeechProvider` 是最简洁的模板）
3. 在 `Core/Providers/ProviderFactory.cs` 加路由
4. 在 `Core/Settings/AppSettings.cs` 加凭证字段
5. 在 `App/Views/SettingsWindow.xaml` 加配置 UI
6. **同步检查 macOS 端**是否需要对应实现（参考根 AGENTS.md 的协议同步规则）

### 改云端协议帧格式

豆包/千问的协议改动**必须同时改 macOS 和 Windows**。提交信息用 `protocol:` 前缀，把两边的改动放在同一个 commit 里方便审计。

### 改 UI

- 颜色：改 `Theme/Colors.xaml`，DESIGN.md 里的色值是源头，改了要同步
- 控件样式：`Theme/Styles.xaml`
- 设置窗口的页面：`Views/SettingsWindow.xaml` 里 5 个 `StackPanel` 切换显示
- Overlay：`Views/OverlayWindow.xaml`，最大 320×140，定位到屏幕右下角

## 验证

提交前：

```powershell
dotnet build -c Release   # 必须编译通过
dotnet test                # 不能让测试退化
```

UI 改动：实际运行一次 `dotnet run --project src/GuGuTalk.App`，按热键试一次端到端流程，**不要只看代码就声称改完了**。

## 不要做

- ❌ 在 Core 项目里 `using System.Windows.*` 或引用 PresentationFramework
- ❌ 用 `Thread.Sleep` 阻塞 UI 线程，用 `await Task.Delay`
- ❌ 在 hot path（每个音频 chunk 触发的回调）里 `Console.WriteLine` 或 `Logger.Information`，用 `Logger.Verbose`
- ❌ 改 `Directory.Packages.props` 时不写明为什么升级，包升级容易引入 break change
- ❌ 把 `bin/`、`obj/`、`.modelcache/`、`bundled-models/`、`*.msi` 提交到 git
