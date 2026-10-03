using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace BonRaffle;

public sealed partial class MainPage
{
    private readonly DispatcherTimer _introTimer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private DateTimeOffset? _introDeadline;
    private double _introRemaining;
    private int _introTotal;
    private bool _applyingCountdownSettings;
    private bool _countdownReady;

    private void InitializeCountdown()
    {
        _introTimer.Tick += (_, _) => TickIntroCountdown();
    }

    private void PageRoot_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateCountdownSize();

    private void UpdateCountdownSize()
    {
        var height = PageRoot.ActualHeight;
        var width = PageRoot.ActualWidth;
        var stageDiameter = Math.Clamp(Math.Min(width * 0.6, height * 0.59), 240, 440);
        StageCountdownViewbox.Width = stageDiameter;
        StageCountdownViewbox.Height = stageDiameter;
    }

    private void ApplyCountdownSettings()
    {
        UpdateCountdownSize();
        StageCountdownArc.Stroke = new SolidColorBrush(ParseColor(_settings.CountdownRingColor));
        StageCountdownCaption.Text = _settings.CountdownCaption;
        StageCountdownCaption.Visibility = string.IsNullOrEmpty(_settings.CountdownCaption) ? Visibility.Collapsed : Visibility.Visible;
        _applyingCountdownSettings = true;
        HomeTimerToggle.IsOn = _settings.ShowIntroCountdown;
        HomeTimerControls.Visibility = _settings.ShowIntroCountdown ? Visibility.Visible : Visibility.Collapsed;
        HomeTimerMinutes.Value = _settings.CountdownSeconds / 60;
        HomeTimerSeconds.Value = _settings.CountdownSeconds % 60;
        _applyingCountdownSettings = false;
    }

    private async void HomeTimerToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (!_countdownReady || _applyingCountdownSettings) return;
        HomeTimerControls.Visibility = HomeTimerToggle.IsOn ? Visibility.Visible : Visibility.Collapsed;
        _settings.ShowIntroCountdown = HomeTimerToggle.IsOn;
        try { await RaffleData.SaveSettingsAsync(_settings); }
        catch (Exception ex) { await ShowErrorAsync("Не удалось сохранить таймер", ex); }
    }

    private async void HomeTimerDuration_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_countdownReady || _applyingCountdownSettings || !TryReadHomeTimerDuration(out var total)) return;
        _settings.CountdownSeconds = total;
        try { await RaffleData.SaveSettingsAsync(_settings); }
        catch (Exception ex) { await ShowErrorAsync("Не удалось сохранить время таймера", ex); }
    }

    private bool TryReadHomeTimerDuration(out int total)
    {
        total = 0;
        var minutes = HomeTimerMinutes.Value;
        var seconds = HomeTimerSeconds.Value;
        if (!double.IsFinite(minutes) || !double.IsFinite(seconds) ||
            minutes != Math.Truncate(minutes) || seconds != Math.Truncate(seconds) ||
            minutes < 0 || minutes > 1440 || seconds < 0 || seconds > 59 ||
            minutes * 60 + seconds is < 10 or > 86400) return false;
        total = (int)(minutes * 60 + seconds);
        return true;
    }

    private async void StartHomeTimer_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning || _importOpening || !OpenRaffleButton.IsEnabled) return;
        if (!TryReadHomeTimerDuration(out var total))
        {
            await new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Время таймера",
                Content = "Укажите от 10 секунд до 24 часов.", CloseButtonText = "Понятно"
            }.ShowAsync();
            return;
        }
        _introTotal = total;
        _introRemaining = _introTotal;
        _settings.CountdownSeconds = _introTotal;
        ApplyCountdownSettings();
        try { await RaffleData.SaveSettingsAsync(_settings); }
        catch (Exception ex) { await ShowErrorAsync("Не удалось сохранить время таймера", ex); }
        _introDeadline = DateTimeOffset.UtcNow.AddSeconds(_introRemaining);
        _introTimer.Start();
        RenderIntroCountdown();
        ShowView("timer");
    }

    private void StagePause_Click(object sender, RoutedEventArgs e)
    {
        if (_introDeadline is not null)
        {
            _introRemaining = Math.Max(0, (_introDeadline.Value - DateTimeOffset.UtcNow).TotalSeconds);
            _introDeadline = null;
            _introTimer.Stop();
        }
        else if (_introRemaining > 0)
        {
            _introDeadline = DateTimeOffset.UtcNow.AddSeconds(_introRemaining);
            _introTimer.Start();
        }
        RenderIntroCountdown();
    }

    private void StageCountdownButton_PointerEntered(object sender, PointerRoutedEventArgs e)
        => StageCountdownHoverHint.Opacity = 1;

    private void StageCountdownButton_PointerExited(object sender, PointerRoutedEventArgs e)
        => StageCountdownHoverHint.Opacity = 0;

    private void TickIntroCountdown()
    {
        if (_introDeadline is null) return;
        _introRemaining = Math.Max(0, (_introDeadline.Value - DateTimeOffset.UtcNow).TotalSeconds);
        RenderIntroCountdown();
        if (_introRemaining > 0) return;
        _introTimer.Stop();
        _introDeadline = null;
        OpenRaffle_Click(StartHomeTimerButton, new RoutedEventArgs());
    }

    private void RenderIntroCountdown()
    {
        var seconds = (int)Math.Ceiling(_introRemaining);
        var displayTime = seconds >= 3600
            ? $"{seconds / 3600:00}:{seconds / 60 % 60:00}:{seconds % 60:00}"
            : $"{seconds / 60:00}:{seconds % 60:00}";
        if (StageCountdownTime.Text != displayTime) StageCountdownTime.Text = displayTime;
        var ratio = Math.Clamp(_introRemaining / Math.Max(1, _introTotal), 0, 1);
        const double circumferenceInStrokeWidths = 2 * Math.PI * 205 / 12;
        StageCountdownArc.StrokeDashArray = new DoubleCollection
        {
            ratio * circumferenceInStrokeWidths,
            (1 - ratio) * circumferenceInStrokeWidths
        };
        StageCountdownArc.Visibility = ratio <= 0 ? Visibility.Collapsed : Visibility.Visible;
        StageCountdownHintIcon.Symbol = _introDeadline is null ? Symbol.Play : Symbol.Pause;
        StageCountdownHintText.Text = _introDeadline is null ? "Продолжить" : "Пауза";
        StageCountdownHoverHint.Opacity = StageCountdownButton.IsPointerOver ? 1 : 0;
    }
}
