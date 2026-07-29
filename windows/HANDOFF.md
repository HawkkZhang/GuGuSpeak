# GuGuTalk Windows — Handoff Notes

Snapshot at the point of switching machines. Branch: `fix/windows-build`.

## Update - 2026-07-22

- Local ASR now uses `OnlineRecognizer` with `sherpa-onnx-streaming-paraformer-bilingual-zh-en`. Every ordered audio chunk is decoded immediately and changed text emits `PartialTextUpdated` while recording.
- CT-Transformer zh-en int8 punctuation is applied to partials at a 250 ms cadence and forced once on final. English-adjacent full-width punctuation is normalized to ASCII.
- Provider endpoint detection remains disabled. Hold/toggle release controls the end; the stream receives 300 ms leading and 600 ms trailing padding before final drain.
- The build downloads four checksum-pinned files into two named directories under `bundled-models/`. `GuGuTalk.App.csproj` continues to collect all ONNX, tokens, and LICENSE files after Build and Publish, including on a clean first build.
- `scripts\smoke-local-asr.ps1` now feeds checksum-pinned official Paraformer WAVs in 100 ms chunks and verifies punctuated partials, punctuated final text, and mixed Chinese/English output.
- Windows x64 compilation, xUnit execution, live microphone smoke, publish, and MSI contents still require verification on a Windows host. Do not claim these from macOS-only checks.

The older SenseVoice sections below are retained as migration history and no longer describe the current local provider.

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

## Personal lexicon implementation - 2026-07-23

- Settings now stores only canonical personal terms. Existing `hotwords.json` replacement pairs migrate to canonical terms plus exact aliases.
- All three recognition providers pass final text through the same local correction chain: dynamic pronunciation retrieval followed, when needed, by ONNX masked-language-model scoring.
- The pinned semantic model is `onnx-community/distilbert-base-multilingual-cased-ONNX` revision `2e7303d946cfc9194a939e02efb46824eb440379`, int8 SHA-256 `4fa42d6f6e7d00dd734cdff3fd55b446dec3439de3f8c2e1d162e056969be343`.
- `scripts/smoke-local-asr.ps1` now checks that semantic resources reach app output, pins the sherpa-provided native ONNX Runtime hash, and verifies both `会议/回忆` contexts on a Windows machine.
- The model is lazy-loaded only for an ambiguous phonetic candidate; it never generates replacement text.
- The ONNX call sites were checked against the official Microsoft.ML.OnnxRuntime 1.24.4 source: tensor constructors, `Run`, `AsTensor`, and `ReadOnlySpan<int>.Length` match that API. `SessionOptions` is disposed after session construction.
- `org.k2fsa.sherpa.onnx.runtime.win-x64` 1.13.2 was inspected and its bundled native runtime reports ONNX Runtime 1.24.4, matching the managed semantic-scoring package.
- Core references `Microsoft.ML.OnnxRuntime.Managed`, not the full native package. A `win-x64` publish probe showed that referencing both full packages selected Microsoft's dynamically linked `onnxruntime.dll` and introduced undeclared `MSVCP140/VCRUNTIME140` prerequisites. Managed-only binding keeps sherpa's statically linked 1.24.4 DLL as the single native runtime.
- A temporary official .NET 8.0.423 SDK on Mac compiled the repository's actual C# personal-lexicon source with the product's managed-only ONNX binding plus sherpa native runtime and ran real inference successfully: `会议/回忆` changed only in the meeting context, and `咕咕 Talk` became `GuGuTalk`.
- A source-linked test project ran all 12 current Windows Core tests successfully, covering punctuation, phonetic retrieval, mixed-script terms, the long-term/short-transcript boundary, and legacy replacement migration.
- A second source-linked smoke exercised the actual `SmartPostProcessor.ProcessAsync` path with LLM disabled and produced the same three expected semantic results. This proves the corrector is in the provider-independent final-text pipeline, not only callable in isolation.
- Both PowerShell scripts parse cleanly with the official Microsoft.PowerShell.SDK 7.4.6 parser. `download-model.ps1` was also executed against a verified local cache and produced the complete ASR, punctuation, and semantic output tree with the pinned hashes.
- XAML, MSBuild, and WiX files are well-formed XML, and all three personal-term XAML event handlers resolve to methods in `SettingsWindow.xaml.cs`.
- A native Windows run is still required for WPF rendering, Windows DLL loading, full `dotnet build/test`, local ASR smoke, and MSI packaging. The Mac evidence above validates the shared managed code and model-resource path but does not replace those OS-specific checks.
- 2026-07-27: candidate retrieval was synchronized with macOS. It caches pronunciation signatures for the current small term list and supports Chinese readings, English/CamelCase, spelled letters, digits, common symbols, and mixed-script terms without term-specific rules or a built-in product dictionary.
- English pronunciation uses checksum-pinned `cmusphinx/cmudict` revision `74790861f652b15e4ac49015a90074ad62a27690`; `cmudict.dict` SHA-256 is `81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22` and its license SHA-256 is `bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a`. English ARPABET and Chinese pinyin map into the same phoneme space, while unknown English words use a lightweight G2P fallback. CMUdict is only a general pronunciation resource; configured user terms remain the sole replacement vocabulary.
- Spoken-token windows and weighted pronunciation edit distance replace canonical character-count windows. Overlapping accepted candidates choose the closest pronunciation first, preventing a wider semantic candidate from consuming adjacent words.
- High-confidence formatting-sensitive terms and anchored/long exact Chinese homophones honor the user's configured spelling; short ambiguous Chinese homophones retain ONNX context screening. An official temporary .NET 8.0.423 SDK on Mac compiled the repository C# sources and ran 12/12 source-linked Core tests. Real-resource semantic and `SmartPostProcessor.ProcessAsync` smokes also passed for `会议/回忆` context and mixed-script spelling. Native Windows WPF rendering, Windows DLL loading, full solution build/test, local microphone smoke, and MSI packaging still require a Windows host.

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

First build downloads the streaming Paraformer and CT-Transformer punctuation files (about 298 MiB total)
into `windows/.modelcache/` and copies verified files into `windows/src/GuGuTalk.LocalAsr/bundled-models/`.
`download-model.ps1` is idempotent; re-run if download fails.

## Architecture notes worth carrying forward

- `sherpa-onnx` native recognizers should be treated as single-threaded
  from managed code. Current Paraformer and punctuation calls are serialized behind
  `_recognizerLock` in `SherpaOnnxProvider`. Don't relax this.
- The Paraformer recognizer and punctuation model are loaded at app start via `Prewarm()` and
  reused across hotkey presses. Only `OnlineStream` is recreated per session. Loading models per session re-introduces the
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
| Bundled models | `windows\src\GuGuTalk.LocalAsr\bundled-models\` |
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
