using System.Threading.Channels;
using GuGuTalk.Core.Models;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NAudio.Dsp;
using Serilog;

namespace GuGuTalk.Core.Services;

public sealed class AudioCaptureEngine : IAudioCaptureEngine, IDisposable
{
    private static readonly ILogger Logger = Log.ForContext<AudioCaptureEngine>();

    // sherpa-onnx expects 16 kHz mono int16 PCM.
    private const int TargetSampleRate = 16000;

    // Adaptive gain (soft AGC). Some Windows mic configurations — notably
    // built-in arrays without driver-side AGC, like 麦克风阵列 (英特尔® 智音技术) —
    // hand WASAPI a raw stream that peaks around 0.04 (~4% of full scale)
    // even at normal speaking volume. Apps that go through SAPI / Windows
    // Speech get an AGC-processed feed and don't notice; we read the raw
    // shared-mode stream and have to do the gain ourselves. A static
    // multiplier doesn't work — 6x clipped a normal mic into "robot voice"
    // last quarter — so we track the recent peak and adjust dynamically.
    private const float AgcTargetPeak = 0.5f;
    private const float AgcMinGain = 1.0f;
    private const float AgcMaxGain = 30.0f;
    // How fast gain can change between chunks. Cap step keeps voice from
    // pumping when a loud syllable hits a previously quiet window.
    private const float AgcMaxStepUp = 1.15f;
    private const float AgcMaxStepDown = 0.85f;
    // How long the rolling peak window is. Long enough to span normal
    // pauses between words; short enough to react when the user gets
    // closer to the mic.
    private const int AgcWindowMillis = 1500;
    private float _agcGain = 1.0f;
    private readonly Queue<(DateTime At, float Peak)> _agcPeakHistory = new();

    private WasapiCapture? _capture;
    private WaveFormat? _captureFormat;
    private string? _currentDeviceName;

    public string? CurrentDeviceName => _currentDeviceName;

    // Stateful resampling chain: BufferedWaveProvider <- IEEE float source
    // -> ToSampleProvider -> StereoToMono -> WdlResampler -> 16 kHz mono float.
    // Reusing the chain across chunks preserves resampler state and avoids
    // the discontinuities that broke recognition with MediaFoundationResampler.
    private BufferedWaveProvider? _sourceBuffer;
    private ISampleProvider? _outputProvider;

    // Single-consumer channel ensures audio chunks reach the handler in arrival
    // order. Without this, per-chunk Task.Run dispatch could reorder chunks
    // across threadpool threads and corrupt the recognizer's state.
    private Channel<AudioChunk>? _chunkChannel;
    private Task? _dispatcherTask;
    private CancellationTokenSource? _dispatcherCts;

    public void Prewarm()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            _ = device.AudioClient;
            Logger.Information("Audio engine prewarmed");
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Prewarm failed — microphone may not be available");
        }
    }

    public void StartCapture(Func<AudioChunk, Task> handler)
    {
        StopCapture();

        _chunkChannel = Channel.CreateUnbounded<AudioChunk>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = true
        });
        _dispatcherCts = new CancellationTokenSource();
        _dispatcherTask = Task.Run(() => DispatcherLoopAsync(_chunkChannel.Reader, handler, _dispatcherCts.Token));

        using var enumerator = new MMDeviceEnumerator();
        var device = PickCaptureDevice(enumerator);
        _currentDeviceName = device.FriendlyName;

        _capture = new WasapiCapture(device, true, 20);
        _captureFormat = _capture.WaveFormat;

        // Build the resampling chain once per capture session.
        _sourceBuffer = new BufferedWaveProvider(_captureFormat)
        {
            BufferDuration = TimeSpan.FromSeconds(5),
            DiscardOnBufferOverflow = true,
            ReadFully = false
        };

        ISampleProvider sample = _sourceBuffer.ToSampleProvider();
        if (_captureFormat.Channels > 1)
        {
            sample = new StereoToMonoSampleProvider(sample) { LeftVolume = 0.5f, RightVolume = 0.5f };
        }
        if (_captureFormat.SampleRate != TargetSampleRate)
        {
            // WdlResampler is stateful and stable across small repeated reads.
            sample = new WdlResamplingSampleProvider(sample, TargetSampleRate);
        }
        _outputProvider = sample;

        _agcGain = AgcMinGain;
        _agcPeakHistory.Clear();

        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
        _capture.StartRecording();

        Logger.Information("Audio capture started. Source format: {Format}, target: 16 kHz mono PCM16", _captureFormat);
    }

    public void StopCapture()
    {
        if (_capture is null && _chunkChannel is null) return;

        if (_capture is not null)
        {
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            try { _capture.StopRecording(); } catch (Exception ex) { Logger.Warning(ex, "StopRecording threw"); }
            _capture.Dispose();
            _capture = null;
        }

        _sourceBuffer = null;
        _outputProvider = null;
        _currentDeviceName = null;

        _chunkChannel?.Writer.TryComplete();
        try { _dispatcherTask?.Wait(TimeSpan.FromSeconds(2)); } catch { /* ignore */ }
        _dispatcherCts?.Cancel();
        _dispatcherCts?.Dispose();
        _dispatcherCts = null;
        _dispatcherTask = null;
        _chunkChannel = null;

        Logger.Information("Audio capture stopped");
    }

    private async Task DispatcherLoopAsync(ChannelReader<AudioChunk> reader, Func<AudioChunk, Task> handler, CancellationToken ct)
    {
        try
        {
            await foreach (var chunk in reader.ReadAllAsync(ct))
            {
                try { await handler(chunk); }
                catch (OperationCanceledException) { break; }
                catch (Exception ex) { Logger.Error(ex, "Audio chunk handler crashed"); }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Logger.Error(ex, "Audio dispatcher loop crashed"); }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0 || _chunkChannel is null
            || _sourceBuffer is null || _outputProvider is null) return;

        try
        {
            // Feed the raw device bytes into the resampling chain.
            _sourceBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);

            // Drain whatever 16 kHz mono float samples the chain has ready.
            // 4096 samples = 256 ms; chain buffers 5s, so this loop drains a chunk's worth per call.
            var floats = new float[4096];
            int read = _outputProvider.Read(floats, 0, floats.Length);
            if (read == 0) return;

            byte[] pcm16 = new byte[read * 2];
            float maxAbs = 0f;
            double sumSq = 0;
            for (int i = 0; i < read; i++)
            {
                float f = floats[i];
                float abs = f < 0 ? -f : f;
                if (abs > maxAbs) maxAbs = abs;
                sumSq += f * f;
            }

            // pre-AGC RMS — used by silent-mic detection upstream and as the
            // displayed audio level. AGC must not hide a dead microphone.
            float preAgcRms = (float)Math.Sqrt(sumSq / read);

            float gain = ComputeAgcGain(maxAbs);

            for (int i = 0; i < read; i++)
            {
                float f = floats[i] * gain;
                // soft tanh-style limiter — saturates instead of hard-clipping
                // so loud syllables stay intelligible rather than turning to
                // square-wave crunch when the AGC is still ramping down.
                if (f > 1f || f < -1f)
                    f = (float)Math.Tanh(f);

                short s = (short)(f * 32767f);
                pcm16[i * 2] = (byte)(s & 0xff);
                pcm16[i * 2 + 1] = (byte)((s >> 8) & 0xff);
            }

            var chunk = new AudioChunk(pcm16, TargetSampleRate, 1, preAgcRms);
            _chunkChannel.Writer.TryWrite(chunk);
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "OnDataAvailable failed");
        }
    }

    private float ComputeAgcGain(float chunkPeak)
    {
        var now = DateTime.UtcNow;
        _agcPeakHistory.Enqueue((now, chunkPeak));
        var cutoff = now.AddMilliseconds(-AgcWindowMillis);
        while (_agcPeakHistory.Count > 0 && _agcPeakHistory.Peek().At < cutoff)
            _agcPeakHistory.Dequeue();

        float windowPeak = 0f;
        foreach (var (_, p) in _agcPeakHistory)
            if (p > windowPeak) windowPeak = p;

        // Avoid amplifying pure silence to AgcMaxGain × tiny number = noise floor.
        // 0.002 ≈ -54dBFS — anything quieter is treated as silence and held at unity.
        // Lowered from 0.01 because some built-in mic arrays (Intel Smart Sound)
        // produce legitimate speech at 0.004 peak even at close range.
        if (windowPeak < 0.002f)
        {
            _agcGain = AgcMinGain;
            return _agcGain;
        }

        float target = AgcTargetPeak / windowPeak;
        if (target < AgcMinGain) target = AgcMinGain;
        if (target > AgcMaxGain) target = AgcMaxGain;

        // Smooth transitions — never let gain change by more than the per-chunk cap.
        float maxStep = target > _agcGain ? _agcGain * AgcMaxStepUp : _agcGain * AgcMaxStepDown;
        if (target > _agcGain && target > maxStep) target = maxStep;
        if (target < _agcGain && target < maxStep) target = maxStep;
        _agcGain = target;
        return _agcGain;
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null)
        {
            Logger.Error(e.Exception, "Recording stopped due to error");
        }
    }

    public void Dispose() => StopCapture();

    /// <summary>
    /// Pick a capture device. The system default is unreliable on machines with
    /// virtual audio drivers (Virtual Audio Cable, OBS, screen-share routers,
    /// Stereo Mix) — those silently win the "default" slot but carry program
    /// audio rather than mic input. We also avoid Bluetooth Hands-Free (HFP)
    /// devices that Windows lists as active but whose mic isn't actually
    /// streaming until placed in the right Bluetooth profile.
    ///
    /// Preference order:
    ///   1. Built-in mic arrays / wired mics (most reliable)
    ///   2. The system default (if not virtual / not bluetooth-headset)
    ///   3. Any other physical-looking device
    ///   4. Fall back to whatever the system default is
    /// </summary>
    private static MMDevice PickCaptureDevice(MMDeviceEnumerator enumerator)
    {
        var defaultDevice = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        var all = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).ToList();

        Logger.Information("Found {N} active capture devices: {List}",
            all.Count, string.Join(", ", all.Select(d => d.FriendlyName)));

        // 1. Pick a built-in mic array or wired mic if available.
        var builtIn = all.FirstOrDefault(d => IsBuiltInMic(d.FriendlyName));
        if (builtIn is not null)
        {
            Logger.Information("Selected built-in mic: {Name}", builtIn.FriendlyName);
            return builtIn;
        }

        // 2. Use system default if it's not a virtual/bluetooth device.
        if (!IsLikelyVirtual(defaultDevice.FriendlyName) && !IsLikelyBluetoothHeadset(defaultDevice.FriendlyName))
        {
            Logger.Information("Using system default capture device: {Name}", defaultDevice.FriendlyName);
            return defaultDevice;
        }

        Logger.Warning("System default looks unreliable: {Name}", defaultDevice.FriendlyName);

        // 3. Any other physical-looking device.
        var other = all.FirstOrDefault(d => !IsLikelyVirtual(d.FriendlyName) && !IsLikelyBluetoothHeadset(d.FriendlyName));
        if (other is not null)
        {
            Logger.Information("Selected fallback physical device: {Name}", other.FriendlyName);
            return other;
        }

        Logger.Warning("No good physical device found. Falling back to default: {Name}", defaultDevice.FriendlyName);
        return defaultDevice;
    }

    private static bool IsBuiltInMic(string name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        string n = name.ToLowerInvariant();
        return n.Contains("麦克风阵列") || n.Contains("microphone array") || n.Contains("mic array")
            || n.Contains("internal microphone") || n.Contains("内置麦克风")
            || n.Contains("智音") || n.Contains("realtek")
            || (n.Contains("microphone") && !IsLikelyBluetoothHeadset(name) && !IsLikelyVirtual(name));
    }

    private static bool IsLikelyBluetoothHeadset(string name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        string n = name.ToLowerInvariant();
        // Bluetooth headsets often appear as "耳机 (XXX Hands-Free AG Audio)"
        return n.Contains("hands-free") || n.Contains("headset") || n.Contains("耳机")
            || n.Contains("airpods") || n.Contains("buds") || n.Contains("hfp");
    }

    private static bool IsLikelyVirtual(string name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        string n = name.ToLowerInvariant();
        return n.Contains("virtual") || n.Contains("cable") || n.Contains("stereo mix")
            || n.Contains("立体声混音") || n.Contains("混音") || n.Contains("loopback")
            || n.Contains("vb-audio") || n.Contains("voicemeeter") || n.Contains("obs")
            || n.Contains("screenshare");
    }
}
