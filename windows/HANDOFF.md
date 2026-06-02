# GuGuTalk Windows — Handoff Notes

Snapshot at the point of switching machines. Branch: `fix/windows-build`.

## Update - 2026-06-01

The local Windows ASR path now targets SenseVoice, superseding the older 14M/Zipformer notes below.

- Bundled model: `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`
- Build download: GitHub `asr-models` archive of the same name (~155MB archive, ~240MB extracted), extracted to `src/GuGuTalk.LocalAsr/bundled-models/`
- Runtime lookup: `%LOCALAPPDATA%\GuGuTalk\models\` first, then `<exe>\models\`
- Expected files: `tokens.txt` plus `model.int8.onnx` (preferred) or `model.onnx`
- Provider: `SherpaOnnxProvider` now uses `OfflineRecognizer` + `ModelConfig.SenseVoice`; it buffers PCM during hold-to-talk and decodes once in `FinishAudioAsync`
- SenseVoice ITN is enabled, so punctuation/normalization should come from the model before GuGuTalk post-processing
- `ModelConfig.SenseVoice.Language = "auto"` is set for Chinese/English/mixed-language use.
- `SkipAsrModelDownload=true` can be passed for non-Windows cross-compilation checks; normal Windows builds still download the bundled model.
- Windows smoke helper: `scripts\smoke-local-asr.ps1` builds the app, points `GUGUTALK_LOCAL_ASR_MODEL_DIR` at the bundled model, then decodes bundled `zh.wav` and `en.wav` through `SherpaOnnxProvider`.

Verification from macOS cross-targeting:
- `dotnet build src/GuGuTalk.LocalAsr/GuGuTalk.LocalAsr.csproj -m:1 /p:EnableWindowsTargeting=true /p:SkipAsrModelDownload=true` passed.
- `dotnet build src/GuGuTalk.App/GuGuTalk.App.csproj -m:1 /p:EnableWindowsTargeting=true /p:SkipAsrModelDownload=true` passed and produced `bin/Debug/net8.0-windows/win-x64/GuGuTalk.App.dll`.
- A C# sherpa-onnx smoke test with the same `OfflineRecognizerConfig` decoded bundled `zh.wav` and `en.wav` successfully on macOS. The actual Windows native DLL path still needs a Windows machine for live microphone testing.

## Legacy status before the SenseVoice switch

The following notes describe the previous 14M/Zipformer debugging state. Keep them for insertion-path context, but do not treat the model details as current.

- Build is clean. `dotnet build src/GuGuTalk.App/GuGuTalk.App.csproj`
  produces a working app at
  `src/GuGuTalk.App/bin/Debug/net8.0-windows/win-x64/GuGuTalk.App.exe`.
- Audio capture works. Debug WAVs at
  `%LOCALAPPDATA%\GuGuTalk\debug\session-*.wav` contain clear speech.
- Local ASR works. The debug WAV from the last live test decodes to
  "然后那效果好了好了好了测试一下全部的效果" through a standalone
  sherpa-onnx harness using the same model + same C# binding.
- **The bubble shows the recognised text but it does NOT reach the
  cursor.** This is the open issue the next machine should pick up.

## Legacy fixes from the previous 14M/Zipformer path

### 1. Historical: reverted to the 14M model

`src/GuGuTalk.LocalAsr/GuGuTalk.LocalAsr.csproj` ModelName is now
`sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`.

Why: the previously-wired
`sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30` model returned
empty strings for *every* input through `org.k2fsa.sherpa.onnx 1.10.30`
C# binding — including its own bundled `test_wavs/0.wav`. The 14M model
decodes our captured audio cleanly. Treat this as a model-vs-binding
incompatibility, not a code bug. If you want to try the 2025-06-30
model again later, also bump the sherpa-onnx package.

### 2. Disabled streaming endpointing inside SherpaOnnxProvider

`src/GuGuTalk.LocalAsr/SherpaOnnxProvider.cs` no longer calls
`IsEndpoint()` / `Reset()` mid-utterance. `EnableEndpoint = 0` in the
recognizer config.

Why: hold-to-talk is the user's signal of end-of-utterance. With
endpointing on, `Rule2MinTrailingSilence = 1.2s` would fire between
syllables and `Reset()` wiped the partial text the model had already
produced — `GetResult` then returned empty even though decoding had
been working seconds earlier. Don't bring this back unless you also
move to a continuous-transcription UX.

### 3. Encoder warmup with 0.5s leading silence

`SherpaOnnxProvider.StartSessionAsync` now feeds 0.5s of zeros into the
stream right after `CreateStream()`. Streaming Zipformer's deepest
layer needs ~128 frames (1.28s) of left context before its outputs are
reliable; without warmup the first ~0.3s of real audio is processed
with an empty context window and the leading syllables drop.

## Open issue: text insertion does not reach the cursor

Symptom: speak → release hotkey → bubble shows
"然后那效果好了好了好了测试一下全部的效果" → nothing arrives at the
cursor in the foreground app.

What the orchestrator does on a successful recognition:
`RecognitionOrchestrator.InsertFinalText` calls
`TextInsertionService.Insert`, which tries Clipboard → UIAutomation →
SendInput in that order. The clipboard path sets clipboard, sleeps
50 ms, then sends Ctrl+V via `SendInput`.

The most likely culprit, and the one **already partially attempted**:
`OverlayWindow` was a normal WPF Window. `Show()` activates it,
foreground shifts to our own overlay, and Ctrl+V lands in the overlay
(which has no editable surface). Two changes already made on this
machine:
- `OverlayWindow.xaml`: added `ShowActivated="False"`,
  `Focusable="False"`.
- `OverlayWindow.xaml.cs`: stamped `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`
  on the HWND in `OnSourceInitialized` via P/Invoke.

User reported these did not fix the symptom. So either:

- (a) `WS_EX_NOACTIVATE` is being applied too late — the first `Show()`
  may have already activated the window before `OnSourceInitialized`
  ran. Confirm by checking `GetForegroundWindow()` *during* the paste
  in `TextInsertionService.TryClipboard`. If it's pointing at the
  overlay, that's the bug.
- (b) The clipboard path succeeds in setting the clipboard but the
  paste target window has lost focus for an unrelated reason
  (focus-stealing by another tray app, anti-focus protection on the
  target, e.g. WeChat). Watch for `processName` in the log line
  `开始插入文本，目标: ... (Process)，长度: N` and try inserting into
  Notepad first to isolate.
- (c) Clipboard write succeeded but the saved-and-restored clipboard
  text squashed our paste before Ctrl+V completed. The current code
  restores the original clipboard 150 ms after Ctrl+V — should be
  enough but worth tracing.

What I'd try first on the next machine:
1. Reproduce in Notepad. If it works in Notepad and not WeChat, the
   issue is target-app-specific (the WeChat code path in
   `TextInsertionService` exists for exactly this reason).
2. Add a temporary log line at the top of `TryClipboard`:
   `Logger.Information("FG before paste: {HWnd:X} {Title}", ...)` using
   `NativeMethods.GetForegroundWindowInfo()`. If it logs "GuGuTalk
   Overlay", the focus fix didn't take.
3. If it's the focus issue: move the `WS_EX_NOACTIVATE` stamp earlier
   (before the first `Show()`, e.g. in `OnSourceInitialized` *and* set
   it imperatively the first time `IsPreviewVisible` flips to true).
   Or take the more forceful route: capture the foreground HWND at
   hotkey-press time and `SetForegroundWindow()` back to it right
   before pasting.
4. If the saved/restored clipboard is the problem, drop the restore
   altogether — most users don't care if the recognised text is left
   on the clipboard.

## Build environment on the next machine

The .NET 8 SDK is the only hard requirement. Last machine had it at
`D:\dotnet`. Install path doesn't matter as long as `dotnet.exe` is on
PATH and `DOTNET_ROOT` points at it.

```powershell
# one-time
winget install Microsoft.DotNet.SDK.8     # or dotnet-install.ps1 to D:\dotnet
git clone --filter=blob:none --no-checkout https://github.com/HawkkZhang/GuGuTalk
cd GuGuTalk
git sparse-checkout init --cone
git sparse-checkout set windows
git checkout fix/windows-build
```

```powershell
# build the app (debug)
cd windows
dotnet build src/GuGuTalk.App/GuGuTalk.App.csproj -m:1
# -m:1 is required: WPF's parallel build sometimes hits XAML lock
# contention on a clean cache.

# run from build output
src\GuGuTalk.App\bin\Debug\net8.0-windows\win-x64\GuGuTalk.App.exe

# build the MSI (self-contained)
dotnet publish src/GuGuTalk.App/GuGuTalk.App.csproj -c Release -r win-x64 --self-contained true
dotnet build installer/GuGuTalk.Installer.wixproj -c Release
# MSI lands at installer/bin/Release/GuGuTalk.Installer.msi (~178MB)
```

First build downloads the SenseVoice model
(`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2`, ~155MB archive / ~240MB extracted)
into `windows/.modelcache/` and extracts it into
`windows/src/GuGuTalk.LocalAsr/bundled-models/`.
`download-model.ps1` is idempotent; re-run if download fails.

## Architecture notes worth carrying forward

- `sherpa-onnx` native recognizers should be treated as single-threaded
  from managed code. Current SenseVoice calls are serialized behind
  `_recognizerLock` in `SherpaOnnxProvider`. Don't relax this.
- The SenseVoice recognizer is loaded at app start via `Prewarm()` and
  reused across hotkey presses. Loading per session re-introduces the
  keyboard-hook block.
- Audio chunks must reach the recognizer in order. The original
  per-chunk `Task.Run` dispatch reordered chunks across threadpool
  threads and produced garbage transcripts. The single-consumer
  `Channel<AudioChunk>` + dispatcher loop in `AudioCaptureEngine` is
  load-bearing.
- Resamplers in NAudio are stateful. Building a fresh
  `MediaFoundationResampler` per `DataAvailable` callback throws away
  filter state between chunks and audibly distorts the output. The
  current chain (`BufferedWaveProvider → StereoToMono → WdlResampler`)
  is built once per `StartCapture` and reused.
- AGC is software-side. Built-in mic arrays without driver AGC produce
  raw streams that peak around 0.04 (~4% of full scale) at normal
  speaking volume. `AudioCaptureEngine` runs a rolling-peak adaptive
  gain (1×–30×) with a tanh limiter so a static multiplier doesn't
  clip louder mics into "robot voice".
- WiX 5 with `<Files Include="$(PublishDir)**" />` is the supported
  way to harvest a self-contained publish dir. Do not bring back
  `heat.exe` — it was deprecated and produced the `WIX0094`
  ComponentGroup-not-found failures.
- The MSI uses `Codepage="936"` so CJK strings in the manifest don't
  trip `WIX0311`.

## Useful paths

| What | Where |
| --- | --- |
| User settings | `%APPDATA%\GuGuTalk\settings.json` |
| Logs | `%LOCALAPPDATA%\GuGuTalk\logs\gugutalk-*.log` |
| Per-session debug WAV | `%LOCALAPPDATA%\GuGuTalk\debug\session-*.wav` |
| Bundled model | `windows\src\GuGuTalk.LocalAsr\bundled-models\sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17\` |
| Model download cache | `windows\.modelcache\` |
| Built MSI | `windows\installer\bin\Release\GuGuTalk.Installer.msi` |

## Quick reproduction checklist

1. Build app, launch from
   `src\GuGuTalk.App\bin\Debug\net8.0-windows\win-x64\GuGuTalk.App.exe`.
2. Open Notepad, focus the document.
3. Hold Ctrl+\` , say a sentence in Mandarin, release.
4. Bubble in the bottom-right shows the recognised text within ~1s.
5. **Expected**: text appears in Notepad at the cursor.
6. **Current observed**: text does not appear in Notepad — this is the
   bug to fix.
7. Inspect the latest log at
   `%LOCALAPPDATA%\GuGuTalk\logs\gugutalk-YYYYMMDD.log`. Look for the
   `开始插入文本，目标: ... (Process)` line — that tells you what
   `GetForegroundWindow` returned at insertion time.
