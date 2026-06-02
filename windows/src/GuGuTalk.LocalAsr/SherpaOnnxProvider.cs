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
    private readonly object _recognizerLock = new();

    // SenseVoice is an offline model. Keep the recognizer cached, then decode
    // the held utterance once the user releases the hotkey.
    private OfflineRecognizer? _recognizer;
    private MemoryStream? _sessionPcm;
    private int _sessionSampleRate = 16000;
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
    /// Loads the recognizer in the background so the first hotkey press does not
    /// wait for ONNX model initialization. Safe to call multiple times.
    /// </summary>
    public void Prewarm()
    {
        _ = Task.Run(() =>
        {
            try
            {
                lock (_recognizerLock)
                {
                    if (_disposed || _recognizer is not null) return;
                    var config = new RecognitionConfig(
                        LanguageCode: "zh-CN", SampleRate: 16000,
                        Mode: RecognitionMode.Local, PartialResultsEnabled: false,
                        Endpointing: EndpointingPolicy.Manual,
                        DoubaoCredentials: new DoubaoCredentials("", "", "", ""),
                        QwenCredentials: new QwenCredentials("", "", ""));
                    _recognizer = LoadRecognizer(config);
                }
                Logger.Information("SenseVoice recognizer prewarmed");
            }
            catch (Exception ex)
            {
                Logger.Warning(ex, "SenseVoice recognizer prewarm failed (will retry on first use)");
            }
        });
    }

    public Task StartSessionAsync(RecognitionConfig config, CancellationToken ct = default)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(SherpaOnnxProvider));

        return Task.Run(() =>
        {
            lock (_recognizerLock)
            {
                if (_disposed) return;
                _recognizer ??= LoadRecognizer(config);

                _sessionPcm?.Dispose();
                _sessionPcm = new MemoryStream();
                _sessionSampleRate = (int)config.SampleRate;
                _hasTerminated = false;
                _chunksReceived = 0;
                _audioLevelSum = 0;
                OpenDebugWav();
            }

            _channel.Writer.TryWrite(new TranscriptEvent.SessionStarted(Mode));
            Logger.Information("Local SenseVoice ASR session ready (recognizer cached)");
        }, ct);
    }

    public Task SendAudioAsync(AudioChunk chunk, CancellationToken ct = default)
    {
        if (_disposed) return Task.CompletedTask;

        lock (_recognizerLock)
        {
            if (_recognizer is null || _sessionPcm is null) return Task.CompletedTask;

            _sessionPcm.Write(chunk.PcmData, 0, chunk.PcmData.Length);
            _sessionSampleRate = (int)chunk.SampleRate;
            _chunksReceived++;
            _audioLevelSum += chunk.AudioLevel;
            WriteDebugWav(chunk.PcmData);
        }

        return Task.CompletedTask;
    }

    public Task FinishAudioAsync(CancellationToken ct = default)
    {
        if (_disposed)
        {
            EmitSessionEndedIfNeeded();
            return Task.CompletedTask;
        }

        return Task.Run(() =>
        {
            try
            {
                string finalText;
                int byteCount;
                double avgLevel;

                lock (_recognizerLock)
                {
                    if (_recognizer is null || _sessionPcm is null)
                    {
                        _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed("本地识别模型尚未就绪"));
                        return;
                    }

                    var pcm = _sessionPcm.ToArray();
                    _sessionPcm.Dispose();
                    _sessionPcm = null;

                    byteCount = pcm.Length;
                    avgLevel = _chunksReceived > 0 ? _audioLevelSum / _chunksReceived : 0;
                    if (pcm.Length == 0)
                    {
                        _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed("没有收到有效音频"));
                        return;
                    }

                    var samples = ConvertPcm16ToFloat(pcm);
                    var stream = _recognizer.CreateStream();
                    stream.AcceptWaveform(_sessionSampleRate, samples);
                    _recognizer.Decode(new List<OfflineStream> { stream });
                    finalText = stream.Result.Text.Trim();
                }

                Logger.Information("SenseVoice finish: bytes={Bytes} chunks={Chunks} avgLevel={Avg:F4} final='{Final}'",
                    byteCount, _chunksReceived, avgLevel, finalText);

                if (!string.IsNullOrWhiteSpace(finalText))
                {
                    _channel.Writer.TryWrite(new TranscriptEvent.FinalTextReady(finalText));
                }
                else
                {
                    _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed("说话时间太短，没有识别到内容"));
                }
            }
            catch (Exception ex)
            {
                Logger.Error(ex, "SenseVoice local recognition failed");
                _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed($"本地识别失败：{ex.Message}"));
            }
            finally
            {
                EmitSessionEndedIfNeeded();
            }
        }, ct);
    }

    public Task CancelAsync()
    {
        EmitSessionEndedIfNeeded();
        lock (_recognizerLock)
        {
            _sessionPcm?.Dispose();
            _sessionPcm = null;
            CloseDebugWav();
        }
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;
        _disposed = true;
        lock (_recognizerLock)
        {
            _sessionPcm?.Dispose();
            _sessionPcm = null;
            _recognizer?.Dispose();
            _recognizer = null;
            CloseDebugWav();
        }
        return ValueTask.CompletedTask;
    }

    private static OfflineRecognizer LoadRecognizer(RecognitionConfig config)
    {
        var tokensPath = ModelManager.GetTokensPath()
            ?? throw new InvalidOperationException("本地识别模型 tokens.txt 未找到。请检查安装目录或用户模型目录。");
        var modelPath = ModelManager.GetModelPath()
            ?? throw new InvalidOperationException("SenseVoice model.int8.onnx 未找到。请检查安装目录或用户模型目录。");

        var modelDir = Path.GetDirectoryName(modelPath)!;
        Logger.Information("Loading SenseVoice local ASR model from: {Dir}", modelDir);

        var recognizerConfig = new OfflineRecognizerConfig
        {
            DecodingMethod = "greedy_search"
        };
        recognizerConfig.FeatConfig.SampleRate = (int)config.SampleRate;
        recognizerConfig.FeatConfig.FeatureDim = 80;
        recognizerConfig.ModelConfig.Tokens = tokensPath;
        recognizerConfig.ModelConfig.NumThreads = 4;
        recognizerConfig.ModelConfig.Provider = "cpu";
        recognizerConfig.ModelConfig.Debug = 0;
        recognizerConfig.ModelConfig.SenseVoice.Model = modelPath;
        recognizerConfig.ModelConfig.SenseVoice.Language = "auto";
        recognizerConfig.ModelConfig.SenseVoice.UseInverseTextNormalization = 1;

        return new OfflineRecognizer(recognizerConfig);
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
}
