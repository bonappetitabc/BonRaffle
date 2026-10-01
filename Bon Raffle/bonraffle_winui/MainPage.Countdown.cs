using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace BonRaffle;

public sealed partial class MainPage
{
    private readonly DispatcherTimer _countdownTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private DateTimeOffset? _countdownDeadline;
    private double _countdownRemaining;
    private int _countdownConfiguredSeconds;

    private void InitializeCountdown()
    {
        _countdownTimer.Tick += async (_, _) => await TickCountdownAsync();
    }

    private void PageRoot_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateCountdownSize();

    private void UpdateCountdownSize()
    {
        var height = PageRoot.ActualHeight;
        var width = PageRoot.ActualWidth;
        var roomy = height >= 850 || (_settings.Fullscreen && height >= 720);
        var diameter = roomy
            ? Math.Clamp(Math.Min(width * 0.14, height * 0.19), 132, 156)
            : 108;
        CountdownViewbox.Width = diameter;
        CountdownViewbox.Height = diameter;
    }

    private void ApplyCountdownSettings()
    {
        CountdownPanel.Visibility = _settings.ShowCountdown ? Visibility.Visible : Visibility.Collapsed;
        CountdownCaptionText.Text = _settings.CountdownCaption;
        UpdateCountdownSize();
        CountdownArc.Stroke = new SolidColorBrush(ParseColor(_settings.CountdownRingColor));
        if (!_settings.ShowCountdown)
        {
            _countdownDeadline = null;
            _countdownRemaining = _settings.CountdownSeconds;
            _countdownTimer.Stop();
        }
        if (_countdownConfiguredSeconds != _settings.CountdownSeconds)
        {
            _countdownConfiguredSeconds = _settings.CountdownSeconds;
            _countdownRemaining = _settings.CountdownSeconds;
            _countdownDeadline = null;
            _countdownTimer.Stop();
        }
        RenderCountdown();
    }

    private void Countdown_Click(object sender, RoutedEventArgs e)
    {
        if (_countdownDeadline is not null)
        {
            _countdownRemaining = Math.Max(0, (_countdownDeadline.Value - DateTimeOffset.UtcNow).TotalSeconds);
            _countdownDeadline = null;
            _countdownTimer.Stop();
        }
        else
        {
            if (_countdownRemaining <= 0) _countdownRemaining = _countdownConfiguredSeconds;
            _countdownDeadline = DateTimeOffset.UtcNow.AddSeconds(_countdownRemaining);
            _countdownTimer.Start();
        }
        RenderCountdown();
    }

    private async Task TickCountdownAsync()
    {
        if (_countdownDeadline is not null)
        {
            _countdownRemaining = Math.Max(0, (_countdownDeadline.Value - DateTimeOffset.UtcNow).TotalSeconds);
            if (_countdownRemaining <= 0)
            {
                _countdownDeadline = null;
                _countdownTimer.Stop();
                _settings.ShowCountdown = false;
                ApplyCountdownSettings();
                try { await RaffleData.SaveSettingsAsync(_settings); }
                catch (Exception ex) { await ShowErrorAsync("Не удалось сохранить выключение таймера", ex); }
                return;
            }
        }
        RenderCountdown();
    }

    private void RenderCountdown()
    {
        var seconds = (int)Math.Ceiling(_countdownRemaining);
        CountdownTime.Text = $"{seconds / 3600:00}:{seconds / 60 % 60:00}:{seconds % 60:00}";
        if (seconds < 3600) CountdownTime.Text = $"{seconds / 60:00}:{seconds % 60:00}";
        CountdownAction.Text = _countdownDeadline is null ? "Запустить" : "Пауза";

        var ratio = Math.Clamp(_countdownRemaining / Math.Max(1, _countdownConfiguredSeconds), 0, 1);
        const double circumferenceInStrokeWidths = 2 * Math.PI * 48 / 7;
        CountdownArc.StrokeDashArray = new DoubleCollection
        {
            ratio * circumferenceInStrokeWidths,
            (1 - ratio) * circumferenceInStrokeWidths
        };
        CountdownArc.Visibility = ratio <= 0 ? Visibility.Collapsed : Visibility.Visible;
    }
}
