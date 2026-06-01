using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
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

    private static readonly Duration ResizeDuration = new(TimeSpan.FromMilliseconds(140));
    private static readonly Duration BlurDuration = new(TimeSpan.FromMilliseconds(180));
    private static readonly IEasingFunction ResizeEasing = new CubicEase { EasingMode = EasingMode.EaseOut };

    private readonly RecognitionOrchestrator _orchestrator;
    private readonly DispatcherTimer _spinnerTimer;
    private readonly Typeface _transcriptTypeface;
    private double _spinnerAngle;
    private string _previousTranscript = "";

    public OverlayWindow(RecognitionOrchestrator orchestrator)
    {
        InitializeComponent();
        _orchestrator = orchestrator;

        _transcriptTypeface = new Typeface(
            TranscriptText.FontFamily,
            TranscriptText.FontStyle,
            FontWeights.SemiBold,
            TranscriptText.FontStretch);

        _spinnerTimer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16)
        };
        _spinnerTimer.Tick += (_, _) =>
        {
            _spinnerAngle = (_spinnerAngle + 6) % 360;
            SpinnerRotate.Angle = _spinnerAngle;
        };

        _orchestrator.PropertyChanged += (_, e) =>
        {
            Dispatcher.BeginInvoke(() => UpdateUI(e.PropertyName));
        };

        ApplyState(animate: false);
    }

    /// <summary>
    /// Stamp WS_EX_NOACTIVATE so the overlay never takes focus when shown.
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
                {
                    ApplyState(animate: false);
                    Show();
                    AnimateOpacityIn();
                }
                else
                {
                    Hide();
                }
                break;

            case nameof(RecognitionOrchestrator.PreviewTranscript):
                AnimateTranscriptBlur();
                ApplyState(animate: true);
                break;

            case nameof(RecognitionOrchestrator.PreviewError):
            case nameof(RecognitionOrchestrator.PreviewMessage):
            case nameof(RecognitionOrchestrator.IsRecording):
            case nameof(RecognitionOrchestrator.IsPostProcessing):
                ApplyState(animate: true);
                break;

            case nameof(RecognitionOrchestrator.AudioLevel):
                WaveformEmpty.Level = _orchestrator.AudioLevel;
                WaveformInline.Level = _orchestrator.AudioLevel;
                break;
        }
    }

    /// <summary>
    /// Pick the right state panel and animate the window to its target size.
    /// </summary>
    private void ApplyState(bool animate)
    {
        string transcript = _orchestrator.PreviewTranscript ?? "";
        string? error = _orchestrator.PreviewError;
        string message = _orchestrator.PreviewMessage ?? "";
        bool isRecording = _orchestrator.IsRecording;
        bool isPostProcessing = _orchestrator.IsPostProcessing;

        RecordingEmptyContent.Visibility = Visibility.Collapsed;
        RecordingTranscriptContent.Visibility = Visibility.Collapsed;
        PostProcessingContent.Visibility = Visibility.Collapsed;
        ErrorContent.Visibility = Visibility.Collapsed;
        HintContent.Visibility = Visibility.Collapsed;
        _spinnerTimer.Stop();

        Size target;
        if (!string.IsNullOrEmpty(error))
        {
            ErrorContent.Text = error;
            ErrorContent.Visibility = Visibility.Visible;
            target = MeasureTextSize(error, FontWeights.SemiBold, 12.5, minWidth: 220, maxWidth: 292,
                horizontalPadding: 32, verticalPadding: 20, minHeight: 58);
        }
        else if (isPostProcessing)
        {
            PostProcessingContent.Visibility = Visibility.Visible;
            _spinnerTimer.Start();
            target = new Size(140, 42);
        }
        else if (isRecording && string.IsNullOrEmpty(transcript))
        {
            RecordingEmptyContent.Visibility = Visibility.Visible;
            target = new Size(126, 40);
        }
        else if (!string.IsNullOrEmpty(transcript))
        {
            TranscriptText.Text = transcript;
            RecordingTranscriptContent.Visibility = Visibility.Visible;
            target = MeasureTranscriptSize(transcript);
        }
        else if (!string.IsNullOrEmpty(message))
        {
            HintContent.Text = message;
            HintContent.Visibility = Visibility.Visible;
            target = MeasureTextSize(message, FontWeights.Normal, 12.5, minWidth: 160, maxWidth: 240,
                horizontalPadding: 26, verticalPadding: 16, minHeight: 38);
        }
        else
        {
            // Default fallback
            target = new Size(126, 40);
        }

        AnimateSize(target, animate);
    }

    /// <summary>
    /// Estimate the size needed to host a transcript: width grows with text
    /// length up to 430, then wraps onto 2-3 lines.
    /// </summary>
    private Size MeasureTranscriptSize(string text)
    {
        const double minWidth = 220;
        const double maxWidth = 430;
        const double horizontalPadding = 88; // 20 left margin + 8 right + 44 waveform + 16 right margin
        const double verticalPadding = 24;   // 12 top + 12 bottom

        var formatted = new FormattedText(
            text,
            CultureInfo.CurrentCulture,
            FlowDirection.LeftToRight,
            _transcriptTypeface,
            14.5,
            Brushes.Black,
            VisualTreeHelper.GetDpi(this).PixelsPerDip)
        {
            MaxTextWidth = maxWidth - horizontalPadding,
            Trimming = TextTrimming.CharacterEllipsis,
            MaxLineCount = 3
        };

        double width = Math.Clamp(formatted.WidthIncludingTrailingWhitespace + horizontalPadding, minWidth, maxWidth);
        double height = Math.Max(60, formatted.Height + verticalPadding);
        return new Size(width, Math.Min(height, 110));
    }

    private Size MeasureTextSize(
        string text, FontWeight weight, double fontSize,
        double minWidth, double maxWidth,
        double horizontalPadding, double verticalPadding,
        double minHeight)
    {
        var typeface = new Typeface(
            new FontFamily("Segoe UI"),
            FontStyles.Normal, weight, FontStretches.Normal);
        var formatted = new FormattedText(
            text,
            CultureInfo.CurrentCulture,
            FlowDirection.LeftToRight,
            typeface,
            fontSize,
            Brushes.Black,
            VisualTreeHelper.GetDpi(this).PixelsPerDip)
        {
            MaxTextWidth = maxWidth - horizontalPadding,
            Trimming = TextTrimming.CharacterEllipsis,
            MaxLineCount = 2
        };
        double width = Math.Clamp(formatted.WidthIncludingTrailingWhitespace + horizontalPadding, minWidth, maxWidth);
        double height = Math.Max(minHeight, formatted.Height + verticalPadding);
        return new Size(width, height);
    }

    private void AnimateSize(Size target, bool animate)
    {
        if (!animate)
        {
            BeginAnimation(WidthProperty, null);
            BeginAnimation(HeightProperty, null);
            Width = target.Width;
            Height = target.Height;
            PositionTopCenter();
            return;
        }

        var widthAnim = new DoubleAnimation
        {
            To = target.Width,
            Duration = ResizeDuration,
            EasingFunction = ResizeEasing
        };
        var heightAnim = new DoubleAnimation
        {
            To = target.Height,
            Duration = ResizeDuration,
            EasingFunction = ResizeEasing
        };

        // Reposition continuously while width changes so the window stays centered.
        widthAnim.CurrentTimeInvalidated += (_, _) => PositionTopCenter();

        BeginAnimation(WidthProperty, widthAnim);
        BeginAnimation(HeightProperty, heightAnim);
    }

    private void AnimateTranscriptBlur()
    {
        string current = _orchestrator.PreviewTranscript ?? "";
        if (current == _previousTranscript) return;
        _previousTranscript = current;

        var blurAnim = new DoubleAnimation
        {
            From = 1.2,
            To = 0,
            Duration = BlurDuration,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        TranscriptBlur.BeginAnimation(BlurEffect.RadiusProperty, blurAnim);
    }

    private void PositionTopCenter()
    {
        var workArea = SystemParameters.WorkArea;
        double width = ActualWidth > 0 ? ActualWidth : Width;
        if (double.IsNaN(width) || width <= 0) return;
        Left = workArea.Left + (workArea.Width - width) / 2;
        Top = workArea.Top + 80;
    }

    private void AnimateOpacityIn()
    {
        Opacity = 0;
        var fade = new DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = TimeSpan.FromMilliseconds(180),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        BeginAnimation(OpacityProperty, fade);
    }
}
