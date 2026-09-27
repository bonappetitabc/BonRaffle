using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace BonRaffle;

public sealed partial class MainPage
{
    private bool _prizeMode;
    private List<Prize> _prizes = [];
    private List<Member> _participantMembers = [];
    private readonly HashSet<string> _participantWinnerIds = new(StringComparer.Ordinal);
    private string _activePrizeListName = "";

    private static List<Member> PrizeMembers(IEnumerable<Prize> prizes) => prizes
        .Where(p => p.Quantity > 0)
        .Select(p => new Member { Id = p.Id, Name = p.Name, Avatar = p.Image, Username = "" })
        .ToList();

    private async Task RestoreRaffleModeAsync()
    {
        _participantMembers = _members;
        _participantWinnerIds.Clear();
        _participantWinnerIds.UnionWith(_winnerIds);
        var catalog = await PrizeStore.LoadCatalogAsync();
        var active = catalog.Lists.FirstOrDefault(p => p.Id == catalog.ActiveId);
        if (_settings.RaffleMode == "prizes" && active is not null)
        {
            _prizeMode = true;
            _prizes = active.Prizes;
            _activePrizeListName = active.Name;
            _members = PrizeMembers(_prizes);
            _winnerIds.Clear();
        }
    }

    private async Task ActivatePrizeListAsync(PrizeListCatalog catalog, string id)
    {
        var profile = catalog.Lists.FirstOrDefault(p => p.Id == id)
            ?? throw new InvalidDataException("Выберите список призов.");
        catalog.ActiveId = id;
        await PrizeStore.SaveCatalogAsync(catalog);
        if (!_prizeMode)
        {
            _participantMembers = _members;
            _participantWinnerIds.Clear();
            _participantWinnerIds.UnionWith(_winnerIds);
        }
        _prizeMode = true;
        _prizes = profile.Prizes;
        _activePrizeListName = profile.Name;
        _members = PrizeMembers(_prizes);
        _winnerIds.Clear();
        _settings.RaffleMode = "prizes";
        await RaffleData.SaveSettingsAsync(_settings);
        _avatarCache.Clear(); _avatarRequests.Clear();
        _avatarFiles.StartBatch(_members.Select(m => m.Avatar));
        UpdateCount();
        ShowView("home");
    }

    private async Task ActivateParticipantModeAsync()
    {
        if (!_prizeMode) return;
        _prizeMode = false;
        _members = _participantMembers;
        _winnerIds.Clear();
        _winnerIds.UnionWith(_participantWinnerIds);
        _settings.RaffleMode = "participants";
        await RaffleData.SaveSettingsAsync(_settings);
        _avatarCache.Clear(); _avatarRequests.Clear();
        _avatarFiles.StartBatch(_members.Select(m => m.Avatar));
        UpdateCount();
        ShowView("home");
    }

    private async Task ClearCreatedListsAsync()
    {
        var manual = await ManualRoster.LoadCatalogAsync();
        var ownActive = manual.Lists.Any(p => p.Id == manual.ActiveId &&
            RaffleData.Fingerprint(p.Members) == RaffleData.Fingerprint(_prizeMode ? _participantMembers : _members));
        if (_prizeMode) await ActivateParticipantModeAsync();
        var root = Path.GetFullPath(RaffleData.DirectoryPath).TrimEnd(Path.DirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        foreach (var name in new[] { "manual-lists.json", "manual-members.json", "prize-lists.json", "prizes.json" })
        {
            var target = Path.GetFullPath(Path.Combine(root, name));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Некорректный путь данных.");
            if (File.Exists(target)) File.Delete(target);
        }
        foreach (var name in new[] { "manual-avatars", "prize-images" })
        {
            var target = Path.GetFullPath(Path.Combine(root, name));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Некорректный путь изображений.");
            if (Directory.Exists(target)) Directory.Delete(target, true);
        }
        _prizes = [];
        _activePrizeListName = "";
        if (ownActive)
        {
            _members = [];
            _winnerIds.Clear();
            _participantMembers = [];
            _participantWinnerIds.Clear();
            await RaffleData.SaveMembersAsync([]);
            await RaffleData.SaveWinnerHistoryAsync(new WinnerHistory());
        }
        _settings.RaffleMode = "participants";
        await RaffleData.SaveSettingsAsync(_settings);
        _avatarCache.Clear(); _avatarRequests.Clear();
        UpdateCount();
        ShowView("home");
    }

    private void ApplyModeUI()
    {
        var active = new SolidColorBrush(ParseColor("#D2691E"));
        var inactive = new SolidColorBrush(Color.FromArgb(120, 58, 106, 150));
        ParticipantsModeButton.Background = _prizeMode ? inactive : active;
        PrizesModeButton.Background = _prizeMode ? active : inactive;
        ImportButton.Visibility = _prizeMode ? Visibility.Collapsed : Visibility.Visible;
        ManualListButton.Visibility = _prizeMode ? Visibility.Collapsed : Visibility.Visible;
        MaxExportButton.Visibility = _prizeMode ? Visibility.Collapsed : Visibility.Visible;
        PrizeListButton.Visibility = _prizeMode ? Visibility.Visible : Visibility.Collapsed;
        OpenRaffleButton.Content = _prizeMode ? "Открыть розыгрыш призов" : "Открыть розыгрыш";
        SpinButton.Content = _prizeMode ? "Разыграть приз" : "Выбрать победителя";
        WinnerHeading.Text = _prizeMode ? "Выпал приз!" : "Поздравляем с победой!";
        RemainingCaption.Text = _prizeMode ? _settings.PrizesCaption : _settings.ParticipantsCaption;
        HomeSubtitle.Text = _prizeMode
            ? "Попробуйте демонстрационные призы или создайте свой набор."
            : "Попробуйте демонстрационный список или загрузите свой.";
    }

    private async void ParticipantsMode_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning) return;
        try { await ActivateParticipantModeAsync(); }
        catch (Exception ex) { await ShowErrorAsync("Не удалось переключить режим", ex); }
    }

    private async void PrizesMode_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning) return;
        try
        {
            var catalog = await PrizeStore.LoadCatalogAsync();
            if (catalog.ActiveId is null) { PrizeRaffle_Click(sender, e); return; }
            await ActivatePrizeListAsync(catalog, catalog.ActiveId);
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось открыть призы", ex); }
    }
}
