using System.Threading.Channels;
using GuGuTalk.Core;
using GuGuTalk.Core.Models;
using Serilog;
using SherpaOnnx;

namespace GuGuTalk.LocalAsr;

public sealed class SherpaOnnxProvider : ISpeechProvider, IAsyncDisposable
{
    private static readonly ILogger Logger = Log.ForContext<SherpaOnnxProvider>();

    private readonly Channel<TranscriptEvent> _channel = Channel.CreateUnbounded<TranscriptEvent>();
    private readonly object _streamLock = new();

    // Recognizer is loaded once and reused across sessions (loading takes ~5s).
    // Each session gets a fresh stream from CreateStream() (microseconds).
    private OnlineRecognizer? _recognizer;
    private OnlineStream? _stream;
    private int _revision;
    private string _lastText = "";
    private bool _hasTerminated;
    private bool _disposed;
    private int _chunksReceived;
    private double _audioLevelSum;

    // Debug: dump exactly the audio sent to sherpa-onnx so we can listen to it
    // and confirm whether the audio pipeline corrupts speech or not.
    private FileStream? _debugWavStream;
    private string? _debugWavPath;
    private int _debugSampleCount;

    public RecognitionMode Mode => RecognitionMode.Local;
    public ChannelReader<TranscriptEvent> Events => _channel.Reader;

    /// <summary>
    /// Loads the recognizer in the background so the first hotkey press doesn't
    /// have to wait ~5-10s for model load. Safe to call multiple times.
    /// </summary>
    public void Prewarm()
    {
        _ = Task.Run(() =>
        {
            try
            {
                lock (_streamLock)
                {
                    if (_disposed || _recognizer is not null) return;
                    var config = new RecognitionConfig(
                        LanguageCode: "zh-CN", SampleRate: 16000,
                        Mode: RecognitionMode.Local, PartialResultsEnabled: true,
                        Endpointing: EndpointingPolicy.Manual,
                        DoubaoCredentials: new DoubaoCredentials("", "", "", ""),
                        QwenCredentials: new QwenCredentials("", "", ""));
                    _recognizer = LoadRecognizer(config);
                }
                Logger.Information("Recognizer prewarmed");
            }
            catch (Exception ex)
            {
                Logger.Warning(ex, "Recognizer prewarm failed (will retry on first use)");
            }
        });
    }

    public Task StartSessionAsync(RecognitionConfig config, CancellationToken ct = default)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(SherpaOnnxProvider));

        // Recognizer load takes ~5-10s for the zh-14M model. Run it on a worker
        // thread so the keyboard hook (which fires StartSessionAsync via the
        // hotkey handler) doesn't block message-pump events for that long.
        return Task.Run(() =>
        {
            lock (_streamLock)
            {
                if (_disposed) return;
                if (_recognizer is null)
                {
                    _recognizer = LoadRecognizer(config);
                }

                _stream?.Dispose();
                _stream = _recognizer.CreateStream();

                // Streaming Zipformer's deepest encoder layer needs 128 frames
                // (~1.28s) of left context before its outputs are reliable, so
                // the first ~0.3s of real audio is processed with an empty
                // context window and the leading syllables get dropped. Feed a
                // half second of silence right after CreateStream so by the
                // time the user's first phoneme arrives the encoder context is
                // already warm.
                int warmupSamples = (int)(config.SampleRate / 2);
                _stream.AcceptWaveform((int)config.SampleRate, new float[warmupSamples]);

                _revision = 0;
                _lastText = "";
                _hasTerminated = false;
                _chunksReceived = 0;
                _audioLevelSum = 0;
                OpenDebugWav();
            }

            _channel.Writer.TryWrite(new TranscriptEvent.SessionStarted(Mode));
            Logger.Information("Local ASR session ready (recognizer cached)");
        }, ct);
    }

    public Task SendAudioAsync(AudioChunk chunk, CancellationToken ct = default)
    {
        if (_recognizer is null || _stream is null) return Task.CompletedTask;

        float[] samples = ConvertPcm16ToFloat(chunk.PcmData);

        // sherpa-onnx OnlineRecognizer/OnlineStream are not thread-safe. Audio
        // chunks may arrive on different threadpool threads, so the lock keeps
        // native state consistent and prevents the SEH crash in GetResult.
        lock (_streamLock)
        {
            if (_recognizer is null || _stream is null) return Task.CompletedTask;

            _stream.AcceptWaveform((int)chunk.SampleRate, samples);
            _chunksReceived++;
            _audioLevelSum += chunk.AudioLevel;
            WriteDebugWav(chunk.PcmData);

            while (_recognizer.IsReady(_stream))
            {
                _recognizer.Decode(_stream);
            }

            string text = _recognizer.GetResult(_stream).Text.Trim();
            if (!string.IsNullOrEmpty(text) && text != _lastText)
            {
                _lastText = text;
                _revision++;
                _channel.Writer.TryWrite(new TranscriptEvent.PartialTextUpdated(text, _revision));
            }
            // Endpoint detection is intentionally disabled for hold-to-talk:
            // the user signals end-of-utterance by releasing the hotkey, not by
            // pausing. Calling Reset() mid-utterance was clobbering the decoded
            // partial — when the trailing-silence rule fired between syllables
            // the buffered text was thrown away and the final result came back
            // empty. We let the recognizer keep state until FinishAudioAsync.
        }

        return Task.CompletedTask;
    }

    public Task FinishAudioAsync(CancellationToken ct = default)
    {
        if (_recognizer is null || _stream is null)
        {
            EmitSessionEndedIfNeeded();
            return Task.CompletedTask;
        }

        lock (_streamLock)
        {
            if (_recognizer is null || _stream is null) return Task.CompletedTask;

            // Signal end of input, then decode remaining frames in the buffer.
            // Do NOT feed silence before InputFinished() - it may interfere with
            // decoding the actual speech audio that's already in the buffer.
            _stream.InputFinished();

            while (_recognizer.IsReady(_stream))
            {
                _recognizer.Decode(_stream);
            }

            string finalText = _recognizer.GetResult(_stream).Text.Trim();
            double avgLevel = _chunksReceived > 0 ? _audioLevelSum / _chunksReceived : 0;
            Logger.Information("Finish: chunks={Chunks} avgLevel={Avg:F4} lastPartial='{Last}' final='{Final}'",
                _chunksReceived, avgLevel, _lastText, finalText);
            if (string.IsNullOrEmpty(finalText))
            {
                finalText = _lastText;
            }

            if (!string.IsNullOrEmpty(finalText))
            {
                _channel.Writer.TryWrite(new TranscriptEvent.FinalTextReady(finalText));
            }
        }

        EmitSessionEndedIfNeeded();
        return Task.CompletedTask;
    }

    public Task CancelAsync()
    {
        EmitSessionEndedIfNeeded();
        // Only dispose the stream — the recognizer stays alive for next session.
        lock (_streamLock)
        {
            _stream?.Dispose();
            _stream = null;
            CloseDebugWav();
        }
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        lock (_streamLock)
        {
            _stream?.Dispose();
            _stream = null;
            _recognizer?.Dispose();
            _recognizer = null;
        }
        return ValueTask.CompletedTask;
    }

    private static OnlineRecognizer LoadRecognizer(RecognitionConfig config)
    {
        var tokensPath = ModelManager.GetTokensPath()
            ?? throw new InvalidOperationException("本地识别模型未找到。安装包中应已包含模型，请检查安装目录。");

        var modelDir = Path.GetDirectoryName(tokensPath)!;
        Logger.Information("Loading local ASR model from: {Dir}", modelDir);

        var modelConfig = new OnlineModelConfig
        {
            Tokens = tokensPath,
            NumThreads = 4,
            Provider = "cpu"
        };

        var encoder = FindFile(modelDir, "encoder*.onnx");
        var decoder = FindFile(modelDir, "decoder*.onnx");
        var joiner = FindFile(modelDir, "joiner*.onnx");

        if (encoder is not null && decoder is not null && joiner is not null)
        {
            modelConfig.Transducer.Encoder = encoder;
            modelConfig.Transducer.Decoder = decoder;
            modelConfig.Transducer.Joiner = joiner;
            Logger.Information("Detected transducer model");
        }
        else if (encoder is not null && decoder is not null)
        {
            modelConfig.Paraformer.Encoder = encoder;
            modelConfig.Paraformer.Decoder = decoder;
            Logger.Information("Detected paraformer model");
        }
        else
        {
            throw new InvalidOperationException($"未找到有效的识别模型文件 (位置: {modelDir})");
        }

        var recognizerConfig = new OnlineRecognizerConfig
        {
            ModelConfig = modelConfig,
            DecodingMethod = "greedy_search",
            // Endpointing is disabled: hold-to-talk relies on the user releasing
            // the hotkey, and Reset() mid-utterance (which the endpoint flow
            // wants) drops the partial text the model has already produced.
            EnableEndpoint = 0
        };
        recognizerConfig.FeatConfig.SampleRate = (int)config.SampleRate;
        recognizerConfig.FeatConfig.FeatureDim = 80;

        return new OnlineRecognizer(recognizerConfig);
    }

    private void EmitSessionEndedIfNeeded()
    {
        if (_hasTerminated) return;
        _hasTerminated = true;
        CloseDebugWav();
        _channel.Writer.TryWrite(new TranscriptEvent.SessionEnded());
    }

    private void OpenDebugWav()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "GuGuTalk", "debug");
            Directory.CreateDirectory(dir);
            _debugWavPath = Path.Combine(dir, $"session-{DateTime.Now:yyyyMMdd-HHmmss-fff}.wav");
            _debugWavStream = new FileStream(_debugWavPath, FileMode.Create, FileAccess.Write);
            _debugSampleCount = 0;
            // Reserve 44 bytes for the WAV header; we'll backfill on close.
            _debugWavStream.Write(new byte[44], 0, 44);
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to open debug WAV");
            _debugWavStream = null;
        }
    }

    private void WriteDebugWav(byte[] pcm16)
    {
        if (_debugWavStream is null) return;
        try
        {
            _debugWavStream.Write(pcm16, 0, pcm16.Length);
            _debugSampleCount += pcm16.Length / 2;
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to write debug WAV");
        }
    }

    private void CloseDebugWav()
    {
        if (_debugWavStream is null) return;
        try
        {
            // Build WAV header (16 kHz mono PCM16) and seek back to write it.
            int byteRate = 16000 * 2;
            int dataSize = _debugSampleCount * 2;
            int riffSize = 36 + dataSize;

            byte[] header = new byte[44];
            // "RIFF"
            header[0] = (byte)'R'; header[1] = (byte)'I'; header[2] = (byte)'F'; header[3] = (byte)'F';
            BitConverter.GetBytes(riffSize).CopyTo(header, 4);
            // "WAVE"
            header[8] = (byte)'W'; header[9] = (byte)'A'; header[10] = (byte)'V'; header[11] = (byte)'E';
            // "fmt "
            header[12] = (byte)'f'; header[13] = (byte)'m'; header[14] = (byte)'t'; header[15] = (byte)' ';
            BitConverter.GetBytes(16).CopyTo(header, 16);          // fmt chunk size
            BitConverter.GetBytes((short)1).CopyTo(header, 20);    // PCM
            BitConverter.GetBytes((short)1).CopyTo(header, 22);    // mono
            BitConverter.GetBytes(16000).CopyTo(header, 24);       // sample rate
            BitConverter.GetBytes(byteRate).CopyTo(header, 28);    // byte rate
            BitConverter.GetBytes((short)2).CopyTo(header, 32);    // block align
            BitConverter.GetBytes((short)16).CopyTo(header, 34);   // bits/sample
            // "data"
            header[36] = (byte)'d'; header[37] = (byte)'a'; header[38] = (byte)'t'; header[39] = (byte)'a';
            BitConverter.GetBytes(dataSize).CopyTo(header, 40);

            _debugWavStream.Seek(0, SeekOrigin.Begin);
            _debugWavStream.Write(header, 0, 44);
            _debugWavStream.Flush();
            _debugWavStream.Dispose();
            Logger.Information("Debug WAV saved: {Path} ({Samples} samples = {Sec:F2}s)",
                _debugWavPath, _debugSampleCount, _debugSampleCount / 16000.0);
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to close debug WAV");
        }
        finally
        {
            _debugWavStream = null;
            _debugWavPath = null;
        }
    }

    private static float[] ConvertPcm16ToFloat(byte[] pcm16)
    {
        int sampleCount = pcm16.Length / 2;
        float[] samples = new float[sampleCount];
        for (int i = 0; i < sampleCount; i++)
        {
            short sample = (short)(pcm16[i * 2] | (pcm16[i * 2 + 1] << 8));
            samples[i] = sample / 32768.0f;
        }
        return samples;
    }

    private static string? FindFile(string dir, string searchPattern)
    {
        try
        {
            var matches = Directory.GetFiles(dir, searchPattern);
            // Prefer non-quantized variants for broader onnxruntime compatibility.
            return matches
                .OrderBy(p => p.Contains("int8", StringComparison.OrdinalIgnoreCase))
                .FirstOrDefault();
        }
        catch
        {
            return null;
        }
    }
}
