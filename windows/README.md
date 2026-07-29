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

**首次构建会自动下载流式 Paraformer 中英 int8 模型、CT-Transformer 中英标点模型和个性词多语种语义模型（合计约 428 MiB）**，缓存在 `.modelcache/`。
之后构建走缓存。
在非 Windows 机器上只验证编译时，可加 `/p:SkipAsrModelDownload=true /p:EnableWindowsTargeting=true` 跳过模型下载。

本地模型 smoke test（Windows 真机）：

```powershell
.\scripts\smoke-local-asr.ps1
```

脚本会分块发送两个官方测试 WAV，要求录音过程中出现带标点 partial、停止后出现带标点 final，并检查中英混说输出；随后还会验证个性词语义判断的应改与不应改场景。

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
- 智能后处理：本地个性词纠错 + LLM 优化（OpenAI / Anthropic）
- 系统托盘常驻 + 录音状态浮窗 + 波形动画

## 系统要求

- Windows 10 1903+ (x64)
- .NET 8 Runtime
- 麦克风

## 模型管理

- **ASR 模型**：`sherpa-onnx-streaming-paraformer-bilingual-zh-en`（中英及中英混说，真流式）
- **标点模型**：`sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8`
- **个性词语义模型**：`distilbert-base-multilingual-cased-onnx-int8`（仅在拼音召回命中后按需加载）
- **路径搜索顺序**：用户目录 (`%LOCALAPPDATA%\GuGuTalk\models\`) 优先，然后是安装目录 (`<exe>\models\`)
- **ASR 文件**：`tokens.txt` + `encoder.int8.onnx`/`encoder.onnx` + `decoder.int8.onnx`/`decoder.onnx`
- **标点文件**：独立目录中的 `model.int8.onnx` 或 `model.onnx`
- **环境变量**：`GUGUTALK_LOCAL_ASR_MODEL_DIR`、`GUGUTALK_LOCAL_PUNCTUATION_MODEL_DIR` 与 `GUGUTALK_SEMANTIC_MODEL_DIR` 可分别覆盖对应目录
