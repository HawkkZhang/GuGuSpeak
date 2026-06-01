using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace GuGuTalk.App.Views.Controls;

/// <summary>
/// Sine-wave waveform meter inspired by the macOS overlay: bars in the
/// center are emphasized, opacity rises with audio level, and motion is
/// continuous (driven by a 60 Hz timer) so the bars feel organic even
/// during silence.
/// </summary>
public sealed class WaveformMeter : Control
{
    public static readonly DependencyProperty LevelProperty =
        DependencyProperty.Register(nameof(Level), typeof(float), typeof(WaveformMeter),
            new FrameworkPropertyMetadata(0f, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty BarBrushProperty =
        DependencyProperty.Register(nameof(BarBrush), typeof(Brush), typeof(WaveformMeter),
            new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty BarCountProperty =
        DependencyProperty.Register(nameof(BarCount), typeof(int), typeof(WaveformMeter),
            new FrameworkPropertyMetadata(8, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty CompactProperty =
        DependencyProperty.Register(nameof(Compact), typeof(bool), typeof(WaveformMeter),
            new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    public float Level
    {
        get => (float)GetValue(LevelProperty);
        set => SetValue(LevelProperty, value);
    }

    public Brush BarBrush
    {
        get => (Brush)GetValue(BarBrushProperty);
        set => SetValue(BarBrushProperty, value);
    }

    public int BarCount
    {
        get => (int)GetValue(BarCountProperty);
        set => SetValue(BarCountProperty, value);
    }

    public bool Compact
    {
        get => (bool)GetValue(CompactProperty);
        set => SetValue(CompactProperty, value);
    }

    private readonly DispatcherTimer _timer;
    private readonly DateTime _epoch = DateTime.UtcNow;

    static WaveformMeter()
    {
        DefaultStyleKeyProperty.OverrideMetadata(
            typeof(WaveformMeter),
            new FrameworkPropertyMetadata(typeof(WaveformMeter)));
    }

    public WaveformMeter()
    {
        _timer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16)
        };
        _timer.Tick += (_, _) => InvalidateVisual();
        IsVisibleChanged += (_, e) =>
        {
            if ((bool)e.NewValue) _timer.Start();
            else _timer.Stop();
        };
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);

        double w = ActualWidth;
        double h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        int barCount = Math.Max(2, BarCount);
        double barWidth = 3;
        double spacing = Compact ? 3 : 2.5;
        double totalWidth = barWidth * barCount + spacing * (barCount - 1);
        double startX = (w - totalWidth) / 2;

        double baseHeight = 4;
        double levelGain = Compact ? 13 : 11;
        double motionGain = Compact ? 6 : 5;

        float level = Math.Clamp(Level, 0f, 1f);
        double t = (DateTime.UtcNow - _epoch).TotalSeconds;

        for (int i = 0; i < barCount; i++)
        {
            // Center emphasis: bars near the middle peak higher
            double centerOffset = Math.Abs(i - (barCount - 1) / 2.0) / ((barCount - 1) / 2.0);
            double centerEmphasis = 1.0 - centerOffset;

            // Continuous sine motion so silence still breathes
            double phase = Math.Sin(t * 5.2 + i * 0.72);
            double motion = (phase + 1) / 2.0; // 0..1

            double barHeight = baseHeight
                + level * levelGain * (0.6 + 0.4 * centerEmphasis)
                + motion * motionGain * (0.4 + 0.6 * centerEmphasis);

            barHeight = Math.Min(barHeight, h);

            double opacity = 0.30 + level * 0.42 + centerEmphasis * 0.22;
            opacity = Math.Clamp(opacity, 0.30, 0.95);

            double x = startX + i * (barWidth + spacing);
            double y = (h - barHeight) / 2;

            var brush = BarBrush.Clone();
            brush.Opacity = opacity;
            brush.Freeze();

            var rect = new Rect(x, y, barWidth, barHeight);
            dc.DrawRoundedRectangle(brush, null, rect, barWidth / 2, barWidth / 2);
        }
    }
}
