using GuGuTalk.Core.Models;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Serilog;

namespace GuGuTalk.Core.Services;

public sealed class AudioCaptureEngine : IAudioCaptureEngine, IDisposable
{
    private static readonly ILogger Logger = Log.ForContext<AudioCaptureEngine>();
    private static readonly WaveFormat TargetFormat = new(16000, 16, 1);

    private WasapiCapture? _capture;
    private Func<AudioChunk, Task>? _handler;
    private WaveFormat? _captureFormat;

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
        _handler = handler;

        using var enumerator = new MMDeviceEnumerator();
        var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);

        _capture = new WasapiCapture(device, true, 20);
        _captureFormat = _capture.WaveFormat;
        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
        _capture.StartRecording();

        Logger.Information("Audio capture started. Format: {Format}", _captureFormat);
    }

    public void StopCapture()
    {
        if (_capture is null) return;

        _capture.DataAvailable -= OnDataAvailable;
        _capture.RecordingStopped -= OnRecordingStopped;
        _capture.StopRecording();
        _capture.Dispose();
        _capture = null;
        _handler = null;

        Logger.Information("Audio capture stopped");
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0 || _handler is null) return;

        var resampled = ResampleTo16kMono(e.Buffer, e.BytesRecorded);
        if (resampled.Length == 0) return;

        float level = CalculateRmsLevel(resampled);
        var chunk = new AudioChunk(resampled, 16000, 1, level);

        _ = Task.Run(() => _handler(chunk));
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null)
        {
            Logger.Error(e.Exception, "Recording stopped due to error");
        }
    }

    private byte[] ResampleTo16kMono(byte[] buffer, int bytesRecorded)
    {
        if (_captureFormat is null) return [];

        if (_captureFormat.SampleRate == TargetFormat.SampleRate
            && _captureFormat.Channels == TargetFormat.Channels
            && _captureFormat.BitsPerSample == TargetFormat.BitsPerSample)
        {
            return buffer[..bytesRecorded];
        }

        using var inputStream = new RawSourceWaveStream(buffer, 0, bytesRecorded, _captureFormat);
        using var resampler = new MediaFoundationResampler(inputStream, TargetFormat);
        resampler.ResamplerQuality = 60;

        using var ms = new MemoryStream();
        var readBuffer = new byte[4096];
        int read;
        while ((read = resampler.Read(readBuffer, 0, readBuffer.Length)) > 0)
        {
            ms.Write(readBuffer, 0, read);
        }
        return ms.ToArray();
    }

    private static float CalculateRmsLevel(byte[] pcm16)
    {
        int sampleCount = pcm16.Length / 2;
        if (sampleCount == 0) return 0f;

        double sum = 0;
        for (int i = 0; i < pcm16.Length - 1; i += 2)
        {
            short sample = (short)(pcm16[i] | (pcm16[i + 1] << 8));
            double normalized = sample / (double)short.MaxValue;
            sum += normalized * normalized;
        }

        return (float)Math.Sqrt(sum / sampleCount);
    }

    public void Dispose() => StopCapture();
}
