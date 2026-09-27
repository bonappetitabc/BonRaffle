using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BonRaffle;

public sealed class Prize
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("image")] public string Image { get; set; } = "";
    [JsonPropertyName("quantity")] public int Quantity { get; set; } = 1;
    [JsonPropertyName("weight")] public int Weight { get; set; } = 1;
}

public sealed class PrizeListProfile
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("prizes")] public List<Prize> Prizes { get; set; } = [];
}

public sealed class PrizeListCatalog
{
    [JsonPropertyName("activeId")] public string? ActiveId { get; set; }
    [JsonPropertyName("lists")] public List<PrizeListProfile> Lists { get; set; } = [];
}

public static class PrizeStore
{
    private static string FilePath => Path.Combine(RaffleData.DirectoryPath, "prizes.json");
    private static string CatalogPath => Path.Combine(RaffleData.DirectoryPath, "prize-lists.json");
    private static string ImageFolder => Path.Combine(RaffleData.DirectoryPath, "prize-images");

    public static async Task<List<Prize>> LoadAsync()
    {
        try
        {
            await using var stream = File.OpenRead(FilePath);
            return (await JsonSerializer.DeserializeAsync<List<Prize>>(stream) ?? [])
                .Where(p => p.Id.StartsWith("prize-", StringComparison.Ordinal)
                    && !string.IsNullOrWhiteSpace(p.Name) && p.Quantity is >= 0 and <= 10000
                    && p.Weight is >= 1 and <= 1000).ToList();
        }
        catch (Exception ex) when (ex is FileNotFoundException or JsonException) { return []; }
    }

    public static async Task<PrizeListCatalog> LoadCatalogAsync()
    {
        try
        {
            await using var stream = File.OpenRead(CatalogPath);
            return await JsonSerializer.DeserializeAsync<PrizeListCatalog>(stream) ?? new();
        }
        catch (FileNotFoundException) { }
        catch (JsonException) { return new(); }
        var legacy = await LoadAsync();
        if (legacy.Count == 0) return new();
        var id = "prizelist-" + Guid.NewGuid().ToString("N");
        var catalog = new PrizeListCatalog { ActiveId = id,
            Lists = [new PrizeListProfile { Id = id, Name = "Мои призы", Prizes = legacy }] };
        await SaveCatalogAsync(catalog);
        return catalog;
    }

    public static string? LocalImage(string? source)
    {
        if (string.IsNullOrWhiteSpace(source)) return null;
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || !uri.IsFile) return null;
        var path = Path.GetFullPath(uri.LocalPath);
        var folder = Path.GetFullPath(ImageFolder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return path.StartsWith(folder, StringComparison.OrdinalIgnoreCase) && File.Exists(path) ? path : null;
    }

    private static List<Prize> Prepare(IReadOnlyList<Prize> entries)
    {
        if (entries.Count > 1000) throw new InvalidDataException("Можно сохранить не больше 1000 видов призов.");
        Directory.CreateDirectory(ImageFolder);
        var prepared = new List<Prize>(entries.Count);
        foreach (var entry in entries)
        {
            var name = entry.Name.Trim();
            if (name.Length is < 1 or > 120) throw new InvalidDataException("Название приза: от 1 до 120 символов.");
            if (!entry.Id.StartsWith("prize-", StringComparison.Ordinal) ||
                !Guid.TryParse(entry.Id.AsSpan(6), out _))
                throw new InvalidDataException("Некорректная запись приза.");
            if (entry.Quantity is < 0 or > 10000 || entry.Weight is < 1 or > 1000)
                throw new InvalidDataException("Количество: 0–10000, вес шанса: 1–1000.");
            var image = "";
            if (!string.IsNullOrWhiteSpace(entry.Image))
            {
                var source = LocalImage(entry.Image);
                if (source is null)
                {
                    source = entry.Image;
                    if (Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.IsFile) source = uri.LocalPath;
                    if (!File.Exists(source)) throw new FileNotFoundException("Картинка приза не найдена.", source);
                    var ext = Path.GetExtension(source).ToLowerInvariant();
                    if (ext is not (".png" or ".jpg" or ".jpeg" or ".webp") ||
                        new FileInfo(source).Length > 5 * 1024 * 1024)
                        throw new InvalidDataException("Картинка должна быть PNG, JPG или WebP до 5 МБ.");
                    var destination = Path.Combine(ImageFolder, entry.Id + ext);
                    File.Copy(source, destination, true);
                    source = destination;
                }
                image = new Uri(source).AbsoluteUri;
            }
            prepared.Add(new Prize { Id = entry.Id, Name = name, Image = image,
                Quantity = entry.Quantity, Weight = entry.Weight });
        }
        return prepared;
    }

    public static async Task<List<Prize>> SaveAsync(IReadOnlyList<Prize> entries)
    {
        var prepared = Prepare(entries);
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        var temp = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var output = File.Create(temp)) await JsonSerializer.SerializeAsync(output, prepared);
            File.Move(temp, FilePath, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
        return prepared;
    }

    public static async Task SaveCatalogAsync(PrizeListCatalog catalog)
    {
        if (catalog.Lists.Count > 100) throw new InvalidDataException("Можно сохранить не больше 100 списков призов.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var profile in catalog.Lists)
        {
            profile.Name = profile.Name.Trim();
            if (profile.Name.Length is < 1 or > 80 || !names.Add(profile.Name) ||
                !profile.Id.StartsWith("prizelist-", StringComparison.Ordinal) ||
                !Guid.TryParse(profile.Id.AsSpan(10), out _))
                throw new InvalidDataException("Названия списков призов должны быть разными и не длиннее 80 символов.");
            profile.Prizes = Prepare(profile.Prizes);
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

    public static Prize Draw(IReadOnlyList<Prize> entries)
    {
        var available = entries.Where(p => p.Quantity > 0 && p.Weight > 0).ToArray();
        var total = available.Sum(p => p.Weight);
        if (total <= 0) throw new InvalidOperationException("Доступные призы закончились.");
        var ticket = RandomNumberGenerator.GetInt32(total);
        foreach (var prize in available)
        {
            if (ticket < prize.Weight) return prize;
            ticket -= prize.Weight;
        }
        throw new InvalidOperationException("Не удалось выбрать приз.");
    }
}
