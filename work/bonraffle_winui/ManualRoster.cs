using System.Text.Json;
using System.Text.Json.Serialization;

namespace BonRaffle;

internal sealed class ManualListProfile
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("members")] public List<Member> Members { get; set; } = [];
    [JsonPropertyName("winnerIds")] public List<string> WinnerIds { get; set; } = [];
}

internal sealed class ManualListCatalog
{
    [JsonPropertyName("activeId")] public string? ActiveId { get; set; }
    [JsonPropertyName("lists")] public List<ManualListProfile> Lists { get; set; } = [];
}

internal static class ManualRoster
{
    private static string CatalogPath => Path.Combine(RaffleData.DirectoryPath, "manual-lists.json");
    private static string LegacyPath => Path.Combine(RaffleData.DirectoryPath, "manual-members.json");
    private static string PhotoFolder => Path.Combine(RaffleData.DirectoryPath, "manual-avatars");

    public static async Task<ManualListCatalog> LoadCatalogAsync()
    {
        try
        {
            await using var input = File.OpenRead(CatalogPath);
            return await JsonSerializer.DeserializeAsync<ManualListCatalog>(input) ?? new();
        }
        catch (FileNotFoundException) { }
        catch (JsonException) { return new(); }

        List<Member> old;
        try
        {
            await using var input = File.OpenRead(LegacyPath);
            old = await JsonSerializer.DeserializeAsync<List<Member>>(input) ?? [];
        }
        catch (Exception ex) when (ex is FileNotFoundException or JsonException) { return new(); }
        if (old.Count == 0) return new();

        var catalog = new ManualListCatalog();
        var profile = new ManualListProfile
        {
            Id = "list-" + Guid.NewGuid().ToString("N"), Name = "Мой список", Members = old
        };
        var current = await RaffleData.LoadMembersAsync();
        if (RaffleData.Fingerprint(current) == RaffleData.Fingerprint(old))
        {
            catalog.ActiveId = profile.Id;
            var history = await RaffleData.LoadWinnerHistoryAsync();
            if (history.ListFingerprint == RaffleData.Fingerprint(old))
                profile.WinnerIds = history.Ids.Intersect(old.Select(m => m.Id)).ToList();
        }
        catalog.Lists.Add(profile);
        await SaveCatalogAsync(catalog);
        return catalog;
    }

    public static string? LocalPhoto(string? source)
    {
        if (string.IsNullOrWhiteSpace(source)) return null;
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || !uri.IsFile) return null;
        var path = Path.GetFullPath(uri.LocalPath);
        var folder = Path.GetFullPath(PhotoFolder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return path.StartsWith(folder, StringComparison.OrdinalIgnoreCase) && File.Exists(path) ? path : null;
    }

    public static async Task SaveCatalogAsync(ManualListCatalog catalog)
    {
        if (catalog.Lists.Count > 100) throw new InvalidDataException("Можно сохранить не больше 100 своих списков.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Directory.CreateDirectory(PhotoFolder);
        foreach (var profile in catalog.Lists)
        {
            profile.Name = profile.Name.Trim();
            if (profile.Name.Length is < 1 or > 80 || !names.Add(profile.Name))
                throw new InvalidDataException("Названия списков должны быть разными и не длиннее 80 символов.");
            if (!profile.Id.StartsWith("list-", StringComparison.Ordinal) ||
                !Guid.TryParse(profile.Id.AsSpan(5), out _))
                throw new InvalidDataException("Некорректный ID списка.");
            if (profile.Members.Count > 100_000)
                throw new InvalidDataException("В списке не может быть больше 100 000 записей.");
            var prepared = new List<Member>(profile.Members.Count);
            foreach (var entry in profile.Members)
            {
                var name = entry.Name.Trim();
                if (name.Length == 0) throw new InvalidDataException("У каждой записи должно быть имя или название.");
                if (!entry.Id.StartsWith("manual-", StringComparison.Ordinal) ||
                    !Guid.TryParse(entry.Id.AsSpan(7), out _))
                    throw new InvalidDataException("Некорректный ID ручной записи.");
                var avatar = "";
                if (!string.IsNullOrWhiteSpace(entry.Avatar))
                {
                    var existing = LocalPhoto(entry.Avatar);
                    if (existing is not null) avatar = new Uri(existing).AbsoluteUri;
                    else
                    {
                        var path = entry.Avatar;
                        if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
                        if (!File.Exists(path)) throw new FileNotFoundException("Выбранная картинка не найдена.", path);
                        var extension = Path.GetExtension(path).ToLowerInvariant();
                        if (extension is not (".png" or ".jpg" or ".jpeg" or ".webp") ||
                            new FileInfo(path).Length > 5 * 1024 * 1024)
                            throw new InvalidDataException("Картинка должна быть PNG, JPG или WebP до 5 МБ.");
                        var destination = Path.Combine(PhotoFolder, entry.Id + extension);
                        File.Copy(path, destination, true);
                        avatar = new Uri(destination).AbsoluteUri;
                    }
                }
                prepared.Add(new Member { Id = entry.Id, Name = name, Username = "", Avatar = avatar });
            }
            profile.Members = prepared;
            var ids = prepared.Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
            profile.WinnerIds = profile.WinnerIds.Where(ids.Contains).Distinct(StringComparer.Ordinal).ToList();
        }
        if (catalog.ActiveId is not null && !catalog.Lists.Any(p => p.Id == catalog.ActiveId))
            catalog.ActiveId = null;
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        var temp = CatalogPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var output = File.Create(temp)) await JsonSerializer.SerializeAsync(output, catalog);
            File.Move(temp, CatalogPath, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    public static async Task<ManualListProfile> ActivateAsync(ManualListCatalog catalog, string id)
    {
        var profile = catalog.Lists.FirstOrDefault(p => p.Id == id)
            ?? throw new InvalidDataException("Выберите свой список.");
        if (profile.Members.Count == 0) throw new InvalidDataException("Добавьте хотя бы одну запись.");
        catalog.ActiveId = id;
        await SaveCatalogAsync(catalog);
        await RaffleData.SaveMembersAsync(profile.Members);
        await RaffleData.SaveWinnerHistoryAsync(new WinnerHistory
        {
            ListFingerprint = RaffleData.Fingerprint(profile.Members), Ids = profile.WinnerIds
        });
        return profile;
    }

    public static async Task DeactivateAsync()
    {
        var catalog = await LoadCatalogAsync();
        if (catalog.ActiveId is null) return;
        catalog.ActiveId = null;
        await SaveCatalogAsync(catalog);
    }

    public static async Task RecordWinnerAsync(IReadOnlyList<Member> members, string winnerId)
    {
        var catalog = await LoadCatalogAsync();
        var profile = catalog.Lists.FirstOrDefault(p => p.Id == catalog.ActiveId);
        if (profile is null || RaffleData.Fingerprint(profile.Members) != RaffleData.Fingerprint(members)) return;
        if (!profile.WinnerIds.Contains(winnerId, StringComparer.Ordinal))
        {
            profile.WinnerIds.Add(winnerId);
            await SaveCatalogAsync(catalog);
        }
    }
}
