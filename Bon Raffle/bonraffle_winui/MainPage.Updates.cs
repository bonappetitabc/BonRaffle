using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BonRaffle;

public sealed partial class MainPage
{
    private sealed class UpdatePreferences
    {
        public bool Automatic { get; set; } = true;
        public DateTimeOffset LastAttempt { get; set; }
        public bool SystemNotifications { get; set; }
        public string NotifiedVersion { get; set; } = "";
    }

    private static readonly HttpClient UpdateHttp = new() { Timeout = TimeSpan.FromMinutes(15) };
    private readonly AppUpdateClient _updates = new(UpdateHttp);
    private UpdatePreferences _updatePreferences = new();
    private AppRelease? _updateRelease;
    private bool _updateBusy;
    private string _updateStatus = "Нажмите «Проверить обновления».";
    private string? _updateFile;
    private double _updateProgress;
    private CancellationTokenSource? _updateDownload;
    private event Action? UpdateStateChanged;
    private Window? _updateWindow;
    public static MainPage? Current { get; private set; }
    private static Version CurrentAppVersion => typeof(MainPage).Assembly.GetName().Version is { } v
        ? new Version(v.Major, v.Minor, v.Build) : new Version(2, 3, 0);
    private string UpdatePreferencesPath => Path.Combine(RaffleData.DirectoryPath, "update-preferences.json");

    private async Task InitializeUpdatesAsync()
    {
        Current = this;
        try
        {
            if (File.Exists(UpdatePreferencesPath))
                _updatePreferences = JsonSerializer.Deserialize<UpdatePreferences>(await File.ReadAllTextAsync(UpdatePreferencesPath)) ?? new();
        }
        catch { _updatePreferences = new(); }
        if (_updatePreferences.Automatic &&
            (DateTimeOffset.UtcNow - _updatePreferences.LastAttempt >= TimeSpan.FromDays(1) ||
             _updatePreferences.LastAttempt > DateTimeOffset.UtcNow))
            await CheckForUpdatesAsync();
    }

    private async Task SaveUpdatePreferencesAsync()
    {
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        var temporary = UpdatePreferencesPath + ".tmp";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(_updatePreferences));
        File.Move(temporary, UpdatePreferencesPath, true);
    }

    private void UpdateChanged()
    {
        UpdateNotice.IsOpen = _updateRelease is not null;
        UpdateNotice.Title = _updateRelease is null ? "" : $"Доступна Bon Raffle {_updateRelease.Version}";
        UpdateStateChanged?.Invoke();
    }

    private async Task CheckForUpdatesAsync()
    {
        if (_updateBusy) return;
        _updateBusy = true;
        _updateStatus = "Проверяем выпуски GitHub…";
        UpdateChanged();
        try
        {
            _updatePreferences.LastAttempt = DateTimeOffset.UtcNow;
            await SaveUpdatePreferencesAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var release = await _updates.FindAsync("windows", CurrentAppVersion, timeout.Token);
            if (_updateRelease?.Version != release?.Version) _updateFile = null;
            _updateRelease = release;
            _updateStatus = release is null ? "У вас последняя версия для Windows." : $"Доступна версия {release.Version}.";
            await NotifyUpdateAsync();
        }
        catch (OperationCanceledException) { _updateStatus = "GitHub не ответил вовремя. Повторите проверку позже."; }
        catch (Exception) { _updateStatus = "Не удалось проверить обновления. Проверьте подключение и повторите попытку."; }
        finally { _updateBusy = false; UpdateChanged(); }
    }

    private StackPanel BuildUpdatePanel()
    {
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = $"Обновления · версия {CurrentAppVersion}", FontSize = 20 });
        var automatic = new ToggleSwitch { Header = "Проверять автоматически при запуске", IsOn = _updatePreferences.Automatic };
        var notifications = new ToggleSwitch { Header = "Системные уведомления о новой версии", IsOn = _updatePreferences.SystemNotifications };
        var notificationStatus = new TextBlock { Text = "Системные уведомления Windows недоступны. Обновления будут показаны в приложении.",
            TextWrapping = TextWrapping.Wrap, Visibility = App.NotificationsAvailable ? Visibility.Collapsed : Visibility.Visible };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var notes = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxHeight = 180 };
        var notesScroll = new ScrollViewer { Content = notes, MaxHeight = 180 };
        var progress = new ProgressBar { Minimum = 0, Maximum = 100 };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var check = new Button { Content = "Проверить обновления" };
        var download = new Button { Content = "Скачать обновление" };
        var cancel = new Button { Content = "Отменить загрузку" };
        var install = new Button { Content = "Закрыть Bon Raffle и запустить установщик" };
        var releaseLink = new HyperlinkButton { Content = "Открыть выпуск на GitHub" };
        actions.Children.Add(check); actions.Children.Add(download); actions.Children.Add(cancel);
        panel.Children.Add(automatic); panel.Children.Add(notifications); panel.Children.Add(status); panel.Children.Add(notesScroll);
        panel.Children.Insert(3, notificationStatus);
        panel.Children.Add(progress); panel.Children.Add(actions); panel.Children.Add(install); panel.Children.Add(releaseLink);
        panel.Children.Add(new TextBlock { Text = "Проверка при запуске — не чаще раза в сутки. Установка запускается после вашего нажатия; списки и настройки хранятся отдельно.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75 });
        void Refresh()
        {
            status.Text = _updateStatus;
            automatic.IsEnabled = !_updateBusy;
            notifications.IsEnabled = !_updateBusy;
            notes.Text = _updateRelease?.Notes ?? "";
            notesScroll.Visibility = notes.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            check.IsEnabled = !_updateBusy;
            download.Visibility = _updateRelease is not null && _updateFile is null ? Visibility.Visible : Visibility.Collapsed;
            download.IsEnabled = !_updateBusy && _updateRelease?.Sha256.Length == 64;
            cancel.Visibility = _updateDownload is not null ? Visibility.Visible : Visibility.Collapsed;
            install.Visibility = _updateFile is not null ? Visibility.Visible : Visibility.Collapsed;
            install.IsEnabled = !_updateBusy && !_spinning;
            releaseLink.NavigateUri = _updateRelease?.Page ?? new Uri(AppUpdateClient.Repository + "/releases");
            progress.Visibility = _updateDownload is not null ? Visibility.Visible : Visibility.Collapsed;
            progress.Value = _updateProgress * 100;
        }
        panel.Loaded += (_, _) => { UpdateStateChanged += Refresh; Refresh(); };
        panel.Unloaded += (_, _) => UpdateStateChanged -= Refresh;
        automatic.Toggled += async (_, _) =>
        {
            _updatePreferences.Automatic = automatic.IsOn;
            try { await SaveUpdatePreferencesAsync(); }
            catch { _updateStatus = "Не удалось сохранить настройку проверки обновлений."; UpdateChanged(); }
        };
        check.Click += async (_, _) => await CheckForUpdatesAsync();
        notifications.Toggled += async (_, _) =>
        {
            _updatePreferences.SystemNotifications = notifications.IsOn;
            try
            {
                await SaveUpdatePreferencesAsync();
                if (notifications.IsOn && !App.NotificationsAvailable)
                    _updateStatus = "Системные уведомления Windows недоступны. Обновления будут показаны в приложении.";
                else await NotifyUpdateAsync();
            }
            catch { _updateStatus = "Не удалось сохранить настройку уведомлений."; }
            UpdateChanged();
        };
        download.Click += async (_, _) => await DownloadUpdateAsync();
        cancel.Click += (_, _) => _updateDownload?.Cancel();
        install.Click += async (_, _) => await InstallUpdateAsync();
        Refresh();
        return panel;
    }

    private async Task DownloadUpdateAsync()
    {
        if (_updateBusy || _updateRelease is not { } release) return;
        _updateBusy = true;
        _updateProgress = 0;
        _updateStatus = "Скачиваем обновление…";
        using var cancel = new CancellationTokenSource();
        _updateDownload = cancel;
        UpdateChanged();
        try
        {
            // The shell Downloads folder also respects a user's redirected location.
            var downloads = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            using (var shell = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
                downloads = Environment.ExpandEnvironmentVariables(shell?.GetValue("{374DE290-123F-4565-9164-39C4925E467B}") as string
                    ?? Path.Combine(downloads, "Downloads"));
            _updateFile = await _updates.DownloadAsync(release, downloads,
                new Progress<double>(value => { if (_updateDownload is null) return; _updateProgress = value; _updateStatus = $"Скачивание: {value:P0}"; UpdateChanged(); }), cancel.Token);
            _updateStatus = "Файл скачан и проверен. Можно запустить установщик.";
        }
        catch (OperationCanceledException) { _updateStatus = "Загрузка отменена. Можно скачать заново."; }
        catch (Exception) { _updateStatus = "Не удалось скачать или проверить файл. Повторите загрузку либо откройте выпуск на GitHub."; }
        finally { _updateDownload = null; _updateBusy = false; UpdateChanged(); }
    }

    private async Task InstallUpdateAsync()
    {
        if (_updateBusy || _spinning || _updateFile is not { } path || _updateRelease is not { } release) return;
        _updateBusy = true;
        _updateStatus = "Проверяем установщик…";
        UpdateChanged();
        try
        {
            await AppUpdateClient.VerifyAsync(path, release);
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, Verb = "runas" });
            _updateWindow?.Close();
            Application.Current.Exit();
        }
        catch (InvalidDataException) { _updateFile = null; _updateStatus = "Скачанный файл изменился. Скачайте его заново."; }
        catch (Exception) { _updateStatus = "Установка не запущена. Запрос Windows можно повторить."; }
        finally { _updateBusy = false; UpdateChanged(); }
    }

    private void ShowUpdates_Click(object sender, RoutedEventArgs e)
        => OpenUpdatesWindow();

    public void OpenUpdatesWindow()
    {
        if (_updateWindow is not null) { _updateWindow.Activate(); return; }
        _updateWindow = new Window { Title = "Обновления — Bon Raffle", Content = new ScrollViewer
            { Content = BuildUpdatePanel(), Padding = new Thickness(24) } };
        _updateWindow.AppWindow.Resize(new Windows.Graphics.SizeInt32(720, 570));
        _updateWindow.Closed += (_, _) => _updateWindow = null;
        _updateWindow.Activate();
    }

    private async Task NotifyUpdateAsync()
    {
        if (!_updatePreferences.SystemNotifications || !App.NotificationsAvailable || _updateRelease is not { } release ||
            HomeView.Visibility != Visibility.Visible || _updatePreferences.NotifiedVersion == release.Version.ToString()) return;
        try
        {
            var notifier = Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat.CreateToastNotifier();
            if (notifier.Setting != Windows.UI.Notifications.NotificationSetting.Enabled) return;
            var content = new Microsoft.Toolkit.Uwp.Notifications.ToastContentBuilder()
                .AddArgument("action", "updates")
                .AddText($"Доступна Bon Raffle {release.Version}")
                .AddText("Откройте приложение, чтобы посмотреть изменения и скачать обновление.")
                .GetToastContent();
            var notification = new Windows.UI.Notifications.ToastNotification(content.GetXml())
                { Tag = "update", Group = "releases", ExpirationTime = DateTimeOffset.Now.AddDays(3) };
            notifier.Show(notification);
            _updatePreferences.NotifiedVersion = release.Version.ToString();
            await SaveUpdatePreferencesAsync();
        }
        catch { /* The in-app update notice remains available. */ }
    }
}
