using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using Windows.UI;

namespace BonRaffle;

public sealed partial class MainPage : Page
{
    private readonly List<Border> _slotBorders = [];
    private readonly List<TextBlock> _slotNames = [];
    private readonly List<Image> _slotImages = [];
    private readonly Dictionary<Image, TextBlock> _giftIcons = [];
    private readonly AvatarCache _avatarFiles = new();
    private readonly DispatcherTimer _avatarProgressTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private double _avatarDisplayedProgress;
    private double _avatarTargetProgress;
    private int _avatarUpdateQueued;
    private int _avatarObservedBatchGeneration;
    private readonly Dictionary<Image, string> _avatarRequests = [];
    private readonly Dictionary<string, BitmapImage> _avatarCache = [];
    private readonly Dictionary<Canvas, Storyboard> _layerAnimations = [];
    private Storyboard? _winnerEntranceAnimation;
    private readonly TranslateTransform _slotTransform = new();
    private List<Member> _members = [];
    private readonly HashSet<string> _winnerIds = new(StringComparer.Ordinal);
    private List<Member> _visualPool = [];
    private RaffleSettings _settings = new();
    private Member? _winner;
    private bool _spinning;
    private bool _settingsOpening;
    private bool _avatarDialogOpening;
    private bool _importOpening;
    private bool _maxExporting;
    private bool _raffleActive;
    private double _offset;
    private long _spinStartedAt;
    private double _spinStartOffset;
    private int _spinTargetSteps;
    private int _spinStepsDone;
    private bool _finishQueued;
    private long _lastFrame;
    private int _poolPosition;
    private const double SlotPitch = 70;
    private const double SpinTravelArea = 113.4 + 1150.0 * 0.44 + 1150.0 * 0.38 / 2.8;

    public MainPage()
    {
        Current = this;
        InitializeComponent();
        ApplyPrimaryButtonColors(ParseColor("#D2691E"));
        InitializeCountdown();
        _avatarFiles.ActivityChanged += AvatarActivityChanged;
        _avatarProgressTimer.Tick += (_, _) => TickAvatarProgress();
        Slots.RenderTransform = _slotTransform;
        Loaded += async (_, _) => await InitializeAsync();
        Unloaded += (_, _) =>
        {
            StopRendering();
            _countdownTimer.Stop();
            foreach (var layer in _layerAnimations.Keys.ToArray()) StopLayerAnimation(layer);
            _winnerEntranceAnimation?.Stop();
        };
    }

    private async Task InitializeAsync()
    {
        try
        {
            RaffleData.MigrateLegacyData();
            await DemoData.SeedIfNeededAsync();
            _settings = await RaffleData.LoadSettingsAsync();
            _members = await RaffleData.LoadMembersAsync();
            var history = await RaffleData.LoadWinnerHistoryAsync();
            if (history.ListFingerprint == RaffleData.Fingerprint(_members))
                _winnerIds.UnionWith(history.Ids.Intersect(_members.Select(m => m.Id)));
            var manualCatalog = await ManualRoster.LoadCatalogAsync();
            var activeManual = manualCatalog.Lists.FirstOrDefault(p => p.Id == manualCatalog.ActiveId);
            if (activeManual is not null && RaffleData.Fingerprint(activeManual.Members) == RaffleData.Fingerprint(_members))
                FileStatus.Text = $"Свой список «{activeManual.Name}»";
            await RestoreRaffleModeAsync();
            ApplySettings();
            UpdateCount();
            FocusPrimaryAction();
            if (_members.Count > 0) _avatarFiles.StartBatch(_members.Select(m => m.Avatar));
            if (_settings.Fullscreen) SetFullscreen(true);
            _ = InitializeUpdatesAsync();
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось прочитать данные", ex); }
    }

    private void UpdateCount()
    {
        if (_prizeMode)
        {
            var available = _prizes.Count(p => p.Quantity > 0);
            var remaining = _prizes.Sum(p => p.Quantity);
            MemberCount.Text = $"{available:N0} видов призов";
            RaffleCount.Text = available.ToString("N0", new CultureInfo("ru-RU"));
            OpenRaffleButton.IsEnabled = available > 0;
            AgainButton.IsEnabled = available > 0;
            AgainButton.Content = available > 0 ? "Разыграть ещё один приз" : "Призы закончились";
            FileStatus.Text = available > 0
                ? $"Список «{_activePrizeListName}» · Осталось призов: {remaining:N0}"
                : $"В списке «{_activePrizeListName}» доступных призов нет. Измените количество.";
            ApplyModeUI();
            return;
        }
        var count = _members.Count.ToString("N0", new System.Globalization.CultureInfo("ru-RU"));
        MemberCount.Text = $"{count} участников";
        RaffleCount.Text = (_members.Count - _winnerIds.Count).ToString("N0", new System.Globalization.CultureInfo("ru-RU"));
        OpenRaffleButton.IsEnabled = _members.Count > _winnerIds.Count;
        AgainButton.IsEnabled = _members.Count > _winnerIds.Count;
        AgainButton.Content = AgainButton.IsEnabled ? "Провести ещё один розыгрыш" : "Все участники выиграли";
        if (_members.Count > 0)
            FileStatus.Text = _members.Count == _winnerIds.Count
                ? "Все участники уже выиграли. Загрузите новый список."
                : _winnerIds.Count > 0
                    ? $"Могут выиграть: {_members.Count - _winnerIds.Count:N0} · Уже выиграли: {_winnerIds.Count:N0}"
                    : "Загружен последний список участников";
        ApplyModeUI();
    }

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (_importOpening || _maxExporting || _spinning) return;
        _importOpening = true;
        ImportButton.IsEnabled = false;
        MaxExportButton.IsEnabled = false;
        OpenRaffleButton.IsEnabled = false;
        var completed = false;
        var stage = "Открытие окна выбора файла";
        try
        {
            var file = PickMemberFile();
            if (file is null) return;
            if (_settings.ConfirmReplace && _members.Count > 0)
            {
                var confirmation = new ContentDialog
                {
                    XamlRoot = XamlRoot, Title = "Заменить список участников?",
                    Content = $"Сейчас сохранено {_members.Count:N0} участников. Новый файл заменит этот список.",
                    PrimaryButtonText = "Заменить", CloseButtonText = "Отмена"
                };
                if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
            }
            ImportProgress.Visibility = Visibility.Visible;
            ImportProgress.IsActive = true;
            FileStatus.Text = "Читаю файл…";
            stage = "Чтение CSV";
            var imported = await Task.Run(() => RaffleData.Import(file.Value.Path));
            stage = "Сохранение списка";
            await RaffleData.SaveMembersAsync(imported);
            await RaffleData.SaveWinnerHistoryAsync(new WinnerHistory { ListFingerprint = RaffleData.Fingerprint(imported) });
            await ManualRoster.DeactivateAsync();
            _members = imported;
            _participantMembers = imported;
            _participantWinnerIds.Clear();
            _prizeMode = false;
            _settings.RaffleMode = "participants";
            await RaffleData.SaveSettingsAsync(_settings);
            _winnerIds.Clear();
            UpdateCount();
            FileStatus.Text = $"Загружено из {file.Value.Name}: {_members.Count:N0} участников";
            _avatarFiles.StartBatch(imported.Select(m => m.Avatar));
            completed = true;
        }
        catch (Exception ex)
        {
            WriteImportDiagnostic(stage, ex);
            await ShowErrorAsync("Не удалось загрузить список", ex);
        }
        finally
        {
            _importOpening = false;
            ImportButton.IsEnabled = true;
            MaxExportButton.IsEnabled = true;
            ImportProgress.IsActive = false;
            ImportProgress.Visibility = Visibility.Collapsed;
            if (!completed) UpdateCount();
        }
    }

    private async void ManualList_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning || _importOpening) return;
        try
        {
            var catalog = await ManualRoster.LoadCatalogAsync();
            if (catalog.Lists.Count == 0)
                catalog.Lists.Add(new ManualListProfile { Id = "list-" + Guid.NewGuid().ToString("N"), Name = "Мой список" });
            var currentId = catalog.Lists.FirstOrDefault(p => p.Id == catalog.ActiveId)?.Id ?? catalog.Lists[0].Id;
            var entries = catalog.Lists.First(p => p.Id == currentId).Members.Select(m => new Member
            { Id = m.Id, Name = m.Name, Username = m.Username, Avatar = m.Avatar }).ToList();
            var profilePicker = new ComboBox { Header = "Выберите свой список", HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var profile in catalog.Lists)
                profilePicker.Items.Add(new ComboBoxItem { Content = profile.Name, Tag = profile.Id });
            var profileNameBox = new TextBox { Header = "Название списка", Text = catalog.Lists.First(p => p.Id == currentId).Name,
                PlaceholderText = "Например, День рождения или Новый год" };
            var createProfile = new Button { Content = "Новый список" };
            var deleteProfile = new Button { Content = "Удалить список" };
            var restartProfile = new Button { Content = "Начать этот список заново" };
            var nameBox = new TextBox { Header = "Имя или название", PlaceholderText = "Например, Вася Петров или приз № 1" };
            var photoStatus = new TextBlock { Text = "Без картинки — аватар по умолчанию", Opacity = 0.75 };
            var preview = new Image { Width = 60, Height = 60, Stretch = Stretch.UniformToFill,
                Source = AvatarBitmap(PlaceholderSource) };
            var message = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
            var list = new ListView { Height = 340, SelectionMode = ListViewSelectionMode.Single };
            var choosePhoto = new Button { Content = "Выбрать картинку…" };
            var clearPhoto = new Button { Content = "Без картинки" };
            var add = new Button { Content = "Добавить запись", Background = new SolidColorBrush(ParseColor("#D2691E")),
                Foreground = new SolidColorBrush(Colors.White) };
            var update = new Button { Content = "Сохранить изменения", IsEnabled = false };
            var remove = new Button { Content = "Удалить выбранного", IsEnabled = false };
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Мой список участников",
                PrimaryButtonText = "Сохранить и использовать", CloseButtonText = "Отмена"
            };
            var dialogWidth = Math.Min(920, Math.Max(440, XamlRoot.Size.Width - 48));
            dialog.Resources["ContentDialogMaxWidth"] = dialogWidth;
            string? pendingPhoto = null;
            void ShowPhoto(string? source)
            {
                pendingPhoto = source;
                var path = ManualRoster.LocalPhoto(source) ?? source;
                if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
                photoStatus.Text = !string.IsNullOrWhiteSpace(path) && File.Exists(path)
                    ? Path.GetFileName(path) : "Без картинки — аватар по умолчанию";
                preview.Source = !string.IsNullOrWhiteSpace(path) && File.Exists(path)
                    ? new BitmapImage(new Uri(path)) : AvatarBitmap(PlaceholderSource);
            }
            void Refresh(int selected = -1)
            {
                list.Items.Clear();
                for (var i = 0; i < entries.Count; i++)
                {
                    var member = entries[i];
                    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                    var photo = new Image { Width = 40, Height = 40, Stretch = Stretch.UniformToFill };
                    var photoPath = ManualRoster.LocalPhoto(member.Avatar) ?? member.Avatar;
                    if (Uri.TryCreate(photoPath, UriKind.Absolute, out var photoUri) && photoUri.IsFile)
                        photoPath = photoUri.LocalPath;
                    photo.Source = !string.IsNullOrWhiteSpace(photoPath) && File.Exists(photoPath)
                        ? new BitmapImage(new Uri(photoPath)) : AvatarBitmap(PlaceholderSource);
                    var photoFrame = RoundAvatarFrame(photo, 40);
                    var labels = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
                    labels.Children.Add(new TextBlock { Text = member.Name, FontSize = 15,
                        TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 280 });
                    labels.Children.Add(new TextBlock { Text = member.Avatar.Length > 0 ? "Своя картинка" : "Аватар по умолчанию",
                        FontSize = 11, Opacity = 0.65 });
                    row.Children.Add(photoFrame); row.Children.Add(labels);
                    list.Items.Add(row);
                }
                list.SelectedIndex = selected;
                update.IsEnabled = selected >= 0;
                remove.IsEnabled = selected >= 0;
                restartProfile.IsEnabled = catalog.Lists.FirstOrDefault(p => p.Id == currentId)?.WinnerIds.Count > 0;
                dialog.IsPrimaryButtonEnabled = entries.Count > 0 || nameBox.Text.Trim().Length > 0;
                message.Text = "Этот список хранится в папке данных Bon Raffle. При переключении история победителей каждого списка сохраняется.";
            }
            void StashCurrent()
            {
                var profile = catalog.Lists.FirstOrDefault(p => p.Id == currentId);
                if (profile is null) return;
                profile.Name = profileNameBox.Text;
                profile.Members = entries;
                var ids = entries.Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
                profile.WinnerIds = profile.WinnerIds.Where(ids.Contains).ToList();
                var item = profilePicker.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string?)i.Tag == currentId);
                if (item is not null) item.Content = profile.Name;
            }
            profilePicker.SelectionChanged += (_, _) =>
            {
                if (profilePicker.SelectedItem is not ComboBoxItem item || item.Tag is not string id || id == currentId) return;
                StashCurrent();
                currentId = id;
                var profile = catalog.Lists.First(p => p.Id == id);
                profileNameBox.Text = profile.Name;
                entries = profile.Members.Select(m => new Member
                { Id = m.Id, Name = m.Name, Username = m.Username, Avatar = m.Avatar }).ToList();
                nameBox.Text = ""; ShowPhoto(null); Refresh();
            };
            createProfile.Click += (_, _) =>
            {
                StashCurrent();
                var number = 1;
                while (catalog.Lists.Any(p => p.Name.Equals($"Мой список {number}", StringComparison.OrdinalIgnoreCase))) number++;
                var profile = new ManualListProfile { Id = "list-" + Guid.NewGuid().ToString("N"), Name = $"Мой список {number}" };
                catalog.Lists.Add(profile);
                profilePicker.Items.Add(new ComboBoxItem { Content = profile.Name, Tag = profile.Id });
                profilePicker.SelectedIndex = profilePicker.Items.Count - 1;
            };
            restartProfile.Click += (_, _) =>
            {
                StashCurrent();
                var profile = catalog.Lists.FirstOrDefault(p => p.Id == currentId);
                if (profile is null) return;
                profile.WinnerIds.Clear();
                restartProfile.IsEnabled = false;
                message.Text = "Результаты этого списка сброшены. Нажмите «Сохранить и использовать», чтобы начать розыгрыш заново.";
            };
            deleteProfile.Click += async (_, _) =>
            {
                if (catalog.Lists.Count == 1)
                {
                    try
                    {
                        var removed = catalog.Lists[0];
                        var wasActive = catalog.ActiveId == removed.Id &&
                            RaffleData.Fingerprint(removed.Members) == RaffleData.Fingerprint(_members);
                        catalog.Lists.Clear(); catalog.ActiveId = null;
                        await ManualRoster.SaveCatalogAsync(catalog);
                        foreach (var member in removed.Members)
                        {
                            var image = ManualRoster.LocalPhoto(member.Avatar);
                            if (image is not null) File.Delete(image);
                        }
                        if (wasActive)
                        {
                            _members = []; _participantMembers = [];
                            _winnerIds.Clear(); _participantWinnerIds.Clear();
                            await RaffleData.SaveMembersAsync([]);
                            await RaffleData.SaveWinnerHistoryAsync(new WinnerHistory());
                            UpdateCount(); ShowView("home");
                        }
                        dialog.Hide();
                    }
                    catch (Exception ex) { message.Text = $"Не удалось удалить список: {ex.Message}"; }
                    return;
                }
                var index = catalog.Lists.FindIndex(p => p.Id == currentId);
                if (index < 0) return;
                catalog.Lists.RemoveAt(index);
                profilePicker.Items.RemoveAt(index);
                profilePicker.SelectedIndex = Math.Min(index, catalog.Lists.Count - 1);
            };
            list.SelectionChanged += (_, _) =>
            {
                update.IsEnabled = list.SelectedIndex >= 0;
                remove.IsEnabled = list.SelectedIndex >= 0;
                if (list.SelectedIndex is var index && index >= 0 && index < entries.Count)
                {
                    nameBox.Text = entries[index].Name;
                    ShowPhoto(entries[index].Avatar);
                }
            };
            nameBox.TextChanged += (_, _) =>
                dialog.IsPrimaryButtonEnabled = entries.Count > 0 || nameBox.Text.Trim().Length > 0;
            choosePhoto.Click += async (_, _) =>
            {
                try
                {
                    var picker = new FileOpenPicker();
                    WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance));
                    foreach (var extension in new[] { ".png", ".jpg", ".jpeg", ".webp" }) picker.FileTypeFilter.Add(extension);
                    var file = await picker.PickSingleFileAsync();
                    if (file is null) return;
                    if (new FileInfo(file.Path).Length > 5 * 1024 * 1024)
                    {
                        message.Text = "Выберите картинку меньше 5 МБ.";
                        return;
                    }
                    ShowPhoto(file.Path);
                }
                catch (Exception ex) { message.Text = $"Не удалось выбрать картинку: {ex.Message}"; }
            };
            clearPhoto.Click += (_, _) => ShowPhoto(null);
            add.Click += (_, _) =>
            {
                var name = nameBox.Text.Trim();
                if (name.Length == 0) { message.Text = "Введите имя или название."; return; }
                entries.Add(new Member { Id = "manual-" + Guid.NewGuid().ToString("N"), Name = name,
                    Username = "", Avatar = pendingPhoto ?? "" });
                Refresh(); nameBox.Text = ""; ShowPhoto(null);
            };
            update.Click += (_, _) =>
            {
                var index = list.SelectedIndex;
                if (index < 0 || index >= entries.Count) { message.Text = "Сначала выберите запись в списке."; return; }
                var name = nameBox.Text.Trim();
                if (name.Length == 0) { message.Text = "Введите имя или название."; return; }
                entries[index].Name = name;
                entries[index].Avatar = pendingPhoto ?? "";
                Refresh(index);
            };
            remove.Click += (_, _) =>
            {
                var index = list.SelectedIndex;
                if (index < 0 || index >= entries.Count) { message.Text = "Сначала выберите запись в списке."; return; }
                entries.RemoveAt(index);
                Refresh(); nameBox.Text = ""; ShowPhoto(null);
            };
            var photoRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
            photoRow.Children.Add(new Border { Width = 70, Height = 70, CornerRadius = new CornerRadius(35),
                Background = new SolidColorBrush(ParseColor("#3A6A96")), Child = RoundAvatarFrame(preview, 60) });
            var photoButtons = new StackPanel { Spacing = 6 };
            photoButtons.Children.Add(choosePhoto); photoButtons.Children.Add(clearPhoto);
            photoRow.Children.Add(photoButtons);
            var editor = new StackPanel { Spacing = 14 };
            editor.Children.Add(new TextBlock { Text = "Новая запись", FontSize = 19,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            editor.Children.Add(new TextBlock { Text = "Введите имя человека или название товара.",
                TextWrapping = TextWrapping.Wrap, Opacity = 0.72 });
            editor.Children.Add(nameBox); editor.Children.Add(photoStatus); editor.Children.Add(photoRow);
            var editActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            editActions.Children.Add(add); editActions.Children.Add(update);
            editor.Children.Add(editActions);
            var roster = new StackPanel { Spacing = 12 };
            roster.Children.Add(new TextBlock { Text = "Мои записи", FontSize = 19,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            roster.Children.Add(list);
            var rosterActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            rosterActions.Children.Add(remove);
            roster.Children.Add(rosterActions);
            var cardBrush = new SolidColorBrush(Color.FromArgb(45, 58, 106, 150));
            var editorCard = new Border { Padding = new Thickness(16), CornerRadius = new CornerRadius(16),
                Background = cardBrush, Child = editor };
            var rosterCard = new Border { Padding = new Thickness(16), CornerRadius = new CornerRadius(16),
                Background = cardBrush, Child = roster };
            var layout = new StackPanel { Spacing = 14, Width = dialogWidth - 72 };
            var profileBar = new StackPanel { Spacing = 10 };
            profileBar.Children.Add(new TextBlock { Text = "Мои списки", FontSize = 19,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            profileBar.Children.Add(profilePicker); profileBar.Children.Add(profileNameBox);
            var profileActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            profileActions.Children.Add(createProfile); profileActions.Children.Add(deleteProfile);
            profileBar.Children.Add(profileActions);
            profileBar.Children.Add(restartProfile);
            layout.Children.Add(new Border { Child = profileBar, Padding = new Thickness(16),
                CornerRadius = new CornerRadius(16), Background = cardBrush });
            if (dialogWidth >= 800)
            {
                var columns = new Grid { ColumnSpacing = 14 };
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(350) });
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Grid.SetColumn(editorCard, 0); Grid.SetColumn(rosterCard, 1);
                columns.Children.Add(editorCard); columns.Children.Add(rosterCard);
                layout.Children.Add(columns);
            }
            else
            {
                list.Height = 220;
                layout.Children.Add(editorCard); layout.Children.Add(rosterCard);
            }
            layout.Children.Add(message);
            dialog.Content = new ScrollViewer { Content = layout, MaxHeight = 620 };
            profilePicker.SelectedIndex = catalog.Lists.FindIndex(p => p.Id == currentId);
            Refresh();
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var pendingName = nameBox.Text.Trim();
            if (pendingName.Length > 0)
            {
                var selected = list.SelectedIndex;
                if (selected >= 0 && selected < entries.Count)
                {
                    entries[selected].Name = pendingName;
                    entries[selected].Avatar = pendingPhoto ?? "";
                }
                else entries.Add(new Member { Id = "manual-" + Guid.NewGuid().ToString("N"),
                    Name = pendingName, Avatar = pendingPhoto ?? "" });
            }
            StashCurrent();
            var selectedProfile = catalog.Lists.First(p => p.Id == currentId);
            if (_settings.ConfirmReplace && _members.Count > 0)
            {
                var confirmation = new ContentDialog
                {
                    XamlRoot = XamlRoot, Title = "Переключить список участников?",
                    Content = "Для текущего розыгрыша будет выбран список «" + selectedProfile.Name + "». История остальных своих списков сохранится.",
                    PrimaryButtonText = "Заменить", CloseButtonText = "Отмена"
                };
                if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
            }
            ManualListButton.IsEnabled = false;
            FileStatus.Text = "Сохраняю свой список…";
            var activated = await ManualRoster.ActivateAsync(catalog, currentId);
            _members = activated.Members;
            _participantMembers = activated.Members;
            _participantWinnerIds.Clear();
            _participantWinnerIds.UnionWith(activated.WinnerIds);
            _prizeMode = false;
            _settings.RaffleMode = "participants";
            await RaffleData.SaveSettingsAsync(_settings);
            _winnerIds.Clear();
            _winnerIds.UnionWith(activated.WinnerIds);
            _avatarCache.Clear();
            _avatarRequests.Clear();
            UpdateCount();
            FileStatus.Text = $"Свой список «{activated.Name}»: {activated.Members.Count:N0} записей. Данные сохранены в папке Settings.";
            _avatarFiles.StartBatch(activated.Members.Select(m => m.Avatar));
            var done = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Список готов",
                Content = $"Список «{activated.Name}» выбран для розыгрыша. Записей: {activated.Members.Count:N0}. Свои списки хранятся в папке данных Bon Raffle.",
                CloseButtonText = "Готово"
            };
            await done.ShowAsync();
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось сохранить свой список", ex); }
        finally { ManualListButton.IsEnabled = true; }
    }

    private static (string Path, string Name)? PickMemberFile()
    {
        // The WinRT picker can intermittently fail with 0x80004005 after a
        // ContentDialog (the MAX export result). Use the desktop shell dialog
        // owned by our WinUI window so it remains usable in the same session.
        using var picker = new System.Windows.Forms.OpenFileDialog
        {
            Title = "Загрузить список участников",
            Filter = "Списки участников CSV (*.csv)|*.csv",
            CheckFileExists = true,
            Multiselect = false,
            RestoreDirectory = true
        };
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance);
        var owner = new FileDialogOwner(handle);
        if (picker.ShowDialog(owner) != System.Windows.Forms.DialogResult.OK)
            return null;
        return (picker.FileName, Path.GetFileName(picker.FileName));
    }

    private sealed class FileDialogOwner(nint handle) : System.Windows.Forms.IWin32Window
    {
        public nint Handle => handle;
    }

    private static void WriteImportDiagnostic(string stage, Exception ex)
    {
        try
        {
            Directory.CreateDirectory(RaffleData.DirectoryPath);
            File.AppendAllText(Path.Combine(RaffleData.DirectoryPath, "import-errors.log"),
                $"[{DateTimeOffset.Now:O}] {stage}: {ex.GetType().FullName}; HRESULT 0x{ex.HResult:X8}; {ex}\n");
        }
        catch { /* Diagnostics must not replace the original error. */ }
    }

    private void Home_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning || _importOpening) return;
        ShowView("home");
    }

    private void Exit_Click(object sender, RoutedEventArgs e) => Application.Current.Exit();

    private void ApplyPrimaryButtonColors(Color color)
    {
        var border = Color.FromArgb(255,
            (byte)Math.Min(color.R + 28, 255),
            (byte)Math.Min(color.G + 28, 255),
            (byte)Math.Min(color.B + 28, 255));
        var pressed = Color.FromArgb(255,
            (byte)(color.R * 0.88),
            (byte)(color.G * 0.88),
            (byte)(color.B * 0.88));
        foreach (var button in new[] { OpenRaffleButton, SpinButton, AgainButton })
        {
            button.Background = new SolidColorBrush(color);
            button.BorderBrush = new SolidColorBrush(border);
            SetButtonStateColor(button, "ButtonBackgroundPointerOver", color);
            SetButtonStateColor(button, "ButtonBackgroundPressed", pressed);
            SetButtonStateColor(button, "ButtonBorderBrushPointerOver", border);
            SetButtonStateColor(button, "ButtonBorderBrushPressed", border);
            SetButtonStateColor(button, "ButtonForegroundPointerOver", Colors.White);
            SetButtonStateColor(button, "ButtonForegroundPressed", Colors.White);
        }
        ApplyModeColors(color);
    }

    private static void SetButtonStateColor(Button button, string key, Color color)
    {
        if (button.Resources.TryGetValue(key, out var resource) && resource is SolidColorBrush brush)
            brush.Color = color;
    }

    private void OpenRaffle_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning || _importOpening) return;
        var eligible = _members.Where(m => !_winnerIds.Contains(m.Id)).ToArray();
        if (eligible.Length == 0) return;
        _visualPool = eligible.Length <= 120 ? [.. eligible] : RandomNumberGenerator.GetItems(eligible, 120).ToList();
        _poolPosition = RandomNumberGenerator.GetInt32(_visualPool.Count);
        _offset = 0;
        _slotTransform.Y = 0;
        _spinning = false;
        _winner = null;
        SpinButton.IsEnabled = true;
        SpinButton.Content = _prizeMode ? "Разыграть приз" : "Выбрать победителя";
        PopulateSlots();
        ShowView("raffle");
    }

    private void ShowView(string view)
    {
        var wasVisible = view switch
        {
            "home" => HomeView.Visibility == Visibility.Visible,
            "raffle" => RaffleView.Visibility == Visibility.Visible,
            "winner" => WinnerView.Visibility == Visibility.Visible,
            _ => false
        };
        StopRendering();
        HomeView.Visibility = view == "home" ? Visibility.Visible : Visibility.Collapsed;
        if (view == "home") _ = NotifyUpdateAsync();
        RaffleView.Visibility = view == "raffle" ? Visibility.Visible : Visibility.Collapsed;
        WinnerView.Visibility = view == "winner" ? Visibility.Visible : Visibility.Collapsed;
        _raffleActive = view == "raffle";
        if (!_settings.ReduceEffects && !wasVisible)
            FadeIn(view == "home" ? HomeView : view == "raffle" ? RaffleView : WinnerView);
        if (_raffleActive) StartRendering();
        if (!wasVisible) FocusPrimaryAction();
    }

    private void FocusPrimaryAction()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_settingsOpening || _spinning) return;
            Button? target = HomeView.Visibility == Visibility.Visible ? OpenRaffleButton :
                RaffleView.Visibility == Visibility.Visible ? SpinButton :
                WinnerView.Visibility == Visibility.Visible ? AgainButton : null;
            if (target is { IsEnabled: true }) target.Focus(FocusState.Programmatic);
        });
    }

    private static void FadeIn(FrameworkElement element)
    {
        var animation = new DoubleAnimation
        {
            From = 0, To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(240)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop
        };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Begin();
    }

    private void PopulateSlots()
    {
        Slots.Children.Clear();
        _slotBorders.Clear();
        _slotNames.Clear();
        _slotImages.Clear();
        _giftIcons.Clear();
        _giftIcons[WinnerAvatar] = WinnerGiftIcon;
        for (var i = 0; i < 6; i++)
        {
            var image = new Image { Width = 40, Height = 40, Stretch = Stretch.UniformToFill, VerticalAlignment = VerticalAlignment.Center };
            var gift = new TextBlock { Text = "🎁", FontSize = 29, Width = 40, Height = 40,
                TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Visibility = Visibility.Collapsed };
            var name = new TextBlock
            {
                FontSize = 17, Foreground = new SolidColorBrush(Colors.White),
                VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1
            };
            var panel = new Grid { Height = 64, ColumnSpacing = 14 };
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(42) });
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            panel.Children.Add(RoundAvatarFrame(image, 40));
            panel.Children.Add(gift);
            Grid.SetColumn(name, 1);
            panel.Children.Add(name);
            var border = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(15, 0, 15, 0), Child = panel };
            Slots.Children.Add(border);
            _slotBorders.Add(border);
            _slotNames.Add(name);
            _slotImages.Add(image);
            _giftIcons[image] = gift;
        }
        for (var i = 0; i < 6; i++) SetSlot(i, NextVisualMember());
        HighlightCenter();
    }

    private Member NextVisualMember()
    {
        var member = _visualPool[_poolPosition % _visualPool.Count];
        _poolPosition++;
        return member;
    }

    private void SetSlot(int index, Member member)
    {
        _slotNames[index].Text = member.Name;
        SetAvatar(_slotImages[index], member.Avatar);
    }

    private void HighlightCenter()
    {
        var drum = ParseColor(_settings.DrumColor);
        for (var i = 0; i < _slotBorders.Count; i++)
        {
            _slotBorders[i].Background = new SolidColorBrush(Color.FromArgb(145, drum.R, drum.G, drum.B));
            _slotBorders[i].BorderBrush = new SolidColorBrush(Colors.Transparent);
            _slotBorders[i].BorderThickness = new Thickness(0);
        }
    }

    private static Color ParseColor(string hex)
    {
        var value = uint.Parse(hex.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        return Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);
    }

    private static string Hex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    private string PlaceholderSource => File.Exists(RaffleData.AvatarPlaceholderPath)
        ? new Uri(RaffleData.AvatarPlaceholderPath).AbsoluteUri
        : "ms-appx:///Assets/AvatarPlaceholder.png";

    private static Grid RoundAvatarFrame(Image image, double size)
    {
        var frame = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
        var brush = new ImageBrush { Stretch = Stretch.UniformToFill, ImageSource = image.Source,
            RelativeTransform = new ScaleTransform { CenterX = 0.5, CenterY = 0.5, ScaleX = 1.08, ScaleY = 1.08 } };
        var photo = new Microsoft.UI.Xaml.Shapes.Ellipse { Fill = brush };
        frame.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Fill = new SolidColorBrush(ParseColor("#244060")) });
        frame.Children.Add(photo);
        image.Opacity = 0;
        frame.Children.Add(image);
        image.RegisterPropertyChangedCallback(Image.SourceProperty, (_, _) => brush.ImageSource = image.Source);
        image.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => photo.Visibility = image.Visibility);
        return frame;
    }

    private void SetAvatar(Image image, string? url)
    {
        var placeholder = PlaceholderSource;
        var localPhoto = _settings.ShowAvatars ? ManualRoster.LocalPhoto(url) ?? PrizeStore.LocalImage(url) : null;
        var source = localPhoto is not null ? url! :
            _settings.ShowAvatars && Uri.TryCreate(url, UriKind.Absolute, out var uri)
            && uri.Scheme is "https" or "http" ? url! : placeholder;
        ShowPrizeGift(image, source == placeholder);
        if (_avatarRequests.TryGetValue(image, out var current) && current == source) return;
        _avatarRequests[image] = source;
        image.ImageFailed -= Avatar_ImageFailed;
        image.ImageFailed += Avatar_ImageFailed;
        if (source == placeholder)
        {
            image.Source = AvatarBitmap(placeholder);
            return;
        }
        if (localPhoto is not null)
        {
            image.Source = AvatarBitmap(localPhoto);
            return;
        }
        image.Source = AvatarBitmap(placeholder);
        _ = SetAvatarAsync(image, source);
    }

    private void ShowPrizeGift(Image image, bool fallback)
    {
        if (!_giftIcons.TryGetValue(image, out var gift)) return;
        var show = _prizeMode && fallback;
        gift.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        image.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        if (image == WinnerAvatar) WinnerAvatarSurface.Visibility = image.Visibility;
    }

    private async Task SetAvatarAsync(Image image, string source)
    {
        try
        {
            var file = await _avatarFiles.GetAsync(source);
            if (file is not null && _avatarRequests.TryGetValue(image, out var current) && current == source)
                image.Source = AvatarBitmap(file);
            else if (file is null && _avatarRequests.TryGetValue(image, out var missing) && missing == source)
                ShowPrizeGift(image, true);
        }
        catch (Exception) { if (_avatarRequests.TryGetValue(image, out var current) && current == source) ShowPrizeGift(image, true); }
    }

    private BitmapImage AvatarBitmap(string source)
    {
        if (_avatarCache.TryGetValue(source, out var bitmap)) return bitmap;
        bitmap = new BitmapImage(new Uri(source));
        if (_avatarCache.Count >= 256) _avatarCache.Clear();
        _avatarCache[source] = bitmap;
        return bitmap;
    }

    private void AvatarActivityChanged(int count)
    {
        if (Interlocked.Exchange(ref _avatarUpdateQueued, 1) != 0) return;
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _avatarUpdateQueued, 0);
            var pending = _avatarFiles.PendingCount;
            var remaining = _avatarFiles.BatchRemaining;
            var total = _avatarFiles.BatchTotal;
            var completed = _avatarFiles.BatchCompleted;
            if (total == 0 && pending == 0 && _avatarFiles.ActiveCount == 0)
            {
                AvatarStatusButton.Visibility = Visibility.Collapsed;
                _avatarProgressTimer.Stop();
                return;
            }
            var generation = _avatarFiles.BatchGeneration;
            if (generation != _avatarObservedBatchGeneration)
            {
                _avatarObservedBatchGeneration = generation;
                _avatarDisplayedProgress = 0;
                DrawAvatarArc(0);
            }
            _avatarTargetProgress = total > 0 ? (double)completed / total : 0;
            AvatarProgressText.Text = FormatAvatarProgress(completed, total);
            AvatarStatusButton.Visibility = Visibility.Visible;
            if (!_avatarProgressTimer.IsEnabled) _avatarProgressTimer.Start();
            ToolTipService.SetToolTip(AvatarStatusButton, total > 0
                ? $"Аватары: {completed:N0} из {total:N0}, осталось {remaining:N0}"
                : "Кеш аватаров — нажмите для подробностей");
        }))
            Interlocked.Exchange(ref _avatarUpdateQueued, 0);
    }

    private void TickAvatarProgress()
    {
        var total = _avatarFiles.BatchTotal;
        var completed = _avatarFiles.BatchCompleted;
        _avatarTargetProgress = total > 0 ? (double)completed / total : 0;
        var gap = _avatarTargetProgress - _avatarDisplayedProgress;
        _avatarDisplayedProgress = Math.Abs(gap) < 0.002
            ? _avatarTargetProgress
            : _avatarDisplayedProgress + Math.Sign(gap) * Math.Max(0.002, Math.Abs(gap) * 0.22);
        _avatarDisplayedProgress = Math.Clamp(_avatarDisplayedProgress, 0, 1);
        DrawAvatarArc(_avatarDisplayedProgress);
        AvatarProgressText.Text = FormatAvatarProgress(completed, total);
        if (_avatarTargetProgress >= 1 && _avatarDisplayedProgress >= 1 && _avatarFiles.BatchRemaining == 0)
        {
            AvatarStatusButton.Visibility = Visibility.Collapsed;
            _avatarProgressTimer.Stop();
        }
        else if (total == 0 && _avatarFiles.PendingCount == 0 && _avatarFiles.ActiveCount == 0)
        {
            AvatarStatusButton.Visibility = Visibility.Collapsed;
            _avatarProgressTimer.Stop();
        }
    }

    private static string FormatAvatarProgress(int completed, int total)
    {
        if (total == 0) return "…";
        var percent = Math.Clamp((double)completed / total * 100, 0, 100);
        return total >= 1000 && completed < total ? $"{percent:0.0}%" : $"{percent:0}%";
    }

    private void DrawAvatarArc(double progress)
    {
        if (progress <= 0) { AvatarProgressArc.Data = null; return; }
        var figure = new PathFigure { StartPoint = new Windows.Foundation.Point(18, 3), IsClosed = false };
        if (progress >= 0.999)
        {
            figure.Segments.Add(new ArcSegment { Point = new Windows.Foundation.Point(18, 33),
                Size = new Windows.Foundation.Size(15, 15), SweepDirection = SweepDirection.Clockwise });
            figure.Segments.Add(new ArcSegment { Point = new Windows.Foundation.Point(18, 3),
                Size = new Windows.Foundation.Size(15, 15), SweepDirection = SweepDirection.Clockwise });
        }
        else
        {
            var angle = progress * Math.PI * 2;
            figure.Segments.Add(new ArcSegment
            {
                Point = new Windows.Foundation.Point(18 + 15 * Math.Sin(angle), 18 - 15 * Math.Cos(angle)),
                Size = new Windows.Foundation.Size(15, 15), SweepDirection = SweepDirection.Clockwise,
                IsLargeArc = progress > 0.5
            });
        }
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        AvatarProgressArc.Data = geometry;
    }

    private async void AvatarStatus_Click(object sender, RoutedEventArgs e)
    {
        if (_avatarDialogOpening) return;
        _avatarDialogOpening = true;
        try
        {
        var cacheBytes = await Task.Run(() => _avatarFiles.SizeBytes);
        var details = new TextBlock
        {
            Text = $"Кеш: {FormatBytes(cacheBytes)}\nОбработано: {_avatarFiles.BatchCompleted:N0} из {_avatarFiles.BatchTotal:N0}\nОсталось: {_avatarFiles.BatchRemaining:N0}\nНе удалось загрузить: {_avatarFiles.BatchFailed:N0}\nОдновременно загружаются: {_avatarFiles.ActiveCount}. Розыгрыш можно открыть во время загрузки.",
            TextWrapping = TextWrapping.Wrap
        };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Загрузка аватаров", Content = details,
            PrimaryButtonText = "Очистить кеш", SecondaryButtonText = "Загрузить заново", CloseButtonText = "Закрыть"
        };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Secondary)
        {
            _avatarFiles.StartBatch(_members.Select(m => m.Avatar));
            return;
        }
        if (result != ContentDialogResult.Primary) return;
        try { await ClearAvatarCacheAsync(); }
        catch (Exception ex) { await ShowErrorAsync("Не удалось очистить кеш", ex); }
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось открыть загрузку аватаров", ex); }
        finally { _avatarDialogOpening = false; }
    }

    private async Task ClearAvatarCacheAsync()
    {
        _avatarCache.Clear();
        _avatarRequests.Clear();
        foreach (var image in _slotImages) image.Source = AvatarBitmap(PlaceholderSource);
        WinnerAvatar.Source = AvatarBitmap(PlaceholderSource);
        await Task.Run(_avatarFiles.Clear);
        AvatarActivityChanged(_avatarFiles.ActiveCount);
    }

    private void Avatar_ImageFailed(object sender, ExceptionRoutedEventArgs e)
    {
        if (sender is Image image)
        {
            image.ImageFailed -= Avatar_ImageFailed;
            image.Source = new BitmapImage(new Uri("ms-appx:///Assets/AvatarPlaceholder.png"));
            ShowPrizeGift(image, true);
        }
    }

    private void RefreshVisibleAvatars()
    {
        _avatarCache.Clear();
        _avatarRequests.Clear();
        if (_raffleActive && _visualPool.Count > 0)
            for (var i = 0; i < _slotImages.Count; i++)
                SetAvatar(_slotImages[i], _visualPool[(_poolPosition - 6 + i + _visualPool.Count * 6) % _visualPool.Count].Avatar);
        if (_winner is not null) SetAvatar(WinnerAvatar, _winner.Avatar);
        else WinnerAvatar.Source = AvatarBitmap(PlaceholderSource);
    }

    private void StartRendering()
    {
        if (!_raffleActive || (!_spinning && (_settings.IdleSpeedPercent == 0 || _settings.ReduceEffects))) return;
        _lastFrame = Stopwatch.GetTimestamp();
        CompositionTarget.Rendering -= OnRendering;
        CompositionTarget.Rendering += OnRendering;
    }

    private void StopRendering() => CompositionTarget.Rendering -= OnRendering;

    private void OnRendering(object? sender, object e)
    {
        if (!_raffleActive || _visualPool.Count == 0) return;
        var now = Stopwatch.GetTimestamp();
        var elapsed = (now - _lastFrame) / (double)Stopwatch.Frequency;
        if (_settings.AnimationFps > 0 && elapsed < 0.98 / _settings.AnimationFps) return;
        var delta = Math.Min(elapsed, 0.05);
        _lastFrame = now;
        if (_spinning)
        {
            var spinElapsed = (now - _spinStartedAt) / (double)Stopwatch.Frequency;
            var progress = Math.Min(spinElapsed / _settings.SpinSeconds, 1);
            var distance = _spinStartOffset
                + (_spinTargetSteps * SlotPitch - _spinStartOffset) * SpinTravelFraction(progress);
            var steps = progress >= 1 ? _spinTargetSteps
                : Math.Min(_spinTargetSteps, (int)(distance / SlotPitch));
            while (_spinStepsDone < steps)
            {
                _spinStepsDone++;
                RotateSlots(_spinStepsDone == _spinTargetSteps - 3 ? _winner : null);
            }
            _offset = progress >= 1 ? 0 : distance - steps * SlotPitch;
            _slotTransform.Y = -_offset;
            if (progress >= 1 && !_finishQueued)
            {
                _finishQueued = true;
                if (!DispatcherQueue.TryEnqueue(() =>
                {
                    _finishQueued = false;
                    if (_spinning) FinishSpin();
                })) _finishQueued = false;
            }
            return;
        }
        _offset += 34 * _settings.IdleSpeedPercent / 100.0 * delta;
        while (_offset >= SlotPitch)
        {
            _offset -= SlotPitch;
            RotateSlots(null);
        }
        _slotTransform.Y = -_offset;
    }

    private void RotateSlots(Member? incoming)
    {
        var border = _slotBorders[0]; var name = _slotNames[0]; var image = _slotImages[0];
        _slotBorders.RemoveAt(0); _slotNames.RemoveAt(0); _slotImages.RemoveAt(0);
        Slots.Children.Remove(border);
        Slots.Children.Add(border);
        _slotBorders.Add(border); _slotNames.Add(name); _slotImages.Add(image);
        SetSlot(5, incoming ?? NextVisualMember());
        HighlightCenter();
    }

    private static double SpinTravelFraction(double progress)
    {
        var t = Math.Clamp(progress, 0, 1);
        double area;
        if (t < 0.18) area = 110 * t + 1040 * t * t / (2 * 0.18);
        else if (t < 0.62) area = 113.4 + 1150 * (t - 0.18);
        else area = 619.4 + 1150 * 0.38 / 2.8 * (1 - Math.Pow((1 - t) / 0.38, 2.8));
        return area / SpinTravelArea;
    }

    private void Spin_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning) return;
        var eligible = _members.Where(m => !_winnerIds.Contains(m.Id)).ToArray();
        if (eligible.Length == 0) return;
        if (_prizeMode)
        {
            var selectedPrize = PrizeStore.Draw(_prizes);
            _winner = eligible.FirstOrDefault(m => m.Id == selectedPrize.Id);
            if (_winner is null) return;
        }
        else _winner = eligible[RandomNumberGenerator.GetInt32(eligible.Length)];
        _spinning = true;
        _spinStartOffset = _offset;
        _spinTargetSteps = Math.Max(12, (int)Math.Ceiling(
            SpinTravelArea * _settings.SpinSeconds * _settings.SpinSpeedPercent / 100.0 / SlotPitch));
        _spinStepsDone = 0;
        _finishQueued = false;
        _spinStartedAt = Stopwatch.GetTimestamp();
        SpinButton.IsEnabled = false;
        SpinButton.Content = "Идёт розыгрыш…";
        StartRendering();
    }

    private async void FinishSpin()
    {
        if (_winner is null) return;
        _spinning = false;
        StopRendering();
        try
        {
            if (_prizeMode)
            {
                var catalog = await PrizeStore.LoadCatalogAsync();
                var profile = catalog.Lists.FirstOrDefault(p => p.Id == catalog.ActiveId)
                    ?? throw new InvalidDataException("Активный список призов не найден.");
                var prize = profile.Prizes.FirstOrDefault(p => p.Id == _winner.Id && p.Quantity > 0)
                    ?? throw new InvalidDataException("Этот приз уже закончился.");
                prize.Quantity--;
                await PrizeStore.SaveCatalogAsync(catalog);
                _prizes = profile.Prizes;
                _members = PrizeMembers(_prizes);
            }
            else
            {
                var updated = new HashSet<string>(_winnerIds, StringComparer.Ordinal) { _winner.Id };
                await RaffleData.SaveWinnerHistoryAsync(new WinnerHistory
                {
                    ListFingerprint = RaffleData.Fingerprint(_members), Ids = updated.OrderBy(id => id).ToList()
                });
                await ManualRoster.RecordWinnerAsync(_members, _winner.Id);
                _winnerIds.Clear();
                _winnerIds.UnionWith(updated);
            }
        }
        catch (Exception ex)
        {
            await ShowErrorAsync("Не удалось сохранить победителя", ex);
            SpinButton.IsEnabled = true;
            SpinButton.Content = _prizeMode ? "Разыграть приз" : "Выбрать победителя";
            return;
        }
        UpdateCount();
        WinnerName.Text = _winner.Name;
        WinnerUsername.Text = string.IsNullOrWhiteSpace(_winner.Username) ? "" : "@" + _winner.Username.TrimStart('@');
        WinnerUsername.Visibility = string.IsNullOrEmpty(WinnerUsername.Text) ? Visibility.Collapsed : Visibility.Visible;
        WinnerId.Text = "ID: " + _winner.Id;
        var showId = !_winner.Id.StartsWith("manual-", StringComparison.Ordinal)
            && !_winner.Id.StartsWith("prize-", StringComparison.Ordinal);
        WinnerIdBadge.Visibility = showId ? Visibility.Visible : Visibility.Collapsed;
        CopyWinnerIdButton.Visibility = showId ? Visibility.Visible : Visibility.Collapsed;
        WinnerPosition.Text = showId ? $"Позиция в списке: {_members.FindIndex(m => m.Id == _winner.Id) + 1:N0}" : "";
        WinnerPosition.Visibility = showId ? Visibility.Visible : Visibility.Collapsed;
        SetAvatar(WinnerAvatar, _winner.Avatar);
        ShowView("winner");
        AnimateWinner();
    }

    private void AnimateWinner()
    {
        _winnerEntranceAnimation?.Stop();
        StopLayerAnimation(BalloonLayer);
        StopLayerAnimation(StarShowerLayer);
        BalloonLayer.Children.Clear();
        StarShowerLayer.Children.Clear();
        if (_settings.ReduceEffects) return;
        WinnerCard.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
        var entrance = new CompositeTransform();
        WinnerCard.RenderTransform = entrance;
        var storyboard = new Storyboard();
        foreach (var property in new[] { "ScaleX", "ScaleY" })
        {
            var animation = new DoubleAnimation
            {
                From = 0.92, To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(520)),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                FillBehavior = FillBehavior.Stop
            };
            Storyboard.SetTarget(animation, entrance);
            Storyboard.SetTargetProperty(animation, property);
            storyboard.Children.Add(animation);
        }
        var lift = new DoubleAnimation
        {
            From = 20, To = 0, Duration = new Duration(TimeSpan.FromMilliseconds(520)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop
        };
        Storyboard.SetTarget(lift, entrance);
        Storyboard.SetTargetProperty(lift, "TranslateY");
        storyboard.Children.Add(lift);
        AddParticleAnimation(storyboard, WinnerCard, "Opacity", 0, 1, 0.44, 0);
        _winnerEntranceAnimation = storyboard;
        storyboard.Begin();
        var effect = _settings.WinnerEffect == "random"
            ? new[] { "balloons", "stars", "sparks" }[Random.Shared.Next(3)]
            : _settings.WinnerEffect;
        if (effect == "balloons") AnimateBalloons();
        else if (effect == "stars") AnimateConfettiSalute(BalloonLayer);
        else AnimateStarShower(StarShowerLayer);
    }

    private void AnimateBalloons(Canvas? target = null)
    {
        var layer = target ?? BalloonLayer;
        StopLayerAnimation(layer);
        var preview = target is not null;
        var scale = preview ? 0.55 : 1.0;
        layer.Children.Clear();
        WinnerView.UpdateLayout();
        var width = Math.Max(preview ? 260 : 600, layer.ActualWidth);
        var height = Math.Max(preview ? 110 : 400, layer.ActualHeight);
        var colors = new[] { "#E88A43", "#F5C978", "#91BED7", "#F1DDB5", "#E9A9A4", "#E9A044" };
        var storyboard = new Storyboard();
        for (var i = 0; i < 6; i++)
        {
            var color = ParseColor(colors[i]);
            var piece = new Canvas { Width = 34, Height = 78, Opacity = 0,
                RenderTransformOrigin = new Windows.Foundation.Point(0, 0) };
            var body = new Microsoft.UI.Xaml.Shapes.Ellipse
                { Width = 28, Height = 36, Fill = new SolidColorBrush(color) };
            Canvas.SetLeft(body, 3);
            piece.Children.Add(body);
            var shine = new Microsoft.UI.Xaml.Shapes.Ellipse
                { Width = 6, Height = 11, Fill = new SolidColorBrush(Color.FromArgb(125, 255, 255, 255)) };
            Canvas.SetLeft(shine, 9); Canvas.SetTop(shine, 7);
            piece.Children.Add(shine);
            var knot = new Microsoft.UI.Xaml.Shapes.Polygon
                { Fill = new SolidColorBrush(color) };
            knot.Points.Add(new Windows.Foundation.Point(13, 35));
            knot.Points.Add(new Windows.Foundation.Point(21, 35));
            knot.Points.Add(new Windows.Foundation.Point(17, 42));
            piece.Children.Add(knot);
            piece.Children.Add(new Microsoft.UI.Xaml.Shapes.Line
            {
                X1 = 17, Y1 = 42, X2 = 12, Y2 = 59,
                Stroke = new SolidColorBrush(Color.FromArgb(180, 242, 225, 197)), StrokeThickness = 1
            });
            piece.Children.Add(new Microsoft.UI.Xaml.Shapes.Line
            {
                X1 = 12, Y1 = 59, X2 = 17, Y2 = 77,
                Stroke = new SolidColorBrush(Color.FromArgb(180, 242, 225, 197)), StrokeThickness = 1
            });
            var movement = new TranslateTransform();
            piece.RenderTransform = movement;
            var side = i % 2 == 0 ? -1 : 1;
            Canvas.SetLeft(piece, width / 2 + side * Math.Min(width * 0.30, 300)
                + (Random.Shared.NextDouble() - 0.5) * 44);
            Canvas.SetTop(piece, height * 0.78 + Random.Shared.NextDouble() * 28);
            layer.Children.Add(piece);
            var delay = i * 0.12;
            var duration = 2.35 + Random.Shared.NextDouble() * 0.35;
            AddParticleAnimation(storyboard, movement, "X", 0,
                side * (30 + Random.Shared.NextDouble() * 65) * scale, duration, delay);
            AddParticleAnimation(storyboard, movement, "Y", 0,
                (-240 - Random.Shared.NextDouble() * 80) * scale, duration, delay);
            AddOpacityEnvelope(storyboard, piece, duration, delay);
        }
        StartLayerAnimation(layer, storyboard);
    }

    private void StopLayerAnimation(Canvas layer)
    {
        if (!_layerAnimations.Remove(layer, out var previous)) return;
        previous.Stop();
    }

    private void StartLayerAnimation(Canvas layer, Storyboard storyboard)
    {
        _layerAnimations[layer] = storyboard;
        storyboard.Completed += (_, _) =>
        {
            if (!_layerAnimations.TryGetValue(layer, out var current) || !ReferenceEquals(current, storyboard)) return;
            _layerAnimations.Remove(layer);
            layer.Children.Clear();
        };
        storyboard.Begin();
    }

    private async void MaxExport_Click(object sender, RoutedEventArgs e)
    {
        if (_maxExporting || _importOpening || _spinning) return;
        _maxExporting = true;
        MaxExportButton.IsEnabled = false;
        ImportButton.IsEnabled = false;
        try
        {
            if (!long.TryParse(_settings.MaxChatId, out var chatId) || string.IsNullOrWhiteSpace(MaxConnection.LoadToken()))
            {
                var info = new ContentDialog
                {
                    XamlRoot = XamlRoot, Title = "Подключение MAX",
                    Content = "Сначала укажите токен бота и chat_id канала в разделе «Настройки» → «Данные».",
                    CloseButtonText = "Понятно"
                };
                await info.ShowAsync();
                return;
            }
            FileStatus.Text = "Получаю участников из MAX…";
            ImportProgress.Visibility = Visibility.Visible;
            ImportProgress.IsActive = true;
            var progress = new Progress<int>(count => FileStatus.Text = $"Получено из MAX: {count:N0} участников…");
            var result = await MaxRosterExporter.ExportAsync(MaxConnection.LoadToken()!, chatId,
                _settings.MaxApiHost, progress);
            FileStatus.Text = $"CSV сохранён в «Загрузки»: {result.Count:N0} участников. Теперь нажмите «Загрузить участников».";
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Выгрузка MAX готова",
                Content = $"Сохранено {result.Count:N0} участников в файл:\n{result.Path}\n\nЗагрузите этот CSV кнопкой «Загрузить участников».",
                PrimaryButtonText = "Открыть Загрузки", CloseButtonText = "Готово"
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                Process.Start(new ProcessStartInfo { FileName = Path.GetDirectoryName(result.Path)!, UseShellExecute = true });
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось выгрузить участников MAX", ex); }
        finally
        {
            await Task.Delay(500);
            _maxExporting = false;
            MaxExportButton.IsEnabled = true;
            ImportButton.IsEnabled = true;
            ImportProgress.IsActive = false;
            ImportProgress.Visibility = Visibility.Collapsed;
        }
    }

    private void AnimatePreviewBalloons(Canvas layer) => AnimateBalloons(layer);

    private static Microsoft.UI.Xaml.Shapes.Polygon MakeStar(double radius, Color color)
    {
        var star = new Microsoft.UI.Xaml.Shapes.Polygon
        {
            Width = radius * 2, Height = radius * 2,
            Fill = new SolidColorBrush(color), Opacity = 0
        };
        for (var point = 0; point < 10; point++)
        {
            var angle = point * Math.PI / 5 - Math.PI / 2;
            var length = point % 2 == 0 ? radius : radius * 0.43;
            star.Points.Add(new Windows.Foundation.Point(radius + Math.Cos(angle) * length,
                radius + Math.Sin(angle) * length));
        }
        return star;
    }

    private static Microsoft.UI.Xaml.Shapes.Rectangle MakeConfetti(int index, double scale, Color color)
    {
        return new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Width = (4 + index % 3) * scale,
            Height = (14 + index % 5 * 2) * scale,
            RadiusX = 0.7 * scale, RadiusY = 0.7 * scale,
            Fill = new SolidColorBrush(color), Opacity = 0,
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5)
        };
    }

    private Windows.Foundation.Rect CardBounds(Canvas layer, bool preview)
    {
        if (preview)
            return new Windows.Foundation.Rect(layer.ActualWidth * 0.26,
                layer.ActualHeight * 0.18, layer.ActualWidth * 0.48, layer.ActualHeight * 0.70);
        WinnerView.UpdateLayout();
        return WinnerCard.TransformToVisual(layer).TransformBounds(
            new Windows.Foundation.Rect(0, 0, WinnerCard.ActualWidth, WinnerCard.ActualHeight));
    }

    private void AnimateConfettiSalute(Canvas layer)
    {
        StopLayerAnimation(layer);
        layer.Children.Clear();
        layer.UpdateLayout();
        var width = Math.Max(260, layer.ActualWidth);
        var preview = width < 400;
        var scale = preview ? 0.52 : 1.0;
        var bounds = CardBounds(layer, preview);
        var colors = new[] { "#86D84E", "#F9E458", "#B66DDC", "#FFFFFF",
            "#EA86CB", "#65D7E8", "#49A03F", "#F6B86C" };
        var storyboard = new Storyboard();
        for (var i = 0; i < (preview ? 48 : 108); i++)
        {
            var side = i % 2 == 0 ? -1 : 1;
            var particle = MakeConfetti(i, scale, ParseColor(colors[i % colors.Length]));
            var motion = new CompositeTransform { Rotation = (i * 53) % 360 };
            particle.RenderTransform = motion;
            Canvas.SetLeft(particle, side < 0 ? bounds.Left - 38 * scale : bounds.Right + 38 * scale);
            Canvas.SetTop(particle, bounds.Top + bounds.Height * 0.48 + ((i % 5) - 2) * 5 * scale);
            layer.Children.Add(particle);
            var delay = (i % 12) * 0.025;
            var duration = 2.0 + (i % 7) * 0.12;
            var angle = (i * 137 % 360) * Math.PI / 180;
            var distance = (115 + (i % 8) * 24) * scale;
            AddParticleAnimation(storyboard, motion, "TranslateX", 0,
                Math.Cos(angle) * distance, duration, delay);
            AddParticleAnimation(storyboard, motion, "TranslateY", 0,
                Math.Sin(angle) * distance + 16 * scale, duration, delay);
            AddParticleAnimation(storyboard, motion, "Rotation", motion.Rotation,
                motion.Rotation + (i % 2 == 0 ? 540 : -540), duration, delay);
            AddOpacityEnvelope(storyboard, particle, duration, delay);
        }
        StartLayerAnimation(layer, storyboard);
    }

    private void AnimateStarShower(Canvas layer)
    {
        StopLayerAnimation(layer);
        layer.Children.Clear();
        layer.UpdateLayout();
        var preview = layer.ActualWidth < 400;
        var scale = preview ? 0.62 : 1.0;
        var bounds = CardBounds(layer, preview);
        var colors = new[] { "#FFD85A", "#FF8A52", "#F06BB7", "#79D8FF", "#83E5B5", "#BA9CFF", "#FFFFFF" };
        var storyboard = new Storyboard();
        for (var i = 0; i < (preview ? 36 : 72); i++)
        {
            var radius = (2.6 + i % 4) * scale;
            var star = MakeStar(radius, ParseColor(colors[i % colors.Length]));
            var motion = new TranslateTransform();
            star.RenderTransform = motion;
            var position = ((i * 47) % 101) / 100.0;
            Canvas.SetLeft(star, bounds.Left + 20 * scale + position * Math.Max(0, bounds.Width - 40 * scale));
            Canvas.SetTop(star, bounds.Top - 32 * scale - (i % 5) * 12 * scale);
            layer.Children.Add(star);
            var delay = (i % 12) * 0.075 + (i / 12) * 0.045;
            var duration = 1.9 + (i % 7) * 0.13;
            AddParticleAnimation(storyboard, motion, "X", 0,
                Math.Sin(i * 2.37) * 19 * scale, duration, delay);
            AddParticleAnimation(storyboard, motion, "Y", 0,
                bounds.Height + 52 * scale + (i % 5) * 8 * scale, duration, delay);
            AddOpacityEnvelope(storyboard, star, duration, delay);
        }
        StartLayerAnimation(layer, storyboard);
    }

    private static void AddOpacityEnvelope(Storyboard storyboard, UIElement target,
        double duration, double delay)
    {
        var opacity = new DoubleAnimationUsingKeyFrames
            { BeginTime = TimeSpan.FromSeconds(delay), FillBehavior = FillBehavior.Stop };
        opacity.KeyFrames.Add(new LinearDoubleKeyFrame
            { KeyTime = KeyTime.FromTimeSpan(TimeSpan.Zero), Value = 0 });
        opacity.KeyFrames.Add(new LinearDoubleKeyFrame
            { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.12)), Value = 1 });
        opacity.KeyFrames.Add(new LinearDoubleKeyFrame
            { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(duration * 0.70)), Value = 1 });
        opacity.KeyFrames.Add(new LinearDoubleKeyFrame
            { KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(duration)), Value = 0 });
        Storyboard.SetTarget(opacity, target);
        Storyboard.SetTargetProperty(opacity, "Opacity");
        storyboard.Children.Add(opacity);
    }

    private static void AddParticleAnimation(Storyboard storyboard, DependencyObject target,
        string property, double from, double to, double seconds, double delay)
    {
        var animation = new DoubleAnimation
        {
            From = from, To = to, Duration = new Duration(TimeSpan.FromSeconds(seconds)),
            BeginTime = TimeSpan.FromSeconds(delay), FillBehavior = FillBehavior.Stop
        };
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, property);
        storyboard.Children.Add(animation);
    }

    private void CopyWinnerId_Click(object sender, RoutedEventArgs e)
    {
        if (_winner is null || _winner.Id.StartsWith("manual-", StringComparison.Ordinal)) return;
        var data = new DataPackage();
        data.SetText(_winner.Id);
        Clipboard.SetContent(data);
    }

    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning || _settingsOpening) return;
        _settingsOpening = true;
        try
        {
        var cacheBytes = await Task.Run(() => _avatarFiles.SizeBytes);
        StopRendering();
        var fullscreen = new ToggleSwitch { Header = "Во весь экран при запуске", IsOn = _settings.Fullscreen };
        var avatars = new ToggleSwitch { Header = "Показывать аватары", IsOn = _settings.ShowAvatars };
        var photo = new ToggleSwitch { Header = "Показывать фоновое фото", IsOn = _settings.UseBackgroundPhoto };
        var confirmReplace = new ToggleSwitch { Header = "Подтверждать замену списка", IsOn = _settings.ConfirmReplace };
        var effects = new ToggleSwitch { Header = "Уменьшить эффекты", IsOn = _settings.ReduceEffects };
        var duration = new ComboBox { Header = "Длительность розыгрыша", Width = 280, HorizontalAlignment = HorizontalAlignment.Left };
        duration.Items.Add("8 секунд"); duration.Items.Add("12 секунд"); duration.Items.Add("20 секунд");
        duration.SelectedIndex = _settings.SpinSeconds == 8 ? 0 : _settings.SpinSeconds == 12 ? 1 : 2;
        var fps = new ComboBox { Header = "Частота анимации", Width = 320, HorizontalAlignment = HorizontalAlignment.Left };
        fps.Items.Add("Авто — частота экрана"); fps.Items.Add("30 кадров/с"); fps.Items.Add("60 кадров/с");
        fps.Items.Add("120 кадров/с"); fps.Items.Add("144 кадра/с");
        fps.SelectedIndex = _settings.AnimationFps switch { 30 => 1, 60 => 2, 120 => 3, 144 => 4, _ => 0 };
        var idle = new Slider { Header = "Скорость вращения до розыгрыша", Minimum = 0, Maximum = 200, StepFrequency = 10, Value = _settings.IdleSpeedPercent };
        var spin = new Slider { Header = "Скорость розыгрыша", Minimum = 50, Maximum = 200, StepFrequency = 10, Value = _settings.SpinSpeedPercent };
        var dim = new Slider { Header = "Затемнение фона", Minimum = 30, Maximum = 85, StepFrequency = 5, Value = _settings.BackgroundDim };
        var homeCardColor = new ColorPicker { Color = ParseColor(_settings.HomeCardColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        var homeCardTransparency = new Slider { Header = "Прозрачность карточки на главной", Minimum = 0, Maximum = 100, StepFrequency = 5, Value = (1 - _settings.HomeCardOpacity) * 100 };
        var resetHomeCardButton = new Button { Content = "Вернуть стандартный вид карточки" };
        resetHomeCardButton.Click += (_, _) => { homeCardColor.Color = ParseColor("#000000"); homeCardTransparency.Value = 40; };
        var showRemaining = new ToggleSwitch { Header = "Показывать число участников над барабаном", IsOn = _settings.ShowRemainingHeader };
        var participantsCaption = new TextBox { Header = "Подпись над барабаном · участники", Text = _settings.ParticipantsCaption,
            MaxLength = 200, Width = 620, HorizontalAlignment = HorizontalAlignment.Left,
            TextWrapping = TextWrapping.Wrap, AcceptsReturn = false };
        var prizesCaption = new TextBox { Header = "Подпись над барабаном · призы", Text = _settings.PrizesCaption,
            MaxLength = 200, Width = 620, HorizontalAlignment = HorizontalAlignment.Left,
            TextWrapping = TextWrapping.Wrap, AcceptsReturn = false };
        var showCountdown = new ToggleSwitch { Header = "Показывать таймер над барабаном", IsOn = _settings.ShowCountdown };
        var countdownMinutes = new NumberBox { Header = "Длительность таймера, минуты", Minimum = 1, Maximum = 1440,
            SmallChange = 1, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            Value = Math.Max(1, _settings.CountdownSeconds / 60), Width = 180,
            HorizontalAlignment = HorizontalAlignment.Left };
        var countdownCaption = new TextBox { Header = "Текст над таймером", Text = _settings.CountdownCaption,
            MaxLength = 200, Width = 620, HorizontalAlignment = HorizontalAlignment.Left,
            TextWrapping = TextWrapping.Wrap, AcceptsReturn = false };
        var countdownRingColor = new ColorPicker { Color = ParseColor(_settings.CountdownRingColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        var countdownHint = new TextBlock { Text = "Подпись — до 200 символов. Нажмите на круг над барабаном, чтобы запустить или приостановить отсчёт. При нуле таймер сразу скроется и выключится.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.8 };
        var winnerEffect = new ComboBox { Header = "Анимация победы", Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
        winnerEffect.Items.Add("Шарики"); winnerEffect.Items.Add("Конфетти-салют");
        winnerEffect.Items.Add("Звёздный дождь"); winnerEffect.Items.Add("Случайный при каждой победе");
        winnerEffect.SelectedIndex = _settings.WinnerEffect switch { "stars" => 1, "sparks" => 2, "random" => 3, _ => 0 };
        var effectPreview = new Canvas { Width = 260, Height = 110, Background = new SolidColorBrush(Color.FromArgb(170, 10, 21, 35)) };
        var previewButton = new Button { Content = "Показать пример" };
        var effectPreviewRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        effectPreviewRow.Children.Add(effectPreview);
        var effectControls = new StackPanel { Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        effectControls.Children.Add(winnerEffect);
        effectControls.Children.Add(previewButton);
        effectPreviewRow.Children.Add(effectControls);
        previewButton.Click += (_, _) =>
        {
            var kind = winnerEffect.SelectedIndex switch { 1 => "stars", 2 => "sparks", 3 => new[] { "balloons", "stars", "sparks" }[Random.Shared.Next(3)], _ => "balloons" };
            if (kind == "balloons")
            {
                effectPreview.Children.Clear();
                AnimatePreviewBalloons(effectPreview);
            }
            else if (kind == "stars") AnimateConfettiSalute(effectPreview);
            else AnimateStarShower(effectPreview);
        };
        var drumColor = new ColorPicker { Color = ParseColor(_settings.DrumColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        var selectionColor = new ColorPicker { Color = ParseColor(_settings.SelectionColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        var winnerCardColor = new ColorPicker { Color = ParseColor(_settings.WinnerCardColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        var winnerCardBorderColor = new ColorPicker { Color = ParseColor(_settings.WinnerCardBorderColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        var primaryButtonColor = new ColorPicker { Color = ParseColor(_settings.PrimaryButtonColor), IsAlphaEnabled = false,
            ColorSpectrumComponents = ColorSpectrumComponents.SaturationValue };
        Button ColorSettingButton(string title, ColorPicker picker)
        {
            var swatch = new Border
            {
                Width = 24, Height = 24, CornerRadius = new CornerRadius(5),
                Background = new SolidColorBrush(picker.Color),
                BorderBrush = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)),
                BorderThickness = new Thickness(1)
            };
            var value = new TextBlock { Text = Hex(picker.Color), Opacity = 0.72 };
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            content.Children.Add(swatch);
            content.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(value);
            picker.ColorChanged += (_, _) =>
            {
                swatch.Background = new SolidColorBrush(picker.Color);
                value.Text = Hex(picker.Color);
            };
            return new Button
            {
                Content = content, Width = 520, HorizontalAlignment = HorizontalAlignment.Left,
                HorizontalContentAlignment = HorizontalAlignment.Left, MinHeight = 44,
                Flyout = new Flyout { Content = picker }
            };
        }
        var drumOpacity = new Slider { Header = "Непрозрачность барабана", Minimum = 0, Maximum = 100, StepFrequency = 5, Value = _settings.DrumOpacity * 100 };
        StackPanel PercentSlider(Slider slider, string caption)
        {
            slider.Header = null;
            slider.HorizontalAlignment = HorizontalAlignment.Stretch;
            slider.Margin = new Thickness(0, 4, 0, 0);
            var heading = new Grid();
            heading.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            heading.Children.Add(new TextBlock { Text = caption, TextWrapping = TextWrapping.Wrap });
            var value = new TextBlock { Text = $"{Math.Round(slider.Value):0}%", Opacity = 0.8, Margin = new Thickness(16, 0, 0, 0) };
            Grid.SetColumn(value, 1);
            heading.Children.Add(value);
            slider.ValueChanged += (_, _) => value.Text = $"{Math.Round(slider.Value):0}%";
            var row = new StackPanel { Width = 520, HorizontalAlignment = HorizontalAlignment.Left };
            row.Children.Add(heading);
            row.Children.Add(slider);
            return row;
        }
        var resetBackground = false;
        var resetBackgroundButton = new Button { Content = "Вернуть стандартный фон" };
        var backgroundStatus = new TextBlock { Text = _settings.BackgroundFormat is null ? "Используется стандартный фон" : "Используется свой фон" };
        resetBackgroundButton.Click += (_, _) => { resetBackground = true; backgroundStatus.Text = "Стандартный фон будет восстановлен после сохранения"; };
        var logoStatus = new TextBlock { Text = File.Exists(RaffleData.LogoPath) ? "Используется свой логотип" : "Используется стандартный логотип" };
        var resetLogo = false;
        var resetLogoButton = new Button { Content = "Вернуть стандартный логотип" };
        resetLogoButton.Click += (_, _) => { resetLogo = true; logoStatus.Text = "Стандартный логотип будет восстановлен после сохранения"; };
        var pickLogoButton = new Button { Content = "Выбрать свой логотип…" };
        var pickLogoRequested = false;
        var avatarPlaceholderStatus = new TextBlock
        {
            Text = File.Exists(RaffleData.AvatarPlaceholderPath)
                ? "Для участников без фото используется своя картинка"
                : "Для участников без фото используется стандартная картинка",
            VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap
        };
        var avatarPlaceholderPreview = new Image
        {
            Width = 48, Height = 48, Stretch = Stretch.UniformToFill,
            Source = new BitmapImage(new Uri(PlaceholderSource))
        };
        var avatarPlaceholderPreviewFrame = new Border
        {
            Width = 52, Height = 52, CornerRadius = new CornerRadius(26),
            BorderBrush = new SolidColorBrush(ParseColor("#D2691E")),
            BorderThickness = new Thickness(2), Child = avatarPlaceholderPreview
        };
        var avatarPlaceholderPreviewRow = new StackPanel
            { Orientation = Orientation.Horizontal, Spacing = 12 };
        avatarPlaceholderPreviewRow.Children.Add(avatarPlaceholderPreviewFrame);
        avatarPlaceholderPreviewRow.Children.Add(avatarPlaceholderStatus);
        var pickAvatarPlaceholderButton = new Button { Content = "Выбрать картинку для участников без фото…" };
        var pickAvatarPlaceholderRequested = false;
        var resetAvatarPlaceholder = false;
        var resetAvatarPlaceholderButton = new Button { Content = "Вернуть стандартную картинку" };
        resetAvatarPlaceholderButton.Click += (_, _) =>
        {
            resetAvatarPlaceholder = true;
            avatarPlaceholderStatus.Text = "Стандартная картинка будет восстановлена после сохранения";
            avatarPlaceholderPreview.Source = new BitmapImage(new Uri("ms-appx:///Assets/AvatarPlaceholder.png"));
        };
        var pickBackgroundButton = new Button { Content = "Выбрать свой фон…" };
        var pickBackgroundRequested = false;
        var dataFolderButton = new Button { Content = "Открыть папку данных" };
        var resetSettingsButton = new Button { Content = "Вернуть настройки по умолчанию" };
        var aboutPanel = new StackPanel { Spacing = 12 };
        var version = typeof(MainPage).Assembly.GetName().Version?.ToString(3) ?? "2.2.26";
        void AboutSection(string title, string description)
        {
            aboutPanel.Children.Add(new TextBlock { Text = title, FontSize = 18,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            aboutPanel.Children.Add(new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap });
        }
        aboutPanel.Children.Add(new TextBlock
        {
            Text = "Bon Raffle — приложение для розыгрышей среди людей и розыгрыша призов на мероприятиях, в сообществах и каналах MAX.",
            FontSize = 16, TextWrapping = TextWrapping.Wrap
        });
        AboutSection("Участники и свои списки",
            "Загрузите CSV либо создайте в приложении несколько списков с именами, названиями или номерами столиков и картинками. Переключайте, переименовывайте и удаляйте списки. История победителей каждого своего списка сохраняется отдельно.");
        AboutSection("Участники из MAX",
            "Подключите бота в разделе «Данные» и выгрузите участников канала или группы в CSV в папке «Загрузки». Затем загрузите CSV обычной кнопкой. Позиция победителя помогает найти его в списке MAX; сверяйте также имя, аватар и соседние записи. Внутренний ID не используется для поиска в мессенджере.");
        AboutSection("Розыгрыш призов",
            "Создавайте отдельные наборы призов с картинками, количеством и весом шанса. После выигрыша количество уменьшается, а шансы оставшихся призов пересчитываются.");
        AboutSection("Попробуйте сразу",
            "Включены четыре изменяемых примера: участники, столики и два набора призов. Их можно открыть, изменить или удалить как обычные списки.");
        AboutSection("Данные и лицензия",
            "Свои списки и картинки хранятся на этом компьютере в папке данных Bon Raffle. Токен MAX хранится в защищённом хранилище Windows. Исходный код распространяется по лицензии MIT.");
        aboutPanel.Children.Add(new TextBlock { Text = $"Версия: {version}\nАвтор: bonappetit.abc\n© 2026 Bon Raffle",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75 });
        aboutPanel.Children.Add(BuildUpdatePanel());
        var dataInfo = new TextBlock
        {
            Text = $"Локально сохранено: {_members.Count:N0} участников\n{RaffleData.DirectoryPath}",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75
        };
        var cacheInfo = new TextBlock { Text = $"Кеш аватаров: {FormatBytes(cacheBytes)}", TextWrapping = TextWrapping.Wrap };
        var clearCacheButton = new Button { Content = "Очистить кеш аватаров" };
        clearCacheButton.Click += async (_, _) =>
        {
            clearCacheButton.IsEnabled = false;
            try
            {
                await ClearAvatarCacheAsync();
                cacheInfo.Text = $"Кеш аватаров: {FormatBytes(_avatarFiles.SizeBytes)}";
            }
            catch (Exception ex) { cacheInfo.Text = $"Не удалось очистить кеш: {ex.Message}"; }
            finally { clearCacheButton.IsEnabled = true; }
        };
        dataFolderButton.Click += async (_, _) =>
        {
            try
            {
                Directory.CreateDirectory(RaffleData.DirectoryPath);
                Process.Start(new ProcessStartInfo { FileName = RaffleData.DirectoryPath, UseShellExecute = true });
            }
            catch (Exception ex) { await ShowErrorAsync("Не удалось открыть папку данных", ex); }
        };
        resetSettingsButton.Click += (_, _) =>
        {
            fullscreen.IsOn = true;
            avatars.IsOn = true;
            effects.IsOn = false;
            photo.IsOn = true;
            confirmReplace.IsOn = false;
            duration.SelectedIndex = 2;
            fps.SelectedIndex = 0;
            idle.Value = 100;
            spin.Value = 100;
            dim.Value = 55;
            homeCardColor.Color = ParseColor("#000000");
            homeCardTransparency.Value = 40;
            showRemaining.IsOn = true;
            participantsCaption.Text = "ЕЩЁ МОГУТ ВЫИГРАТЬ";
            prizesCaption.Text = "ДОСТУПНЫХ ВИДОВ ПРИЗОВ";
            showCountdown.IsOn = false;
            countdownMinutes.Value = 5;
            countdownCaption.Text = "Конкурс начнётся через";
            countdownRingColor.Color = ParseColor("#D2691E");
            winnerEffect.SelectedIndex = 0;
            drumColor.Color = ParseColor("#000000");
            selectionColor.Color = ParseColor("#3A6A96");
            winnerCardColor.Color = ParseColor("#D2691E");
            winnerCardBorderColor.Color = ParseColor("#E9B965");
            primaryButtonColor.Color = ParseColor("#D2691E");
            drumOpacity.Value = 60;
            resetBackground = true;
            backgroundStatus.Text = "Исходные параметры будут восстановлены после сохранения";
            resetLogo = true;
            logoStatus.Text = "Стандартный логотип будет восстановлен после сохранения";
            resetAvatarPlaceholder = true;
            avatarPlaceholderStatus.Text = "Стандартная картинка будет восстановлена после сохранения";
        };
        var generalPanel = new StackPanel { Spacing = 14 };
        generalPanel.Children.Add(fullscreen); generalPanel.Children.Add(avatars);
        generalPanel.Children.Add(photo); generalPanel.Children.Add(confirmReplace);
        generalPanel.Children.Add(effects);
        var rafflePanel = new StackPanel { Spacing = 14 };
        rafflePanel.Children.Add(duration); rafflePanel.Children.Add(fps);
        rafflePanel.Children.Add(PercentSlider(idle, "Скорость вращения до розыгрыша"));
        rafflePanel.Children.Add(PercentSlider(spin, "Скорость розыгрыша"));
        rafflePanel.Children.Add(showRemaining);
        rafflePanel.Children.Add(participantsCaption);
        rafflePanel.Children.Add(prizesCaption);
        rafflePanel.Children.Add(new TextBlock { Text = "Подписи участников и призов — до 200 символов каждая.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.8 });
        rafflePanel.Children.Add(showCountdown);
        rafflePanel.Children.Add(countdownMinutes);
        rafflePanel.Children.Add(countdownCaption);
        rafflePanel.Children.Add(ColorSettingButton("Цвет кольца таймера", countdownRingColor));
        rafflePanel.Children.Add(countdownHint);
        rafflePanel.Children.Add(effectPreviewRow);
        var appearancePanel = new StackPanel { Spacing = 14 };
        appearancePanel.Children.Add(backgroundStatus); appearancePanel.Children.Add(pickBackgroundButton);
        appearancePanel.Children.Add(resetBackgroundButton);
        appearancePanel.Children.Add(PercentSlider(dim, "Затемнение фона"));
        appearancePanel.Children.Add(logoStatus); appearancePanel.Children.Add(pickLogoButton);
        appearancePanel.Children.Add(resetLogoButton);
        appearancePanel.Children.Add(avatarPlaceholderPreviewRow);
        appearancePanel.Children.Add(pickAvatarPlaceholderButton);
        appearancePanel.Children.Add(resetAvatarPlaceholderButton);
        appearancePanel.Children.Add(ColorSettingButton("Цвет карточки на главной", homeCardColor));
        appearancePanel.Children.Add(PercentSlider(homeCardTransparency, "Прозрачность карточки на главной"));
        appearancePanel.Children.Add(resetHomeCardButton);
        appearancePanel.Children.Add(ColorSettingButton("Цвет барабана", drumColor));
        appearancePanel.Children.Add(PercentSlider(drumOpacity, "Непрозрачность барабана"));
        appearancePanel.Children.Add(ColorSettingButton("Цвет выбранной строки", selectionColor));
        appearancePanel.Children.Add(ColorSettingButton("Цвет карточки победителя", winnerCardColor));
        appearancePanel.Children.Add(ColorSettingButton("Цвет рамки карточки победителя", winnerCardBorderColor));
        appearancePanel.Children.Add(ColorSettingButton("Цвет основных кнопок", primaryButtonColor));
        var dataPanel = new StackPanel { Spacing = 14 };
        var maxChatId = new TextBox { Header = "chat_id канала или группы MAX", Text = _settings.MaxChatId,
            PlaceholderText = "Пример: -123456789 (не настоящий ID)", Width = 620,
            HorizontalAlignment = HorizontalAlignment.Left };
        var maxToken = new PasswordBox { Header = "Токен бота MAX", PlaceholderText = "Пример: сюда вставьте токен бота MAX",
            Width = 620, HorizontalAlignment = HorizontalAlignment.Left };
        var maxApiHost = new TextBox { Header = "Адрес API MAX", Text = _settings.MaxApiHost,
            PlaceholderText = "platform-api.max.ru", Width = 620, HorizontalAlignment = HorizontalAlignment.Left };
        var maxApiHostStatus = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.75,
            Text = "По умолчанию — platform-api.max.ru. При необходимости измените адрес здесь. MAX рекомендует добавить сертификат Минцифры в доверенные. Токен отправляется выбранному серверу max.ru." };
        var maxGuide = new StackPanel { Spacing = 10 };
        maxGuide.Children.Add(new TextBlock
        {
            Text = "Как подключить MAX", FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
        });
        foreach (var step in new[]
        {
            "1. Создайте бота в MAX для бизнеса и скопируйте его токен.",
            "2. Добавьте бота администратором канала или группы.",
            "3. Получите chat_id канала или группы через события MAX.",
            "4. Введите chat_id и токен ниже, затем сохраните настройки.",
            "5. На главной нажмите «Выгрузить участников из MAX». CSV появится в «Загрузках» — загрузите его в розыгрыш обычной кнопкой."
        })
        {
            maxGuide.Children.Add(new TextBlock { Text = step, TextWrapping = TextWrapping.Wrap });
        }
        var maxManualLink = new HyperlinkButton
        {
            Content = "Инструкция MAX: как получить chat_id",
            NavigateUri = new Uri("https://dev.max.ru/docs-api/use-cases/getting-chat-id")
        };
        maxGuide.Children.Add(maxManualLink);
        maxGuide.Children.Add(new HyperlinkButton
        {
            Content = "Официальный метод API: получение участников",
            NavigateUri = new Uri("https://dev.max.ru/docs-api/methods/GET/chats/-chatId-/members")
        });
        maxGuide.Children.Add(new HyperlinkButton
        {
            Content = "Рекомендация MAX по адресу и сертификату",
            NavigateUri = new Uri("https://dev.max.ru/docs-api")
        });
        var maxGuideCard = new Border
        {
            Padding = new Thickness(16), CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(34, 58, 106, 150)),
            Child = maxGuide
        };
        var maxTokenStatus = new TextBlock { Text = string.IsNullOrEmpty(MaxConnection.LoadToken()) ? "Токен ещё не сохранён" : "Токен сохранён" };
        var clearMaxTokenButton = new Button { Content = "Удалить подключение MAX" };
        var clearMaxToken = false;
        clearMaxTokenButton.Click += (_, _) =>
        {
            maxToken.Password = "";
            maxChatId.Text = "";
            clearMaxToken = true;
            maxTokenStatus.Text = "Токен и chat_id будут удалены после сохранения настроек";
        };
        var openVaultButton = new Button { Content = "Открыть хранилище паролей Windows" };
        openVaultButton.Click += async (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo { FileName = "control.exe", Arguments = "/name Microsoft.CredentialManager", UseShellExecute = true }); }
            catch (Exception ex) { await ShowErrorAsync("Не удалось открыть хранилище паролей", ex); }
        };
        dataPanel.Children.Add(new TextBlock { Text = "Выгрузка из MAX", FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        dataPanel.Children.Add(maxGuideCard);
        dataPanel.Children.Add(maxChatId); dataPanel.Children.Add(maxToken);
        dataPanel.Children.Add(maxApiHost); dataPanel.Children.Add(maxApiHostStatus);
        dataPanel.Children.Add(new TextBlock
        {
            Text = "chat_id хранится в папке данных Bon Raffle. Токен хранится только в защищённом хранилище Windows.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.7
        });
        dataPanel.Children.Add(maxTokenStatus); dataPanel.Children.Add(clearMaxTokenButton);
        dataPanel.Children.Add(openVaultButton);
        dataPanel.Children.Add(cacheInfo); dataPanel.Children.Add(clearCacheButton);
        Window? settingsWindow = null;
        var clearCreatedButton = new Button { Content = "Удалить все свои списки и картинки" };
        clearCreatedButton.Click += async (_, _) =>
        {
            var confirm = new ContentDialog
            {
                XamlRoot = settingsWindow?.Content.XamlRoot ?? XamlRoot, Title = "Удалить созданные списки?",
                Content = "Будут удалены все свои списки участников и призов, их картинки и история победителей своих списков. Файлы MAX в «Загрузках» и кеш аватаров останутся.",
                PrimaryButtonText = "Удалить", CloseButtonText = "Отмена"
            };
            if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
            try
            {
                await ClearCreatedListsAsync();
                dataInfo.Text = $"Локально сохранено: {_members.Count:N0} участников\n{RaffleData.DirectoryPath}";
            }
            catch (Exception ex) { dataInfo.Text = $"Не удалось удалить свои списки: {ex.Message}"; }
        };
        dataPanel.Children.Add(clearCreatedButton);
        dataPanel.Children.Add(dataInfo); dataPanel.Children.Add(dataFolderButton);
        dataPanel.Children.Add(resetSettingsButton);
        var maxInstructionsPanel = new StackPanel { Spacing = 14 };
        maxInstructionsPanel.Children.Add(new TextBlock { Text = "Инструкция MAX", FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        foreach (var step in new[]
        {
            "1. В разделе «Данные» сохраните chat_id канала и токен бота-администратора.",
            "2. На главной нажмите «Выгрузить участников из MAX». CSV сохранится в папке «Загрузки».",
            "3. Загрузите этот CSV кнопкой «Загрузить участников» и проведите розыгрыш.",
            "4. На карточке победителя запомните его позицию в списке. Откройте участников канала MAX и найдите примерно эту строку.",
            "5. Сверьте имя, аватар и соседние записи. Если порядок участников в MAX изменился после выгрузки, номер строки может отличаться.",
            "Внутренний ID из CSV нужен приложению для истории розыгрыша; поиск пользователя по нему в MAX не предусмотрен."
        })
            maxInstructionsPanel.Children.Add(new TextBlock { Text = step, TextWrapping = TextWrapping.Wrap });
        maxInstructionsPanel.Children.Add(new HyperlinkButton
        {
            Content = "Официальная инструкция MAX: как получить chat_id",
            NavigateUri = new Uri("https://dev.max.ru/docs-api/use-cases/getting-chat-id")
        });
        var panels = new Dictionary<string, StackPanel>
        {
            ["Основное"] = generalPanel, ["Розыгрыш"] = rafflePanel,
            ["Внешний вид"] = appearancePanel, ["Данные"] = dataPanel,
            ["Инструкция MAX"] = maxInstructionsPanel,
            ["О программе"] = aboutPanel
        };
        var scroller = new ScrollViewer { VerticalAlignment = VerticalAlignment.Stretch };
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var tabButtons = new Dictionary<string, Button>();
        void SelectTab(string name)
        {
            scroller.Content = panels[name];
            scroller.ChangeView(null, 0, null, true);
            foreach (var (key, button) in tabButtons)
            {
                button.Background = key == name
                    ? new SolidColorBrush(ParseColor(_settings.PrimaryButtonColor))
                    : new SolidColorBrush(Color.FromArgb(80, 255, 255, 255));
                button.Foreground = new SolidColorBrush(Colors.White);
            }
        }
        foreach (var name in panels.Keys)
        {
            var button = new Button { Content = name, MinHeight = 38 };
            button.Click += (_, _) => SelectTab(name);
            tabButtons[name] = button;
            tabs.Children.Add(button);
        }
        var tabStrip = new ScrollViewer
        {
            Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled
        };
        var settingsOverlay = new Grid
        {
            Background = new SolidColorBrush(ParseColor("#252525")),
            Padding = new Thickness(32, 24, 32, 20)
        };
        settingsOverlay.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        settingsOverlay.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        settingsOverlay.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        settingsOverlay.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var title = new TextBlock { Text = "Настройки", FontSize = 28,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 16) };
        settingsOverlay.Children.Add(title);
        Grid.SetRow(tabStrip, 1);
        tabStrip.Margin = new Thickness(0, 0, 0, 16);
        settingsOverlay.Children.Add(tabStrip);
        Grid.SetRow(scroller, 2);
        settingsOverlay.Children.Add(scroller);
        var footer = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 16, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var saveButton = new Button { Content = "Сохранить", HorizontalAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(ParseColor("#A8CBDD")), Foreground = new SolidColorBrush(Colors.Black) };
        var cancelButton = new Button { Content = "Отмена", HorizontalAlignment = HorizontalAlignment.Stretch };
        Grid.SetColumn(cancelButton, 1);
        footer.Children.Add(saveButton);
        footer.Children.Add(cancelButton);
        Grid.SetRow(footer, 3);
        settingsOverlay.Children.Add(footer);
        SelectTab("Основное");
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Finish(bool save)
        {
            completion.TrySetResult(save);
            settingsWindow?.Close();
        }
        saveButton.Click += (_, _) =>
        {
            try { MaxRosterExporter.NormalizeHost(maxApiHost.Text); Finish(true); }
            catch (InvalidDataException ex)
            {
                SelectTab("Данные");
                maxApiHostStatus.Text = ex.Message;
                maxApiHost.Focus(FocusState.Programmatic);
            }
        };
        cancelButton.Click += (_, _) => Finish(false);
        settingsOverlay.KeyDown += (_, args) =>
        {
            if (args.Key != Windows.System.VirtualKey.Escape) return;
            Finish(false);
            args.Handled = true;
        };
        pickLogoButton.Click += (_, _) => { pickLogoRequested = true; Finish(true); };
        pickAvatarPlaceholderButton.Click += (_, _) => { pickAvatarPlaceholderRequested = true; Finish(true); };
        pickBackgroundButton.Click += (_, _) => { pickBackgroundRequested = true; Finish(true); };
        settingsWindow = new Window { Title = "Настройки — Bon Raffle", Content = settingsOverlay };
        settingsWindow.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        var mainBounds = MainWindow.Instance.AppWindow;
        const int settingsWidth = 1060;
        const int settingsHeight = 780;
        settingsWindow.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            mainBounds.Position.X + Math.Max(0, (mainBounds.Size.Width - settingsWidth) / 2),
            mainBounds.Position.Y + Math.Max(0, (mainBounds.Size.Height - settingsHeight) / 2),
            settingsWidth, settingsHeight));
        settingsWindow.Closed += (_, _) =>
        {
            PageRoot.IsHitTestVisible = true;
            completion.TrySetResult(false);
        };
        PageRoot.IsHitTestVisible = false;
        settingsWindow.Activate();
        var result = await completion.Task;
        if (result || pickLogoRequested || pickBackgroundRequested || pickAvatarPlaceholderRequested)
        {
            var wasFullscreen = _settings.Fullscreen;
            _settings.Fullscreen = fullscreen.IsOn;
            _settings.LaunchPreferenceConfigured = true;
            _settings.ShowAvatars = avatars.IsOn;
            _settings.UseBackgroundPhoto = photo.IsOn;
            _settings.ConfirmReplace = confirmReplace.IsOn;
            _settings.ReduceEffects = effects.IsOn;
            _settings.WinnerEffect = winnerEffect.SelectedIndex switch { 1 => "stars", 2 => "sparks", 3 => "random", _ => "balloons" };
            _settings.SpinSeconds = duration.SelectedIndex switch { 0 => 8, 1 => 12, _ => 20 };
            _settings.AnimationFps = fps.SelectedIndex switch { 1 => 30, 2 => 60, 3 => 120, 4 => 144, _ => 0 };
            _settings.IdleSpeedPercent = (int)idle.Value;
            _settings.SpinSpeedPercent = (int)spin.Value;
            _settings.BackgroundDim = (int)dim.Value;
            _settings.HomeCardColor = Hex(homeCardColor.Color);
            _settings.HomeCardOpacity = 1 - homeCardTransparency.Value / 100;
            _settings.ShowRemainingHeader = showRemaining.IsOn;
            _settings.ParticipantsCaption = participantsCaption.Text;
            _settings.PrizesCaption = prizesCaption.Text;
            _settings.ShowCountdown = showCountdown.IsOn;
            _settings.CountdownSeconds = double.IsFinite(countdownMinutes.Value)
                ? (int)Math.Round(countdownMinutes.Value) * 60 : 300;
            _settings.CountdownCaption = countdownCaption.Text;
            _settings.CountdownRingColor = Hex(countdownRingColor.Color);
            _settings.DrumColor = Hex(drumColor.Color);
            _settings.SelectionColor = Hex(selectionColor.Color);
            _settings.SelectionColorVersion = 1;
            _settings.WinnerCardColor = Hex(winnerCardColor.Color);
            _settings.WinnerCardBorderColor = Hex(winnerCardBorderColor.Color);
            _settings.WinnerCardColorVersion = 1;
            _settings.PrimaryButtonColor = Hex(primaryButtonColor.Color);
            _settings.PrimaryButtonColorVersion = 1;
            _settings.DrumOpacity = drumOpacity.Value / 100;
            _settings.MaxChatId = maxChatId.Text.Trim();
            try
            {
                _settings.MaxApiHost = MaxRosterExporter.NormalizeHost(maxApiHost.Text);
                if (_settings.MaxChatId.Length > 0 && !long.TryParse(_settings.MaxChatId, out _))
                    throw new InvalidDataException("chat_id MAX должен быть целым числом.");
                if (maxToken.Password.Length > 0) MaxConnection.SaveToken(maxToken.Password.Trim());
                else if (clearMaxToken) MaxConnection.DeleteToken();
                if (pickLogoRequested) await PickLogoAsync();
                if (pickBackgroundRequested) await PickBackgroundAsync();
                else if (resetBackground)
                {
                    _settings.BackgroundFormat = null;
                    if (File.Exists(RaffleData.BackgroundPath)) File.Delete(RaffleData.BackgroundPath);
                }
                if (resetLogo && !pickLogoRequested && File.Exists(RaffleData.LogoPath))
                    File.Delete(RaffleData.LogoPath);
                if (pickAvatarPlaceholderRequested) await PickAvatarPlaceholderAsync();
                else if (resetAvatarPlaceholder && File.Exists(RaffleData.AvatarPlaceholderPath))
                    File.Delete(RaffleData.AvatarPlaceholderPath);
                _settings.Validate();
                await RaffleData.SaveSettingsAsync(_settings);
                ApplySettings(refreshBackground: pickBackgroundRequested || resetBackground,
                    refreshLogo: pickLogoRequested || resetLogo);
                if (wasFullscreen != _settings.Fullscreen) SetFullscreen(_settings.Fullscreen);
                RefreshVisibleAvatars();
            }
            catch (Exception ex) { await ShowErrorAsync("Не удалось сохранить настройки", ex); }
        }
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось открыть настройки", ex); }
        finally
        {
            _settingsOpening = false;
            FocusPrimaryAction();
            if (_raffleActive) StartRendering();
        }
    }

    private async Task PickBackgroundAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance));
        picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg"); picker.FileTypeFilter.Add(".webp");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        if (new FileInfo(file.Path).Length > 30 * 1024 * 1024) throw new InvalidDataException("Фон больше 30 МБ.");
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        File.Copy(file.Path, RaffleData.BackgroundPath, true);
        _settings.BackgroundFormat = Path.GetExtension(file.Path).TrimStart('.').ToUpperInvariant();
    }

    private async Task PickLogoAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance));
        picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg"); picker.FileTypeFilter.Add(".webp");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        if (new FileInfo(file.Path).Length > 20 * 1024 * 1024) throw new InvalidDataException("Логотип больше 20 МБ.");
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        File.Copy(file.Path, RaffleData.LogoPath, true);
    }

    private async Task PickAvatarPlaceholderAsync()
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance));
        picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg"); picker.FileTypeFilter.Add(".webp");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        if (new FileInfo(file.Path).Length > 5 * 1024 * 1024)
            throw new InvalidDataException("Картинка должна быть меньше 5 МБ.");
        using (var stream = await file.OpenReadAsync())
        {
            var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
            if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0
                || decoder.PixelWidth > 4096 || decoder.PixelHeight > 4096)
                throw new InvalidDataException("Выберите картинку размером до 4096 × 4096 пикселей.");
        }
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        var destination = RaffleData.AvatarPlaceholderPath;
        if (!Path.GetFullPath(file.Path).Equals(Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase))
            File.Copy(file.Path, destination, true);
    }

    private void ApplySettings(bool refreshBackground = true, bool refreshLogo = true)
    {
        var alpha = (byte)Math.Clamp(_settings.BackgroundDim * 255 / 100, 0, 255);
        BackgroundShade.Background = new SolidColorBrush(Color.FromArgb(alpha, 0, 0, 0));
        var homeColor = ParseColor(_settings.HomeCardColor);
        HomeCard.Background = new SolidColorBrush(Color.FromArgb((byte)(_settings.HomeCardOpacity * 255),
            homeColor.R, homeColor.G, homeColor.B));
        RemainingHeader.Visibility = _settings.ShowRemainingHeader ? Visibility.Visible : Visibility.Collapsed;
        RemainingCaption.Text = _prizeMode ? _settings.PrizesCaption : _settings.ParticipantsCaption;
        ApplyCountdownSettings();
        var drum = ParseColor(_settings.DrumColor);
        DrumBorder.Background = new SolidColorBrush(Color.FromArgb((byte)(_settings.DrumOpacity * 255), drum.R, drum.G, drum.B));
        var selectedColor = ParseColor(_settings.SelectionColor);
        DrumBorder.BorderBrush = new SolidColorBrush(selectedColor);
        SelectionFrame.Background = new SolidColorBrush(Color.FromArgb(70, selectedColor.R, selectedColor.G, selectedColor.B));
        SelectionFrame.BorderBrush = new SolidColorBrush(selectedColor);
        WinnerCard.Background = new SolidColorBrush(ParseColor(_settings.WinnerCardColor));
        WinnerCard.BorderBrush = new SolidColorBrush(ParseColor(_settings.WinnerCardBorderColor));
        ApplyPrimaryButtonColors(ParseColor(_settings.PrimaryButtonColor));
        var path = RaffleData.BackgroundPath;
        BackgroundImage.Visibility = _settings.UseBackgroundPhoto ? Visibility.Visible : Visibility.Collapsed;
        if (refreshBackground)
        {
            BackgroundImage.Source = File.Exists(path) && _settings.BackgroundFormat is not null
                ? new BitmapImage(new Uri(path)) : new BitmapImage(new Uri("ms-appx:///Assets/background-bon-raffle.png"));
            if (_settings.UseBackgroundPhoto && !_settings.ReduceEffects) FadeIn(BackgroundImage);
        }
        if (refreshLogo)
            HeaderLogo.Source = File.Exists(RaffleData.LogoPath)
                ? new BitmapImage(new Uri(RaffleData.LogoPath))
                : new BitmapImage(new Uri("ms-appx:///Assets/logo-bon-raffle.png"));
        if (_slotBorders.Count > 0) HighlightCenter();
        if (_raffleActive && !_spinning) { StopRendering(); StartRendering(); }
    }

    private void HeaderLogo_ImageOpened(object sender, RoutedEventArgs e)
    {
        if (HeaderLogo.Source is not BitmapImage bitmap || bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0)
            return;
        var scale = Math.Min(1, Math.Min(300.0 / bitmap.PixelWidth, 70.0 / bitmap.PixelHeight));
        HeaderLogo.Width = bitmap.PixelWidth * scale;
        HeaderLogo.Height = bitmap.PixelHeight * scale;
    }

    private void SetFullscreen(bool enabled)
    {
        MainWindow.Instance.SetFullscreen(enabled);
    }

    private void PageRoot_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        if (_settingsOpening || _avatarDialogOpening ||
            VisualTreeHelper.GetOpenPopupsForXamlRoot(XamlRoot).Count > 0) return;
        if (_spinning) { e.Handled = true; return; }
        // Handle Enter before the focused navigation button receives it.
        e.Handled = true;
        var action = HomeView.Visibility == Visibility.Visible ? "home" :
            RaffleView.Visibility == Visibility.Visible ? "raffle" :
            WinnerView.Visibility == Visibility.Visible ? "winner" : "";
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_spinning) return;
            if (action == "home" && HomeView.Visibility == Visibility.Visible && OpenRaffleButton.IsEnabled)
            {
                OpenRaffleButton.Focus(FocusState.Programmatic);
                OpenRaffle_Click(OpenRaffleButton, new RoutedEventArgs());
            }
            else if (action == "raffle" && RaffleView.Visibility == Visibility.Visible && SpinButton.IsEnabled)
            {
                SpinButton.Focus(FocusState.Programmatic);
                Spin_Click(SpinButton, new RoutedEventArgs());
            }
            else if (action == "winner" && WinnerView.Visibility == Visibility.Visible && AgainButton.IsEnabled)
            {
                AgainButton.Focus(FocusState.Programmatic);
                OpenRaffle_Click(AgainButton, new RoutedEventArgs());
            }
        });
    }

    private async void PageRoot_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.F11) return;
        _settings.Fullscreen = !_settings.Fullscreen;
        _settings.LaunchPreferenceConfigured = true;
        SetFullscreen(_settings.Fullscreen);
        await RaffleData.SaveSettingsAsync(_settings);
        e.Handled = true;
    }

    private async Task ShowErrorAsync(string title, Exception ex)
    {
        var details = string.IsNullOrWhiteSpace(ex.Message)
            ? $"Windows вернула ошибку 0x{ex.HResult:X8} ({ex.GetType().Name}). Повторите попытку; подробности сохранены в папке данных Bon Raffle."
            : ex.Message;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = details, CloseButtonText = "Закрыть" };
        await dialog.ShowAsync();
    }

    private static string FormatBytes(long bytes) => bytes < 1024 * 1024
        ? $"{bytes / 1024.0:N1} КБ" : $"{bytes / 1048576.0:N1} МБ";
}
