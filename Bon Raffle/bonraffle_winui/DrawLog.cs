using System.Text.Json;
using System.Text.Json.Serialization;

namespace BonRaffle;

public sealed class DrawRecord
{
    [JsonPropertyName("timestampUtc")] public string TimestampUtc { get; set; } = "";
    [JsonPropertyName("mode")] public string Mode { get; set; } = "participants";
    [JsonPropertyName("listName")] public string ListName { get; set; } = "";
    [JsonPropertyName("listFingerprint")] public string ListFingerprint { get; set; } = "";
    [JsonPropertyName("eligibleCount")] public int EligibleCount { get; set; }
    [JsonPropertyName("winnerId")] public string WinnerId { get; set; } = "";
    [JsonPropertyName("winnerName")] public string WinnerName { get; set; } = "";
    [JsonPropertyName("listPosition")] public int? ListPosition { get; set; }
    [JsonPropertyName("chance")] public double Chance { get; set; }
    [JsonPropertyName("proof")] public DrawProof? Proof { get; set; }
}

public static class DrawLog
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static string PathName => Path.Combine(RaffleData.DirectoryPath, "draw-log.json");

    public static async Task<List<DrawRecord>> LoadAsync()
    {
        try
        {
            await using var file = File.OpenRead(PathName);
            return await JsonSerializer.DeserializeAsync<List<DrawRecord>>(file)
                ?? throw new InvalidDataException("Протокол розыгрыша повреждён.");
        }
        catch (FileNotFoundException) { return []; }
    }

    public static async Task AppendAsync(DrawRecord record)
    {
        await Gate.WaitAsync();
        try
        {
            var records = await LoadAsync();
            records.Add(record);
            Directory.CreateDirectory(RaffleData.DirectoryPath);
            var temp = PathName + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                await using (var file = File.Create(temp))
                    await JsonSerializer.SerializeAsync(file, records);
                File.Move(temp, PathName, true);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        finally { Gate.Release(); }
    }

    public static async Task ClearAsync()
    {
        await Gate.WaitAsync();
        try { if (File.Exists(PathName)) File.Delete(PathName); }
        finally { Gate.Release(); }
    }

    public static async Task<string> ExportJsonAsync()
    {
        var records = await LoadAsync();
        return JsonSerializer.Serialize(new
        {
            schema = "bon-raffle-draw-log-v1",
            exportedUtc = DateTimeOffset.UtcNow.ToString("O"),
            draws = records
        }, new JsonSerializerOptions { WriteIndented = true });
    }
}
