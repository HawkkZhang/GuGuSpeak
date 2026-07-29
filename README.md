# GuGuTalk

一款跨平台语音输入工具，支持本地识别和云端识别，让语音输入更高效。

## 平台

| 平台 | 技术栈 | 目录 | 状态 |
|------|--------|------|------|
| macOS 15.5+ | Swift 6 + SwiftUI | [`macos/`](macos/) | 已发布 |
| Windows | C# + WPF (.NET 8) | [`windows/`](windows/) | 开发中 |

## 功能

- 多种识别引擎：本地真流式中英识别 / 豆包 / 千问
- 灵活热键：按住说话 + 切换模式
- 智能文字插入：自动适配目标应用
- 后处理：个性词（本地拼音召回 + 语义评分）+ LLM 优化 + 标点控制
- 系统常驻：菜单栏 (macOS) / 系统托盘 (Windows)

## 快速开始

### macOS

```bash
cd macos
xcodebuild -project DesktopVoiceInput.xcodeproj -scheme DesktopVoiceInput build
```

macOS 首次构建会下载 sherpa-onnx 运行库、流式 Paraformer 中英 int8 模型、CT-Transformer 中英标点模型和多语种个性词语义模型；模型会直接打进应用资源，安装后无需额外下载。

### Windows

```powershell
cd windows
dotnet build GuGuTalk.sln -c Release
dotnet run --project src/GuGuTalk.App
```

详细说明见各平台目录下的 README。

## 设计

- [PRODUCT.md](PRODUCT.md) — 产品定义
- [DESIGN.md](DESIGN.md) — 设计系统

## 给 AI 编码工具

如果你是 AI 编码工具（Claude Code / Codex / Copilot 等），先读：

- [AGENTS.md](AGENTS.md) — 仓库总规范（**必读**）
- [macos/AGENTS.md](macos/AGENTS.md) — Mac 专用规范
- [windows/AGENTS.md](windows/AGENTS.md) — Windows 专用规范

里面有目录结构、改动边界、commit 规范和协议同步规则。

## 开源协议

MIT License
