# GuGuTalk Windows

macOS 原生语音输入工具 GuGuTalk 的 Windows 版本。

## 技术栈

- C# / .NET 8
- WPF (UI)
- NAudio (WASAPI 音频采集)
- sherpa-onnx (本地语音识别)
- FlaUI (UIAutomation 文字插入)
- WiX 5 (MSI 安装包)

## 构建

```powershell
dotnet build GuGuTalk.sln -c Release
```

**首次构建会自动从 GitHub 下载 sherpa-onnx SenseVoice int8 模型包（约 155MB，解压后约 240MB）**，缓存在 `.modelcache/`。
之后构建走缓存。
在非 Windows 机器上只验证编译时，可加 `/p:SkipAsrModelDownload=true /p:EnableWindowsTargeting=true` 跳过模型下载。

本地模型 smoke test（Windows 真机）：

```powershell
.\scripts\smoke-local-asr.ps1
```

脚本会用 bundled SenseVoice 模型解码自带 `zh.wav` / `en.wav`，用于先确认本地模型和 sherpa-onnx provider 路径可用。

## 运行（开发）

```powershell
dotnet run --project src/GuGuTalk.App
```

## 打包安装包

```powershell
dotnet publish src/GuGuTalk.App -c Release -r win-x64 --self-contained false
dotnet build installer/GuGuTalk.Installer.wixproj -c Release
```

生成的 `.msi` 中已包含识别模型，**用户安装后无需联网即可使用本地识别**。

## 测试

```powershell
dotnet test
```

## 功能

- 多种识别引擎：本地 (sherpa-onnx，内置) / 豆包 / 千问
- 灵活热键：按住说话 (Ctrl+`) + 切换模式 (Alt+Space)，可在设置中重新录制
- 三层文字插入：剪贴板 → UIAutomation → SendInput
- 智能后处理：热词替换 + LLM 优化（OpenAI / Anthropic）
- 系统托盘常驻 + 录音状态浮窗 + 波形动画

## 系统要求

- Windows 10 1903+ (x64)
- .NET 8 Runtime
- 麦克风

## 模型管理

- **构建时下载**：默认 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`（中/英/日/韩/粤，下载包约 155MB，解压后约 240MB）
- **路径搜索顺序**：用户目录 (`%LOCALAPPDATA%\GuGuTalk\models\`) 优先，然后是安装目录 (`<exe>\models\`)
- **替换模型**：把其他 sherpa-onnx SenseVoice/非流式兼容模型放到用户目录即可（包含 `tokens.txt` + `model.int8.onnx` 或 `model.onnx`）
