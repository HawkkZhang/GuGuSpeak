using GuGuTalk.Core.Models;

namespace GuGuTalk.Core.Services;

public interface IAudioCaptureEngine
{
    void Prewarm();
    void StartCapture(Func<AudioChunk, Task> handler);
    void StopCapture();
    string? CurrentDeviceName { get; }
}
