using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using GuGuTalk.Core.Services;

namespace GuGuTalk.App.Views;

public partial class OverlayWindow : Window
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    private readonly RecognitionOrchestrator _orchestrator;

    public OverlayWindow(RecognitionOrchestrator orchestrator)
    {
        InitializeComponent();
        _orchestrator = orchestrator;

        _orchestrator.PropertyChanged += (_, e) =>
        {
            Dispatcher.BeginInvoke(() => UpdateUI(e.PropertyName));
        };

        PositionBottomRight();
    }

    /// <summary>
    /// Stamp WS_EX_NOACTIVATE so the overlay never takes focus when shown.
    /// Without this, Show() steals foreground from the user's app, and the
    /// clipboard paste (Ctrl+V) lands in our own overlay window instead of
    /// the editor where the cursor was — the bubble shows the recognised
    /// text but nothing reaches the cursor.
    /// </summary>
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
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
