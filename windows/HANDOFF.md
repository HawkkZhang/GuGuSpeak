# GuGuTalk Windows — Handoff Notes

Snapshot of the in-flight Windows port at the point of switching machines.
This doc lives next to the Windows source tree because everything in here
is Windows-specific; the macOS code is not affected.

## Where things stand

- Branch: `fix/windows-build` — open as PR #1.
- Compiles and produces a self-contained MSI on a clean machine with only
  the .NET 8 SDK installed. No .NET runtime install required at the user
  end.
- App launches, tray icon appears, settings window opens, hotkey overlay
  appears, recognizer model loads in the background.
- **Voice recognition is not yet known to work end-to-end on real
  hardware.** See "Open issue: silent capture" below — last test on the
  dev machine showed `avgLevel ≈ 0` from the built-in mic and the
  diagnostic stalled at the OS layer.

## Build environment on the next machine

The .NET 8 SDK is the only hard requirement. Last machine had it at
`D:\dotnet` to keep `C:` free; install path does not matter as long as
`dotnet.exe` is on PATH and `DOTNET_ROOT` points at it.

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
# -m:1 is required: WPF's parallel build sometimes hits XAML lock contention
# on a clean cache.

# build the MSI (self-contained)
dotnet publish src/GuGuTalk.App/GuGuTalk.App.csproj -c Release -r win-x64 --self-contained true
dotnet build installer/GuGuTalk.Installer.wixproj -c Release
# MSI lands at installer/bin/Release/GuGuTalk.Installer.msi (~178MB)
```

First build downloads the sherpa-onnx model
(`sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30.tar.bz2`,
~160MB) into `windows/.modelcache/` and extracts it into
`windows/src/GuGuTalk.LocalAsr/bundled-models/`. If the GitHub
release download fails, retry — `download-model.ps1` is idempotent.

## Open issue: silent capture

Symptom: pressing the hotkey shows the overlay and the model accepts
chunks, but the per-chunk RMS audio level logged by SherpaOnnxProvider
is ≈ `0.0016` (effectively noise floor). Transcript stays empty.

What was already ruled out:
- Wrong recognizer / wrong language — the same model transcribes the
  bundled debug WAVs from a quiet desk fine when fed back through
  sherpa-onnx-cli.
- Resampler corruption — fixed by switching to a stateful
  `BufferedWaveProvider → ToSampleProvider → WdlResampler` chain that is
  built once per session (see `AudioCaptureEngine.StartCapture`).
- Software gain clipping — the 6× pre-amp was producing the "robot
  voice" we saw in early debug WAVs; it has been removed (now 1×).
- Wrong device picked — `PickCaptureDevice` now prefers the built-in mic
  array over Virtual Audio Cable / Bluetooth HFP. Last log showed it
  correctly selected the laptop's `Realtek` array.

What is still suspect (in rough priority order):
1. **Windows microphone permission for desktop apps.** Settings → Privacy
   → Microphone → "Let desktop apps access your microphone". A clean
   Windows install can have this off and WASAPI will happily hand back a
   silent stream with no error.
2. **Another app holding the mic in exclusive mode** (Teams, Zoom, OBS).
   `WasapiCapture` opens shared mode by design, but some drivers lock
   anyway.
3. **Bluetooth HFP profile lock.** Even after we exclude the
   WH-1000XM6 from selection, Windows sometimes leaves the entire audio
   subsystem in HFP and the array mic returns silence until you force
   A2DP via Settings → Bluetooth → device → Audio profile.
4. **Driver-level mute.** Sound control panel → Recording →
   Realtek Mic → Properties → Levels: confirm not muted, slider not at
   0, "Microphone Boost" non-zero.

How to debug on the next machine:

```text
1. Open Windows Voice Recorder (or any system mic test). If THAT shows a
   flat line, the problem is environmental — fix the OS first.
2. Run the app, press the hotkey, speak, release.
3. Inspect %LOCALAPPDATA%\GuGuTalk\debug\session-*.wav — that file
   contains exactly the audio that reached the recognizer. If it's
   silent, the capture pipeline is the problem. If it has clear speech
   but recognition still fails, sherpa-onnx is the problem.
4. Logs are at %LOCALAPPDATA%\GuGuTalk\logs\gugutalk-YYYYMMDD.log.
   Look for:
     - "Selected built-in mic: ..."  (PickCaptureDevice)
     - "Audio capture started. Source format: ..."
     - "Finish: chunks=N avgLevel=X.XXXX"
   avgLevel < 0.005 means silence reached the recognizer; avgLevel > 0.05
   means real audio is flowing and the bug is downstream.
```

## Architecture notes worth carrying forward

- `sherpa-onnx` `OnlineRecognizer` / `OnlineStream` are NOT thread-safe.
  Concurrent calls produce SEH `0xe0434352` deep in `GetResult`. All
  native calls are serialized behind `_streamLock` in
  `SherpaOnnxProvider`. Don't relax this.
- The recognizer takes ~5–10s to load the zh-int8 model. It is loaded
  once at app start via `Prewarm()` and reused across hotkey presses.
  Re-loading per session brought back the keyboard-hook block.
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
- WiX 5 with `<Files Include="$(PublishDir)**" />` is the supported way
  to harvest a self-contained publish dir. Do not bring back `heat.exe` —
  it was deprecated and produced the `WIX0094` ComponentGroup-not-found
  failures.
- The MSI uses `Codepage="936"` so CJK strings in the manifest don't
  trip `WIX0311`.

## Useful paths

| What | Where |
| --- | --- |
| User settings | `%APPDATA%\GuGuTalk\settings.json` |
| Logs | `%LOCALAPPDATA%\GuGuTalk\logs\gugutalk-*.log` |
| Per-session debug WAV | `%LOCALAPPDATA%\GuGuTalk\debug\session-*.wav` |
| Bundled model | `windows\src\GuGuTalk.LocalAsr\bundled-models\sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30\` |
| Model download cache | `windows\.modelcache\` |
| Built MSI | `windows\installer\bin\Release\GuGuTalk.Installer.msi` |

## Next steps when you pick this back up

1. Get the OS-level mic test passing in Voice Recorder.
2. Reinstall the latest MSI (uninstall old build first via
   `Settings → Apps`).
3. Press hotkey, speak, release.
4. Check `session-*.wav` to confirm the audio actually arrived at the
   recognizer; check the latest log for `avgLevel`.
5. If audio is good but recognition is wrong: try the non-int8 variant
   of the model (drop `int8` from `<ModelName>` in
   `GuGuTalk.LocalAsr.csproj` — `FindFile` already prefers non-int8
   when both are present).
