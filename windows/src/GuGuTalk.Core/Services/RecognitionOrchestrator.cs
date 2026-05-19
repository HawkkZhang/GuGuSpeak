using CommunityToolkit.Mvvm.ComponentModel;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Providers;
using GuGuTalk.Core.Settings;
using Serilog;

namespace GuGuTalk.Core.Services;

public sealed partial class RecognitionOrchestrator : ObservableObject
{
    private static readonly ILogger Logger = Log.ForContext<RecognitionOrchestrator>();

    [ObservableProperty] private InsertionResult? _lastInsertionResult;
    [ObservableProperty] private string? _lastErrorMessage;
    [ObservableProperty] private bool _isSessionRunning;

    // Preview state (observable for UI binding)
    [ObservableProperty] private bool _isPreviewVisible;
    [ObservableProperty] private bool _isRecording;
    [ObservableProperty] private string _previewTitle = "";
    [ObservableProperty] private string _previewMessage = "";
    [ObservableProperty] private string _previewTranscript = "";
    [ObservableProperty] private string? _previewError;
    [ObservableProperty] private string? _previewHint;
    [ObservableProperty] private float _audioLevel;
    [ObservableProperty] private bool _isPostProcessing;

    private readonly AppSettings _settings;
    private readonly IAudioCaptureEngine _audioCaptureEngine;
    private readonly ProviderFactory _providerFactory;
    private readonly ITextInsertionService _textInsertionService;
    private readonly SmartPostProcessor _postProcessor;

    private ISpeechProvider? _activeProvider;
    private ISpeechProvider? _startingProvider;
    private CancellationTokenSource? _sessionCts;
    private CancellationTokenSource? _dismissCts;
    private string _finalTranscript = "";
    private bool _isPendingStop;
    private bool _isStartingSession;
    private bool _isSessionActive;
    private bool _isFinishRequested;
    private int _sessionGeneration;

    public RecognitionOrchestrator(
        AppSettings settings,
        IAudioCaptureEngine audioCaptureEngine,
        ProviderFactory providerFactory,
        ITextInsertionService textInsertionService,
        SmartPostProcessor postProcessor)
    {
        _settings = settings;
        _audioCaptureEngine = audioCaptureEngine;
        _providerFactory = providerFactory;
        _textInsertionService = textInsertionService;
        _postProcessor = postProcessor;
    }

    public bool HasActiveWork =>
        _isStartingSession || _isSessionActive || IsSessionRunning ||
        _isFinishRequested || _startingProvider is not null ||
        _activeProvider is not null || IsPostProcessing;

    public async Task BeginCaptureAsync()
    {
        if (_isStartingSession || _isSessionActive)
        {
            Logger.Information("BeginCapture ignored: session already active");
            return;
        }

        _sessionGeneration++;
        int generation = _sessionGeneration;
        _dismissCts?.Cancel();
        _sessionCts?.Cancel();
        _sessionCts = new CancellationTokenSource();

        ResetPreviewState();
        _finalTranscript = "";
        LastErrorMessage = null;
        LastInsertionResult = null;
        _isPendingStop = false;
        _isStartingSession = true;
        _isFinishRequested = false;

        var config = _settings.RecognitionConfig;
        var selections = _providerFactory.ResolveProviders();
        if (selections.Count == 0)
        {
            Fail("没有可用的识别引擎，请先配置本地或云端 provider。");
            return;
        }

        IsPreviewVisible = true;
        PreviewTitle = "正在聆听";
        PreviewMessage = "正在启动识别引擎";
        IsRecording = true;

        Logger.Information("Starting capture. generation={Gen} mode={Mode}", generation, config.Mode.Title());

        try
        {
            var selection = await StartProviderChainAsync(selections, config, generation);
            if (_sessionGeneration != generation)
            {
                await selection.Provider.CancelAsync();
                return;
            }

            PreviewMessage = "按住说话，松开后会插入最终文本";
            _isSessionActive = true;
            IsSessionRunning = true;
            _isStartingSession = false;

            _audioCaptureEngine.StartCapture(async chunk =>
            {
                if (_sessionGeneration != generation || !_isSessionActive || _isFinishRequested) return;
                AudioLevel = chunk.AudioLevel;
                try
                {
                    await selection.Provider.SendAudioAsync(chunk, _sessionCts!.Token);
                }
                catch (Exception ex)
                {
                    Logger.Error(ex, "sendAudio failed");
                    Fail($"发送音频失败：{ex.Message}");
                }
            });

            Logger.Information("Audio capture started");

            if (_isPendingStop)
            {
                Logger.Information("Pending stop detected after capture start");
                await EndCaptureAsync();
            }
        }
        catch (OperationCanceledException)
        {
            Logger.Information("BeginCapture cancelled");
            _isStartingSession = false;
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "BeginCapture failed");
            _isStartingSession = false;
            Fail(ex.Message);
        }
    }

    public async Task EndCaptureAsync()
    {
        if (_activeProvider is null)
        {
            if (_isStartingSession)
            {
                _isPendingStop = true;
                Logger.Information("EndCapture requested before provider ready; marking pending");
            }
            return;
        }

        if (!_isSessionActive || _isFinishRequested) return;

        _isPendingStop = false;
        _isFinishRequested = true;
        IsRecording = false;
        PreviewMessage = "正在处理最后的音频";

        int finishGen = _sessionGeneration;
        await Task.Delay(300);
        if (!_isSessionActive || _sessionGeneration != finishGen) return;

        _audioCaptureEngine.StopCapture();

        try
        {
            await _activeProvider.FinishAudioAsync(_sessionCts?.Token ?? CancellationToken.None);
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "finishAudio failed");
            DismissQuietly("说话时间太短，没有识别到内容");
        }
    }

    public async Task CancelActiveWorkAsync(string reason)
    {
        if (!HasActiveWork)
        {
            _dismissCts?.Cancel();
            ResetPreviewState();
            return;
        }

        Logger.Warning("Cancelling active work. reason={Reason}", reason);
        _sessionGeneration++;
        _dismissCts?.Cancel();
        _sessionCts?.Cancel();

        var provider = _activeProvider;
        _activeProvider = null;
        _startingProvider = null;
        _audioCaptureEngine.StopCapture();

        _finalTranscript = "";
        _isStartingSession = false;
        _isPendingStop = false;
        _isFinishRequested = false;
        _isSessionActive = false;
        IsSessionRunning = false;
        ResetPreviewState();

        if (provider is not null) await provider.CancelAsync();
    }

    private async Task<ProviderSelection> StartProviderChainAsync(
        List<ProviderSelection> selections, RecognitionConfig config, int generation)
    {
        Exception? lastFailure = null;

        foreach (var selection in selections)
        {
            if (_sessionGeneration != generation)
                throw new OperationCanceledException();

            try
            {
                _startingProvider = selection.Provider;
                SubscribeToEvents(selection.Provider, generation);
                await selection.Provider.StartSessionAsync(config, _sessionCts!.Token);
                _startingProvider = null;

                if (_sessionGeneration != generation)
                {
                    await selection.Provider.CancelAsync();
                    throw new OperationCanceledException();
                }

                _activeProvider = selection.Provider;
                return selection;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                _startingProvider = null;
                Logger.Error(ex, "Provider start failed. mode={Mode}", selection.Mode.Title());
                lastFailure = ex;
            }
        }

        throw lastFailure ?? new InvalidOperationException("所有识别引擎都不可用。");
    }

    private void SubscribeToEvents(ISpeechProvider provider, int generation)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await foreach (var evt in provider.Events.ReadAllAsync())
                {
                    if (_sessionGeneration != generation) return;
                    HandleEvent(evt);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Logger.Error(ex, "Provider event loop crashed");
            }
        });
    }

    private void HandleEvent(TranscriptEvent evt)
    {
        switch (evt)
        {
            case TranscriptEvent.PartialTextUpdated partial:
                PreviewTranscript = partial.Text;
                break;

            case TranscriptEvent.FinalTextReady final:
                string finalText = final.Text;
                if (string.IsNullOrWhiteSpace(finalText))
                {
                    if (!string.IsNullOrWhiteSpace(PreviewTranscript))
                        finalText = PreviewTranscript.Trim();
                }

                if (string.IsNullOrWhiteSpace(finalText))
                {
                    DismissQuietly("没有识别到有效内容");
                    return;
                }

                _ = ProcessAndInsertAsync(finalText);
                break;

            case TranscriptEvent.SessionFailed failed:
                if (!string.IsNullOrEmpty(_finalTranscript))
                {
                    FinishSession("provider failure after final");
                }
                else if (!string.IsNullOrWhiteSpace(PreviewTranscript))
                {
                    _finalTranscript = PreviewTranscript.Trim();
                    InsertFinalText();
                    PreviewHint = "识别未完成，已插入部分结果";
                    FinishSession("provider failure used partial");
                }
                else
                {
                    DismissQuietly("说话时间太短，没有识别到内容");
                }
                break;

            case TranscriptEvent.SessionEnded:
                FinishSession("provider emitted sessionEnded");
                break;

            case TranscriptEvent.AudioLevelUpdated level:
                AudioLevel = level.Level;
                break;
        }
    }

    private async Task ProcessAndInsertAsync(string rawText)
    {
        IsPostProcessing = true;
        PreviewMessage = "正在优化文本";

        string processed;
        try
        {
            processed = await _postProcessor.ProcessAsync(rawText);
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Post-processing failed, using rules-only");
            processed = _postProcessor.ProcessRulesOnly(rawText);
        }

        IsPostProcessing = false;

        if (string.IsNullOrWhiteSpace(processed))
        {
            DismissQuietly("没有识别到有效内容");
            return;
        }

        _finalTranscript = processed;
        PreviewTranscript = _finalTranscript;
        InsertFinalText();
        ScheduleDismiss(0.8);
    }

    private void InsertFinalText()
    {
        PreviewMessage = "正在插入到当前输入位置";
        var result = _textInsertionService.Insert(_finalTranscript);
        LastInsertionResult = result;
        if (result.Succeeded)
        {
            PreviewMessage = "已插入到当前应用";
        }
        else
        {
            PreviewError = result.FailureReason;
            LastErrorMessage = result.FailureReason;
        }
    }

    private void FinishSession(string reason)
    {
        Logger.Information("Finishing session. reason={Reason}", reason);
        _audioCaptureEngine.StopCapture();
        _isStartingSession = false;
        _isPendingStop = false;
        _isFinishRequested = false;
        _isSessionActive = false;
        IsSessionRunning = false;
        _activeProvider = null;
        _startingProvider = null;
        IsRecording = false;

        if (!IsPostProcessing)
            ScheduleDismiss(PreviewError is null ? 1.0 : 2.5);
    }

    private void Fail(string message)
    {
        Logger.Error("Session failed: {Message}", message);
        _audioCaptureEngine.StopCapture();
        IsPreviewVisible = true;
        IsRecording = false;
        PreviewError = message;
        PreviewTitle = "语音输入失败";
        PreviewMessage = "";
        LastErrorMessage = message;
        _isStartingSession = false;
        _isPendingStop = false;
        _isFinishRequested = false;
        _isSessionActive = false;
        IsSessionRunning = false;
        _activeProvider = null;
        _startingProvider = null;

        ScheduleDismiss(2.5);
    }

    private void DismissQuietly(string message)
    {
        Logger.Information("Dismissing quietly: {Message}", message);
        IsRecording = false;
        PreviewHint = message;
        PreviewTranscript = "";
        PreviewError = null;
        _isStartingSession = false;
        _isPendingStop = false;
        _isFinishRequested = false;
        _isSessionActive = false;
        IsSessionRunning = false;
        _audioCaptureEngine.StopCapture();
        _activeProvider = null;
        _startingProvider = null;

        ScheduleDismiss(1.2);
    }

    private void ScheduleDismiss(double delaySeconds)
    {
        _dismissCts?.Cancel();
        _dismissCts = new CancellationTokenSource();
        var token = _dismissCts.Token;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(delaySeconds), token);
                if (!token.IsCancellationRequested)
                {
                    IsPreviewVisible = false;
                    ResetPreviewState();
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Logger.Error(ex, "ScheduleDismiss task crashed");
            }
        }, token);
    }

    private void ResetPreviewState()
    {
        IsPreviewVisible = false;
        IsRecording = false;
        PreviewTitle = "";
        PreviewMessage = "";
        PreviewTranscript = "";
        PreviewError = null;
        PreviewHint = null;
        AudioLevel = 0;
        IsPostProcessing = false;
    }
}
