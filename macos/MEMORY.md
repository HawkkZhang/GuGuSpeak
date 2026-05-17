# Project Memory

## Historical Critical Permission Issues - 2026-05-07

**权限流程曾导致应用不可用。相关修复已经进入当前代码和打包流程；后续用户测试没有再确认同类权限阻塞。这里保留为历史风险和回归测试背景。**

### 严重问题

1. **语音识别权限申请导致闪退**
   - 症状：点击"立即申请"按钮后应用崩溃
   - 影响：无法完成权限配置流程
   - 位置：`PermissionCoordinator.refreshSpeechRecognition(prompt: true)`
   - 当前处理：权限请求显式在主线程发起，并在主线程恢复结果

2. **启动时错误弹出权限请求**
   - 症状：应用启动后立即弹出系统辅助功能权限对话框
   - 期望：应该先显示设置窗口，用户主动点击后才请求
   - 影响：用户体验混乱，不知道应该做什么
   - 当前处理：启动只做静默检查；全局热键监听仅在输入监控已授权时启动；缺权限时自动打开设置窗口

3. **权限检测不准确**
   - 症状：系统设置中已授权，应用仍显示"未授权"
   - 已定位：辅助功能/输入监控需要稳定签名和正确跳转；麦克风在 Hardened Runtime 下还必须具备 `com.apple.security.device.audio-input` entitlement
   - 当前处理：Release 构建使用本地稳定签名 `GuGuTalk Local Code Signing`；新增 `Config/DesktopVoiceInput.entitlements`；刷新检查统一走 AppModel，刷新权限后同步热键状态
   - 状态：后续用户测试基本恢复；仍作为权限回归风险保留

### 最近的修改（2026-05-07）

**打包和品牌**：
- 应用名改为 GuGuTalk
- 创建 DMG 安装包
- 添加应用图标和菜单栏图标
- 移除 `LSUIElement`，应用出现在 Launchpad

**权限系统修改**：
- 启用 Hardened Runtime（尝试修复权限检测）
- 启用代码签名（现为本地稳定证书 `GuGuTalk Local Code Signing`，不再依赖 ad-hoc）
- 添加 `Config/DesktopVoiceInput.entitlements`，包含麦克风音频输入 entitlement
- 首次启动会自动打开独立设置窗口；缺权限时直接进入“权限”页，避免新用户误以为菜单栏应用消失
- 添加"刷新检查"按钮
- 曾添加"我已授权，继续使用"按钮（已移除）

**已知问题根源**：
- 权限请求流程混乱
- 错误处理缺失
- UI 流程不清晰

详细问题记录见 `BUGS.md`

## Current Status

- DesktopVoiceInput is a macOS menu bar voice input app prototype.
- Local Apple Speech, Qwen realtime, and Doubao realtime integrations have all been implemented.
- The current stable checkpoint is tag `stable-2026-05-01`, commit `960f2b3`.
- The latest synced checkpoint is on `main`; use `git log --oneline -1` for the exact current commit.
- GitHub repository: `https://github.com/HawkkZhang/GuGuTalk`.
- Local development branch is currently `main`, tracking `origin/main`.
- Product name and GitHub repository are currently `GuGuTalk`; Xcode project and internal target names still include `DesktopVoiceInput`.
- Current UI direction is `Aqua Chick Companion`: theme colors are derived from the app icon, with icon-aqua as the main action/selection color and icon-orange only as a small warmth accent. The UI should use custom refined controls, system font, compact Mac utility structure, no gray glassmorphism, no neon/cyber styling.
- Dark mode should use aqua as a restrained accent, not a large luminous wash. Settings surfaces should stay low-saturation charcoal-teal, with selected controls clearly visible but not bright cyan.
- Recording overlay normal states should use one consistent icon-aqua theme surface between the initial waveform state and the live transcript state; avoid hidden square backgrounds, heavy shadows, and glass-like frames around the rounded shape.
- Chinese speech text should remove pause-induced spaces between Han characters and around Chinese punctuation while preserving normal English word spaces. This applies to Doubao partial/final text and final insertion post-processing.
- The punctuation mode labeled `去掉句尾句号` must only remove terminal period marks (`。`, `.`, `．`, `｡`). It must not remove question marks or exclamation marks returned by providers.
- Capture endpointing should be user-controlled. Hold-to-talk and toggle-to-talk sessions should end on the user's release/stop action, not on provider VAD silence detection.
- Recognition is single-session only, but async cleanup must be session-scoped: final-result timeout tasks, pending stops, and finish requests must not leak across sessions or terminate a later hold-to-talk recording.
- If the user manually triggers a new recording while previous recognition work is still active, the app should cancel the previous session/work first and then start the new session. This includes startup handshakes, active providers, audio capture, final timeout, stale provider events, and AI post-processing.
- Capture now starts microphone audio immediately after permissions pass, before cloud/local provider startup completes. Audio captured during provider startup is held in a bounded 4-second pre-roll buffer and flushed to the selected provider once ready, reducing dropped opening words and false "no speech heard" results.
- Orchestrator-level audio sends must also stay serialized. Pre-roll audio and live audio now enter a single `AudioSendQueue`, and `finishAudio()` waits for that queue to drain so the provider never receives an end frame before earlier captured audio.
- Local Apple Speech must not assume a fixed runtime audio format. Keep cloud PCM as `16k Int16`, but feed local recognition through `SFSpeechAudioBufferRecognitionRequest.nativeAudioFormat` and check `supportsOnDeviceRecognition` before requiring on-device recognition.
- The 300 ms tail-buffer delay after key release should keep accepting audio until capture is actually stopped; do not reintroduce a guard that drops chunks merely because finish has been requested.
- GuGuTalk must be usable inside its own text fields, including prompt and provider configuration fields. Shortcut recording should suspend global hotkeys only while recording a shortcut; do not block all insertion just because the foreground app is GuGuTalk.
- Doubao diagnostics intentionally log raw provider transcript text and normalized transcript text in Release builds while this issue is being verified. Each update is printed as `[DoubaoTranscript]` and also appended to `~/Library/Logs/GuGuTalk/doubao-transcripts.log`. Remove or gate these transcript-content logs before a privacy-sensitive public release.
- Doubao WebSocket sends must stay serialized. Audio tap chunks are produced from multiple async tasks, so the transport must prevent a finish frame from overtaking earlier audio frames; otherwise Doubao can report `last packet has been received already` and the app may fall back to unstable partial text.
- Doubao `bigmodel_async` with `result_type = "full"` should normally be treated as provider-owned full replacement text. However, real logs showed terminal final can occasionally drop a stable prefix that existed in the immediately previous partial/full update, such as previous `Gemini 之前还` followed by terminal raw `之前还挺好用的。`. The client now protects only this terminal-finish edge case with overlap-based prefix repair and logs `repairedFromPrevious` plus `emitted`.
- Text insertion still needs compatibility hardening. Clipboard paste dispatch cannot prove the target input field actually accepted the text; current mitigation extends pasteboard restore delay to `2.0s` and logs paste dispatch honestly instead of treating it as guaranteed insertion.
- WeChat (`com.tencent.xinWeChat` / `com.tencent.WeChat`) uses a per-app insertion strategy: Accessibility insertion -> targeted Unicode keyboard events -> clipboard paste fallback. Logs showed clipboard dispatch could report success without visible insertion in WeChat, so clipboard must remain the last resort there.
- Local DMG artifacts must be generated with `./scripts/package-dmg.sh` and stored only in `dist/dmg/`. Do not create new DMGs in the repo root, `Packages/`, Desktop, Downloads, or random temporary folders.

## Latest Synced State - 2026-05-11

These changes are synced to GitHub on `main`:

- GitHub repository name is `GuGuTalk`: `https://github.com/HawkkZhang/GuGuTalk`.
- App entry now uses a dedicated AppKit `NSWindow` settings/onboarding window, not SwiftUI `Settings {}` as the primary UI.
- App launch/reopen behavior:
  - missing required permissions -> open Permissions page
  - permissions ready -> open General/Home page
- Default hotkeys in code:
  - hold-to-talk -> `Fn`, enabled by default
  - toggle-to-talk -> `⌥ Space`, enabled by default
- Doubao streaming result handling currently uses `result_type = "full"` and treats provider `result.text` as the full replacement transcript for partial and final updates.
- Official Doubao `bigmodel_async` reference: `https://www.volcengine.com/docs/6561/1354869?lang=zh`. The relevant contract is `result_type = "full"` for full transcript refresh, while `single` is incremental and does not include previous segments.
- A previous `result_type = "single"` / `utterances[].definite` assembler approach was tried, then deliberately retired because client-side assembly can create duplicate or missing text when provider refresh semantics shift.
- `show_utterances = true` remains enabled for diagnostics and fallback parsing only. When `result.text` exists, it is the source of truth.
- Doubao terminal final has one conservative protection: if the terminal final drops a stable prefix seen in the previous update, `DoubaoTranscriptRepair` may repair that terminal-finish edge case using overlap matching.
- Occasional one-or-two-character repetitions are still a known verification target. Do not add broad local dedupe until `[DoubaoTranscript]` logs prove whether the raw provider `result.text` or local processing created the repetition.
- Documentation audit completed on 2026-05-10: README, DESIGN, CONTRIBUTING, BUGS, MEMORY, and HANDOFF have been aligned with the current implementation for macOS target, hotkeys, AppKit settings window, Doubao `result_type = "full"`, custom controls, local test coverage, and self-text-field insertion behavior.
- WeChat insertion now has a per-app stable path: Accessibility insertion first, targeted Unicode keyboard events second, clipboard paste only as the final fallback.
- Non-AI final recognition now actively schedules overlay dismissal after successful insertion instead of depending only on provider `sessionEnded`.
- Clipboard paste logging is intentionally conservative: it reports that paste was dispatched, not that the target field definitely accepted it.

## Latest Fixes - 2026-05-17

### macOS 15.7.3 local Apple Speech no-speech regression

- User clarified that the remaining "didn't hear speech" failure happens on macOS Sequoia 15.7.3 and uses the Mac local recognition mode; the current development machine does not reproduce it.
- This is separate from the Doubao/Qwen send-order issue. The likely weak point is Apple Speech local recognition compatibility.
- Evidence from Apple SDK headers:
  - `requiresOnDeviceRecognition` only applies if `SFSpeechRecognizer.supportsOnDeviceRecognition` is true.
  - `SFSpeechAudioBufferRecognitionRequest` exposes `nativeAudioFormat` and expects native/uncompressed audio buffers.
- The previous code forced `requiresOnDeviceRecognition = true` without checking `supportsOnDeviceRecognition`, and reused the cloud-oriented fixed `16k Int16` converted buffer as the Apple Speech `nativeBuffer`.
- On the current machine, `SFSpeechAudioBufferRecognitionRequest().nativeAudioFormat` is also `1 ch, 16000 Hz, Int16`, so the bug can be hidden locally. On macOS 15.7.3 or on machines with different language-resource state, that assumption may fail.
- Current code changes:
  - `AudioCaptureEngine` still produces `16k Int16 pcmData` for cloud providers, but now stores a copied microphone source buffer in `AudioChunk.nativeBuffer`.
  - `LocalSpeechProvider` checks `recognizer.supportsOnDeviceRecognition` before setting `requiresOnDeviceRecognition`.
  - `LocalSpeechProvider` converts local audio to the request's runtime `nativeAudioFormat` before appending it to Apple Speech.
  - Local Speech logs now include locale, on-device support, native request format, first audio chunk formats/durations/levels, and Apple error domain/code plus observed audio duration/level.
  - `SessionFailureInfo` now carries `isNoSpeech`; `RecognitionOrchestrator` only dismisses quietly for true no-speech. Non-no-speech local engine failures are surfaced as errors instead of being mislabeled as "too short".
- Verification:
  - `swift test` passed 22 tests.
  - Debug `xcodebuild` passed.
- Needs real retest on the macOS Sequoia 15.7.3 machine. If it still fails with audible input and `supportsOnDevice=true`, treat it as a system local-engine compatibility issue and recommend Doubao/Qwen fallback or repairing system dictation resources.

## Latest Fixes - 2026-05-16

### No-speech regression after faster startup capture

- User reported that after the startup-latency fix, voice input became effectively unusable and kept reporting that it did not hear speech.
- Evidence from system logs showed WebSocket write failure near session finish: `Socket is not connected`.
- Root cause: `RecognitionOrchestrator` could flush pre-roll audio and send live audio from separate async tasks, while `endCapture()` could call `finishAudio()` before all queued audio reached the provider.
- `RecognitionOrchestrator` now owns a single `AudioSendQueue`:
  - audio tap chunks are routed onto the main actor and queued, not sent directly by many tasks
  - startup pre-roll chunks are queued before live chunks
  - one send loop consumes the queue sequentially with the active provider
  - `endCapture()` stops capture, waits for late tap deliveries plus queue drain, then sends `finishAudio()`
- If the send queue cannot drain within a bounded timeout, the app reports an audio-send timeout instead of sending finish out of order and surfacing a misleading no-speech result.
- Added `AudioSendQueue` unit coverage for order and duration tracking.
- Verification:
  - `swift test` passed 22 tests.
  - Debug `xcodebuild` passed.
  - Debug app `open` still did not leave a running process, matching prior local Debug launch fragility.
  - Release `xcodebuild` passed.
  - Latest Release app launched from `/tmp/DesktopVoiceInputReleaseDerivedData/Build/Products/Release/DesktopVoiceInput.app` with PID `60162`.
- This still needs real hold-to-talk retesting with short Doubao phrases.

## Latest Fixes - 2026-05-14

### Shortcut starts but app reports no speech heard

- User reported that pressing the voice-input shortcut can still show a "no speech heard / no content recognized" style message.
- Root cause found in `RecognitionOrchestrator.beginCapture()`: the app waited for provider startup before starting `AudioCaptureEngine`. With Doubao/Qwen WebSocket startup, speech that began immediately after the key press could be lost before capture actually started.
- `RecognitionOrchestrator` now starts audio capture immediately after permission/config checks and before `startProviderChain`.
- Audio chunks captured while the provider is starting are stored in a bounded 4-second `AudioPrerollBuffer`.
- After the provider becomes active, the pre-roll buffer is flushed in order before normal live audio routing resumes.
- The release tail behavior was also corrected: the 300 ms delay before stopping audio capture now has a chance to deliver final chunks instead of dropping them only because `isFinishRequested` was already true.
- Added tests for `AudioPrerollBuffer` duration trimming and drain order.
- Verification:
  - `swift test` passed 21 tests.
  - Debug `xcodebuild` passed.
  - Debug app `open` was attempted, but no `DesktopVoiceInput` process remained running afterward, consistent with prior local Debug launch fragility around Xcode debug dylib signing. Use Release launch for real manual testing if Debug still exits immediately.
  - Release `xcodebuild` passed.
  - Latest Release app launched from `/tmp/DesktopVoiceInputReleaseDerivedData/Build/Products/Release/DesktopVoiceInput.app` with PID `4202`.

## Latest Fixes - 2026-05-11

### WeChat insertion and stuck overlay mitigation

- User reported that in WeChat the overlay showed recognized final text, but the text did not appear in the WeChat input field and the overlay did not disappear.
- Logs showed the recognition/final path completed and insertion targeted `微信`; the weak point was still the target-specific insertion path and overlay dismissal after successful final handling.
- Current code changes:
  - `TextInsertionService` logs target bundle ID.
  - WeChat bundle IDs `com.tencent.xinWeChat` and `com.tencent.WeChat` now use Accessibility insertion first.
  - If WeChat Accessibility insertion fails, the app sends targeted Unicode keyboard events to the WeChat process.
  - Clipboard paste remains only the final fallback for WeChat.
  - Non-AI final handling now schedules preview dismissal `0.8s` after a successful insertion flow.
  - `scheduleDismiss` now logs when dismissal is scheduled and when it actually fires.
- Verification:
  - Debug `xcodebuild` passed.
  - Release `xcodebuild` passed.
  - `swift test` passed 19 tests.
  - Latest Release app launched from `/tmp/DesktopVoiceInputReleaseDerivedData/Build/Products/Release/DesktopVoiceInput.app` with PID `86388`.
- Important handoff note: this still needs real WeChat retest. If WeChat still fails, inspect TextInsertion logs for whether Accessibility failed, whether `发送 Unicode 键入事件` was emitted, and whether it eventually fell back to clipboard.

### Recognition succeeds but final text sometimes does not appear in the target app

- User reported a session where the overlay showed recognized text, Doubao returned final text, but no text appeared in the foreground input field.
- Evidence confirmed recognition was not the failing layer: `~/Library/Logs/GuGuTalk/doubao-transcripts.log` contained final text for the session.
- System logs showed `TextInsertionService` targeted `Codex` and used the clipboard paste path.
- Root risk: the clipboard paste path can only confirm that GuGuTalk placed text on the pasteboard and sent Cmd+V. macOS does not provide a direct confirmation that the target input field accepted the paste.
- Previous pasteboard restore delay was `0.6s`, which may be too short for Electron/Web/rich-text editors that read pasteboard data asynchronously.
- Current code changes:
  - `TextInsertionService.clipboardPasteInsertion` restores the previous pasteboard after `2.0s` instead of `0.6s`.
  - TextInsertion logs now say the paste command was dispatched and cannot be directly verified, instead of claiming guaranteed paste success.
- Verification:
  - Debug `xcodebuild` passed.
  - Release `xcodebuild` passed.
  - `swift test` passed 19 tests.
  - `./scripts/package-dmg.sh` completed and verified the DMG checksum.
- Latest packaged DMG:
  - `dist/dmg/GuGuTalk-20260511-2230-7747489.dmg`
  - `dist/dmg/GuGuTalk-20260511-2230-7747489.dmg.sha256`
- Important handoff note: the DMG filename still uses the older committed short hash `7747489`; rebuild a fresh DMG after this commit if a distributable artifact is needed.

## Historical Fixes - 2026-05-10

### Doubao repeated-word investigation and send ordering

- Current Doubao transcript handling uses `result_type = "full"` and replaces the preview/final candidate with provider `result.text`; it does not concatenate partial results.
- User's local settings showed `postProcessingEnabled = 0`, so repeated words such as “用用” are not caused by LLM post-processing.
- Recent logs showed Doubao protocol errors like `last packet has been received already`, consistent with a finish frame overtaking queued audio frames.
- `RealtimeWebSocketTransport` now serializes all outgoing WebSocket sends with an async lock so audio frames and finish frames preserve send order.
- Doubao transcript snapshots now log every update, not just terminal/finish. The diagnostic includes `previous`, `raw`, `normalized`, `resultTexts`, `utterances`, and `lostPreviousPrefix`; it is mirrored to Xcode console and `~/Library/Logs/GuGuTalk/doubao-transcripts.log`.
- Real logs confirmed a separate terminal-final issue: a partial update contained `Gemini 之前还`, but the terminal raw result became `之前还挺好用的。`, causing the final inserted text to lose the opening `Gemini`. `DoubaoTranscriptRepair` now only repairs terminal final text when the previous update and terminal text share a meaningful suffix/prefix overlap; logs include `repairedFromPrevious` and `emitted` to prove what was actually sent to the app.
- This is specifically to verify reports where an early term such as “Gemini” appears in partial preview but disappears from later/final output.
- Verified locally: `swift test` passed 19 tests, Debug `xcodebuild` passed, Release `xcodebuild` passed, and latest Release app launched from `/tmp/DesktopVoiceInputReleaseDerivedData/Build/Products/Release/DesktopVoiceInput.app` with PID `36210`.

### Manual restart cancels previous recognition work

- Quick user restarts are now intentional: a new hold-to-talk or toggle-to-talk trigger cancels any unfinished previous recognition work before starting the new session.
- `RecognitionOrchestrator` tracks both `startingProvider` and `activeProvider`, so a provider that is still handshaking can be canceled during a restart.
- Provider events, audio sends, final-result timeouts, and AI post-processing are scoped to `sessionGeneration`, so stale async results from an older session cannot update or end a newer recording.
- Verified locally: `swift test` passed 16 tests, Debug `xcodebuild` passed, Release `xcodebuild` passed, and latest Release app launched from `/tmp/DesktopVoiceInputReleaseDerivedData/Build/Products/Release/DesktopVoiceInput.app` with PID `27079`.

### Hold-to-talk recording cut off by stale final timeout

- Evidence from logs showed the hotkey release happened after the cutoff, so this was not a key-up detection issue.
- `RecognitionOrchestrator` logged `Session timed out waiting for final result` during a later recording, meaning an old final-result timeout task was force-ending the new session.
- `RecognitionOrchestrator` now increments a `sessionGeneration` for every capture and only lets a timeout finish the generation that created it.
- Starting, quiet dismissal, failure, normal finish, and force finish now cancel stale timeout state.
- End handling is now explicitly guarded: release before provider readiness becomes a pending stop; release during recording starts finishing; duplicate finish calls are ignored.
- If the provider already ended during the tail-buffer delay or `finishAudio()`, no new final timeout is scheduled.
- Overlay prompt bubbles now share the normal aqua recording surface; system prompts are differentiated by text style instead of a separate bubble color.
- Verified locally: Debug `xcodebuild` passed, Release `xcodebuild` passed, `swift test` passed 16 tests, latest Release app launched from `/tmp/DesktopVoiceInputReleaseDerivedData/Build/Products/Release/DesktopVoiceInput.app` with PID `11291`.

## Not Yet Fully Implemented

### Hotkeys

- The new dual-hotkey system still needs stabilization.
- There are now two trigger modes:
  - hold-to-talk
  - press-once-to-start, press-again-to-stop
- Hotkey recording should never trigger live voice input while recording.
- Single-key hotkeys are allowed, but conflict handling still needs more polish.
- System-level reserved shortcuts cannot be fully intercepted.
- App-level shortcut conflicts can often be intercepted, but detection and user guidance are still incomplete.

### Safety / Anti-Footgun

- GuGuTalk should allow voice input inside its own editable text fields, including prompts and provider configuration fields.
- Do not insert into GuGuTalk itself when the focused element is not editable, and keep global hotkeys suspended while recording shortcuts.
- Add stronger guards so recording / settings editing / text insertion do not interfere with one another.
- Validate cloud provider settings earlier, before runtime, to reduce handshake-time failures.

### Recognition UX

- Make it clearer which provider is actually being used right now:
  - local
  - Doubao
  - Qwen
- Make fallback reasons and provider switching reasons visible to the user.
- Improve failure messages so they are easier for non-technical users to understand.
- Doubao streaming handling was re-reviewed against the `bigmodel_async` API:
  - request uses `result_type = "full"` so the provider returns the full current transcript
  - preview and final text should directly replace with provider `result.text`
  - request keeps `show_utterances = true` for diagnostics and fallback parsing only
  - client-side utterance assembly / dedupe is intentionally avoided because it can create repeated words
  - `result` parsing supports both object and list shapes
- Continue validating Doubao with real speech logs. If duplicates still appear, inspect the raw provider `result.text` before adding any local correction. Debug builds now log `raw` vs `normalized` transcript text when Chinese pause-space cleanup changes the returned text.

### Text Quality

- `TranscriptPostProcessor` is still minimal.
- It currently only does:
  - whitespace cleanup, including Chinese pause-space removal
  - limited Chinese punctuation cleanup
  - terminal punctuation append
- Still missing:
  - better Chinese punctuation restoration
  - number formatting
  - mixed Chinese / English formatting
  - smarter sentence segmentation

### Stability / Compatibility

- Settings/onboarding now uses a dedicated AppKit settings window for app launch, menu bar Settings, and permission guidance.
- Continue verifying launch/reopen behavior on packaged DMGs, different macOS versions, and local signing/Gatekeeper states.
- More compatibility testing is needed across common macOS apps and input fields.
- Text insertion compatibility is a top-priority product risk. The app must not merely "insert text"; it needs reliable per-target insertion behavior across native text fields, browser editors, rich text editors, Electron apps, and unusual web inputs.
- Browser / web rich-text editors such as Gemini, ChatGPT, Notion, Google Docs, Feishu, and Slack should generally prefer paste-style insertion because Accessibility `AXValue` can expose placeholder / hint / hidden editor text as if it were real content.
- Native macOS text fields may still use Accessibility insertion when safe, but the app should detect placeholder / hint values and fall back before merging them into dictated text.
- Future insertion architecture should support per-app strategy memory, full pasteboard preservation, insertion diagnostics, and a user-facing compatibility mode.
- Need more verification for:
  - repeated sessions
  - permission revocation mid-use
  - settings window interactions
  - self-focus / self-insertion edge cases

### Testing

- Test coverage is still very light.
- Current tests mostly cover transcript post-processing, Doubao transcript parsing, and terminal-final prefix repair.
- Missing automated tests for:
  - hotkey state transitions
  - provider fallback flow
  - text insertion safeguards
  - settings validation

### Release Readiness

- Local development signing exists via `GuGuTalk Local Code Signing`, but production Developer ID signing and notarization are not set up yet.
- Local DMG packaging is set up through `./scripts/package-dmg.sh` and writes artifacts to `dist/dmg/`.
- Public release distribution, notarization, and update delivery are not set up yet.
- Update mechanism is not implemented.

### 智能后处理（Phase 2 & 3 未完成）

已完成：
- 标点处理独立设置（规则层，不依赖 LLM）
- LLM 后处理基础能力（纠错、正式化、列表预设）
- 用户可编辑每个预设的 Prompt
- LLM 客户端支持 OpenAI 兼容 + Anthropic 双协议
- BYOK 配置（endpoint / API key / model）

未完成：
- Per-app 差异化规则（根据目标应用选择不同处理管线）
- Agent 对话功能：用户用自然语言描述后处理需求，Agent 自动判断用规则层还是 LLM 层，输出结构化配置变更
- Agent 对话 UI（独立聊天窗口）
- Agent 对话历史持久化
- 自定义 Prompt 模板管理（用户自建模板，不限于预设）

设计文档：`.claude/plans/jolly-spinning-whistle.md`

## Immediate Priorities

1. Verify Doubao occasional repeated-character reports with `[DoubaoTranscript]` raw/normalized/emitted logs before changing result handling again.
2. Continue testing the dedicated settings/onboarding window from Finder, Launchpad, `/Applications`, and menu bar Settings.
3. Add clearer validation and error handling for Doubao / Qwen configuration.
4. Improve provider visibility and fallback messaging.
5. Expand tests around hotkeys, insertion, and provider switching.
6. Implement Agent 对话 for smart post-processing configuration.
7. Implement per-app post-processing rules.
