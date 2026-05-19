using System.Windows;
using GuGuTalk.Core.Services;

namespace GuGuTalk.App.Views;

public partial class OverlayWindow : Window
{
    private readonly RecognitionOrchestrator _orchestrator;

    public OverlayWindow(RecognitionOrchestrator orchestrator)
    {
        InitializeComponent();
        _orchestrator = orchestrator;

        _orchestrator.PropertyChanged += (_, e) =>
        {
            // BeginInvoke (vs Invoke) avoids potential deadlocks if multiple
            // property changes fire from a worker thread while the UI thread
            // is busy running another handler.
            Dispatcher.BeginInvoke(() => UpdateUI(e.PropertyName));
        };

        PositionBottomRight();
    }

    private void UpdateUI(string? propertyName)
    {
        switch (propertyName)
        {
            case nameof(RecognitionOrchestrator.IsPreviewVisible):
                if (_orchestrator.IsPreviewVisible)
                    Show();
                else
                    Hide();
                break;
            case nameof(RecognitionOrchestrator.PreviewTitle):
                TitleText.Text = _orchestrator.PreviewTitle;
                break;
            case nameof(RecognitionOrchestrator.PreviewTranscript):
                TranscriptText.Text = _orchestrator.PreviewTranscript;
                break;
            case nameof(RecognitionOrchestrator.PreviewMessage):
                StatusText.Text = _orchestrator.PreviewMessage;
                break;
            case nameof(RecognitionOrchestrator.PreviewError):
                if (_orchestrator.PreviewError is not null)
                {
                    StatusText.Text = _orchestrator.PreviewError;
                    StatusText.Foreground = (System.Windows.Media.Brush)FindResource("IconAquaBrush");
                }
                break;
            case nameof(RecognitionOrchestrator.IsRecording):
                RecordingDot.Visibility = _orchestrator.IsRecording ? Visibility.Visible : Visibility.Collapsed;
                Waveform.Visibility = _orchestrator.IsRecording ? Visibility.Visible : Visibility.Collapsed;
                break;
            case nameof(RecognitionOrchestrator.AudioLevel):
                Waveform.Level = _orchestrator.AudioLevel;
                Waveform.InvalidateVisual();
                break;
        }
    }

    private void PositionBottomRight()
    {
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - Width - 16;
        Top = workArea.Bottom - Height - 16;
    }
}
