using System.Diagnostics;
using System.Threading.Channels;
using GuGuTalk.Core;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Services;
using Serilog;
using SherpaOnnx;

namespace GuGuTalk.LocalAsr;

public sealed class SherpaOnnxProvider : ISpeechProvider, IAsyncDisposable
{
    private static readonly ILogger Logger = Log.ForContext<SherpaOnnxProvider>();
    private static readonly float[] LeadingPadding = new float[16000 * 3 / 10];
    private static readonly float[] TrailingPadding = new float[16000 * 6 / 10];
    private const double PartialPunctuationIntervalSeconds = 0.25;

    private readonly Channel<TranscriptEvent> _channel = Channel.CreateUnbounded<TranscriptEvent>();
    private readonly object _recognizerLock = new();

    private OnlineRecognizer? _recognizer;
    private OfflinePunctuation? _punctuation;
    private OnlineStream? _stream;
    private int _sessionSampleRate = 16000;
    private bool _sessionOpen;
    private bool _acceptsAudio;
    private bool _hasTerminated;
    private bool _disposed;
    private int _chunksReceived;
    private int _audioByteCount;
    private double _audioLevelSum;
    private int _revision;
    private string _lastPartialRawText = string.Empty;
    private string _lastPartialText = string.Empty;
    private long _lastPartialTimestamp;

    private FileStream? _debugWavStream;
    private string? _debugWavPath;
    private int _debugSampleCount;

    public RecognitionMode Mode => RecognitionMode.Local;
    public ChannelReader<TranscriptEvent> Events => _channel.Reader;

    /// <summary>
    /// Loads both CPU models in the background so the first hotkey press only
    /// needs to create an online stream. Safe to call multiple times.
    /// </summary>
    public void Prewarm()
    {
        _ = Task.Run(() =>
        {
            try
            {
                lock (_recognizerLock)
                {
                    if (_disposed || (_recognizer is not null && _punctuation is not null)) return;
                    EnsureRuntimeLoadedLocked(16000);
                }
                Logger.Information("Streaming Paraformer and punctuation models prewarmed");
            }
            catch (Exception ex)
            {
                Logger.Warning(ex, "Local streaming ASR prewarm failed (will retry on first use)");
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
                if (_disposed) throw new ObjectDisposedException(nameof(SherpaOnnxProvider));

                _sessionSampleRate = (int)config.SampleRate;
                EnsureRuntimeLoadedLocked(_sessionSampleRate);
                DisposeStreamLocked();
                _stream = _recognizer!.CreateStream();
                _stream.AcceptWaveform(_sessionSampleRate, LeadingPadding);

                _sessionOpen = true;
                _acceptsAudio = true;
                _hasTerminated = false;
                _chunksReceived = 0;
                _audioByteCount = 0;
                _audioLevelSum = 0;
                _revision = 0;
                _lastPartialRawText = string.Empty;
                _lastPartialText = string.Empty;
                _lastPartialTimestamp = 0;
                OpenDebugWavLocked();

                _channel.Writer.TryWrite(new TranscriptEvent.SessionStarted(Mode));
            }

            Logger.Information("Local streaming ASR session ready (models cached)");
        }, ct);
    }

    public Task SendAudioAsync(AudioChunk chunk, CancellationToken ct = default)
    {
        if (_disposed) return Task.CompletedTask;

        return Task.Run(() =>
        {
            if (ct.IsCancellationRequested) return;

            lock (_recognizerLock)
            {
                if (_disposed || !_sessionOpen || !_acceptsAudio
                    || _recognizer is null || _punctuation is null || _stream is null)
                {
                    return;
                }

                _sessionSampleRate = (int)chunk.SampleRate;
                _chunksReceived++;
                _audioByteCount += chunk.PcmData.Length;
                _audioLevelSum += chunk.AudioLevel;
                WriteDebugWavLocked(chunk.PcmData);

                var samples = ConvertPcm16ToFloat(chunk.PcmData);
                if (samples.Length == 0) return;

                _stream.AcceptWaveform(_sessionSampleRate, samples);
                DrainRecognizerLocked();

                var rawText = _recognizer.GetResult(_stream).Text.Trim();
                if (!ShouldRunPartialPunctuationLocked(rawText)) return;

                var punctuatedText = AddPunctuationLocked(rawText);
                _lastPartialRawText = rawText;
                _lastPartialTimestamp = Stopwatch.GetTimestamp();
                if (string.IsNullOrWhiteSpace(punctuatedText) || punctuatedText == _lastPartialText) return;

                _lastPartialText = punctuatedText;
                _revision++;
                _channel.Writer.TryWrite(new TranscriptEvent.PartialTextUpdated(punctuatedText, _revision));
            }
        });
    }

    public Task FinishAudioAsync(CancellationToken ct = default)
    {
        if (_disposed)
        {
            lock (_recognizerLock)
            {
                EmitSessionEndedIfNeededLocked();
            }
            return Task.CompletedTask;
        }

        return Task.Run(() =>
        {
            lock (_recognizerLock)
            {
                if (!_sessionOpen || _hasTerminated) return;
                _acceptsAudio = false;

                try
                {
                    if (_recognizer is null || _punctuation is null || _stream is null)
                    {
                        _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed("本地识别模型尚未就绪"));
                        return;
                    }

                    var averageLevel = _chunksReceived > 0 ? _audioLevelSum / _chunksReceived : 0;
                    if (_audioByteCount == 0)
                    {
                        _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed("没有收到有效音频"));
                        return;
                    }

                    _stream.AcceptWaveform(_sessionSampleRate, TrailingPadding);
                    _stream.InputFinished();
                    DrainRecognizerLocked();

                    var rawText = _recognizer.GetResult(_stream).Text.Trim();
                    var finalText = string.IsNullOrWhiteSpace(rawText)
                        ? string.Empty
                        : AddPunctuationLocked(rawText);

                    Logger.Information(
                        "Streaming ASR finish: bytes={Bytes} chunks={Chunks} avgLevel={Avg:F4} final='{Final}'",
                        _audioByteCount, _chunksReceived, averageLevel, finalText);

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
                    Logger.Error(ex, "Local streaming recognition failed");
                    _channel.Writer.TryWrite(new TranscriptEvent.SessionFailed($"本地识别失败：{ex.Message}"));
                }
                finally
                {
                    DisposeStreamLocked();
                    EmitSessionEndedIfNeededLocked();
                }
            }
        });
    }

    public Task CancelAsync()
    {
        lock (_recognizerLock)
        {
            DisposeStreamLocked();
            EmitSessionEndedIfNeededLocked();
        }
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        if (_disposed) return ValueTask.CompletedTask;

        lock (_recognizerLock)
        {
            if (_disposed) return ValueTask.CompletedTask;
            _disposed = true;
            DisposeStreamLocked();
            _punctuation?.Dispose();
            _punctuation = null;
            _recognizer?.Dispose();
            _recognizer = null;
            CloseDebugWavLocked();
        }
        return ValueTask.CompletedTask;
    }

    private void EnsureRuntimeLoadedLocked(int sampleRate)
    {
        if (_recognizer is not null && _punctuation is not null) return;

        var tokensPath = ModelManager.GetTokensPath()
            ?? throw new InvalidOperationException("本地识别模型 tokens.txt 未找到。请检查安装目录或用户模型目录。");
        var encoderPath = ModelManager.GetEncoderPath()
            ?? throw new InvalidOperationException("Paraformer encoder.int8.onnx 未找到。请检查安装目录或用户模型目录。");
        var decoderPath = ModelManager.GetDecoderPath()
            ?? throw new InvalidOperationException("Paraformer decoder.int8.onnx 未找到。请检查安装目录或用户模型目录。");
        var punctuationPath = ModelManager.GetPunctuationModelPath()
            ?? throw new InvalidOperationException("CT-Transformer model.int8.onnx 未找到。请检查安装目录或用户模型目录。");

        Logger.Information(
            "Loading local streaming ASR models: asr={AsrDir} punctuation={PunctuationDir}",
            Path.GetDirectoryName(encoderPath), Path.GetDirectoryName(punctuationPath));

        var recognizerConfig = new OnlineRecognizerConfig
        {
            DecodingMethod = "greedy_search",
            EnableEndpoint = 0
        };
        recognizerConfig.FeatConfig.SampleRate = sampleRate;
        recognizerConfig.FeatConfig.FeatureDim = 80;
        recognizerConfig.ModelConfig.Tokens = tokensPath;
        recognizerConfig.ModelConfig.NumThreads = 2;
        recognizerConfig.ModelConfig.Provider = "cpu";
        recognizerConfig.ModelConfig.Debug = 0;
        recognizerConfig.ModelConfig.Paraformer.Encoder = encoderPath;
        recognizerConfig.ModelConfig.Paraformer.Decoder = decoderPath;

        var punctuationConfig = new OfflinePunctuationConfig();
        punctuationConfig.Model.CtTransformer = punctuationPath;
        punctuationConfig.Model.NumThreads = 1;
        punctuationConfig.Model.Provider = "cpu";
        punctuationConfig.Model.Debug = 0;

        var recognizer = new OnlineRecognizer(recognizerConfig);
        try
        {
            var punctuation = new OfflinePunctuation(punctuationConfig);
            _recognizer = recognizer;
            _punctuation = punctuation;
        }
        catch
        {
            recognizer.Dispose();
            throw;
        }
    }

    private void DrainRecognizerLocked()
    {
        if (_recognizer is null || _stream is null) return;
        while (_recognizer.IsReady(_stream))
        {
            _recognizer.Decode(_stream);
        }
    }

    private bool ShouldRunPartialPunctuationLocked(string rawText)
    {
        if (string.IsNullOrWhiteSpace(rawText) || rawText == _lastPartialRawText) return false;
        if (_lastPartialTimestamp == 0) return true;

        var elapsedSeconds = (Stopwatch.GetTimestamp() - _lastPartialTimestamp)
                             / (double)Stopwatch.Frequency;
        return elapsedSeconds >= PartialPunctuationIntervalSeconds;
    }

    private string AddPunctuationLocked(string rawText)
    {
        var punctuated = _punctuation?.AddPunct(rawText).Trim();
        if (string.IsNullOrWhiteSpace(punctuated)) punctuated = rawText;
        return PunctuationTextNormalizer.NormalizeForMixedChineseEnglish(punctuated);
    }

    private void DisposeStreamLocked()
    {
        _stream?.Dispose();
        _stream = null;
        _acceptsAudio = false;
    }

    private void EmitSessionEndedIfNeededLocked()
    {
        if (!_sessionOpen || _hasTerminated) return;
        _sessionOpen = false;
        _acceptsAudio = false;
        _hasTerminated = true;
        CloseDebugWavLocked();
        _channel.Writer.TryWrite(new TranscriptEvent.SessionEnded());
    }

    private void OpenDebugWavLocked()
    {
        CloseDebugWavLocked();
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "GuGuTalk", "debug");
            Directory.CreateDirectory(directory);
            _debugWavPath = Path.Combine(directory, $"session-{DateTime.Now:yyyyMMdd-HHmmss-fff}.wav");
            _debugWavStream = new FileStream(_debugWavPath, FileMode.Create, FileAccess.Write);
            _debugSampleCount = 0;
            _debugWavStream.Write(new byte[44], 0, 44);
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to open debug WAV");
            _debugWavStream = null;
        }
    }

    private void WriteDebugWavLocked(byte[] pcm16)
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

    private void CloseDebugWavLocked()
    {
        if (_debugWavStream is null) return;
        try
        {
            var byteRate = _sessionSampleRate * 2;
            var dataSize = _debugSampleCount * 2;
            var riffSize = 36 + dataSize;

            var header = new byte[44];
            header[0] = (byte)'R'; header[1] = (byte)'I'; header[2] = (byte)'F'; header[3] = (byte)'F';
            BitConverter.GetBytes(riffSize).CopyTo(header, 4);
            header[8] = (byte)'W'; header[9] = (byte)'A'; header[10] = (byte)'V'; header[11] = (byte)'E';
            header[12] = (byte)'f'; header[13] = (byte)'m'; header[14] = (byte)'t'; header[15] = (byte)' ';
            BitConverter.GetBytes(16).CopyTo(header, 16);
            BitConverter.GetBytes((short)1).CopyTo(header, 20);
            BitConverter.GetBytes((short)1).CopyTo(header, 22);
            BitConverter.GetBytes(_sessionSampleRate).CopyTo(header, 24);
            BitConverter.GetBytes(byteRate).CopyTo(header, 28);
            BitConverter.GetBytes((short)2).CopyTo(header, 32);
            BitConverter.GetBytes((short)16).CopyTo(header, 34);
            header[36] = (byte)'d'; header[37] = (byte)'a'; header[38] = (byte)'t'; header[39] = (byte)'a';
            BitConverter.GetBytes(dataSize).CopyTo(header, 40);

            _debugWavStream.Seek(0, SeekOrigin.Begin);
            _debugWavStream.Write(header, 0, 44);
            _debugWavStream.Flush();
            _debugWavStream.Dispose();
            Logger.Information(
                "Debug WAV saved: {Path} ({Samples} samples = {Sec:F2}s)",
                _debugWavPath, _debugSampleCount, _debugSampleCount / (double)_sessionSampleRate);
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
        var sampleCount = pcm16.Length / 2;
        var samples = new float[sampleCount];
        for (var index = 0; index < sampleCount; index++)
        {
            var sample = (short)(pcm16[index * 2] | (pcm16[index * 2 + 1] << 8));
            samples[index] = sample / 32768.0f;
        }
        return samples;
    }
}
