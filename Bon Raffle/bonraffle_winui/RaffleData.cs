using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.VisualBasic.FileIO;

namespace BonRaffle;

public sealed class Member
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "?";
    [JsonPropertyName("un")] public string Username { get; set; } = "";
    [JsonPropertyName("av")] public string Avatar { get; set; } = "";
}

public sealed class RaffleSettings
{
    [JsonPropertyName("fullscreen")] public bool Fullscreen { get; set; } = true;
    [JsonPropertyName("launch_preference_configured")] public bool LaunchPreferenceConfigured { get; set; }
    [JsonPropertyName("spin_seconds")] public int SpinSeconds { get; set; } = 20;
    [JsonPropertyName("background_dim")] public int BackgroundDim { get; set; } = 55;
    [JsonPropertyName("background_format")] public string? BackgroundFormat { get; set; }
    [JsonPropertyName("show_avatars")] public bool ShowAvatars { get; set; } = true;
    [JsonPropertyName("reduce_effects")] public bool ReduceEffects { get; set; }
    [JsonPropertyName("winner_effect")] public string WinnerEffect { get; set; } = "balloons";
    [JsonPropertyName("raffle_mode")] public string RaffleMode { get; set; } = "participants";
    [JsonPropertyName("idle_speed_pct")] public int IdleSpeedPercent { get; set; } = 100;
    [JsonPropertyName("spin_speed_pct")] public int SpinSpeedPercent { get; set; } = 100;
    [JsonPropertyName("animation_fps")] public int AnimationFps { get; set; }
    [JsonPropertyName("use_background_photo")] public bool UseBackgroundPhoto { get; set; } = true;
    [JsonPropertyName("confirm_replace")] public bool ConfirmReplace { get; set; }
    [JsonPropertyName("home_card_color")] public string HomeCardColor { get; set; } = "#000000";
    [JsonPropertyName("home_card_opacity")] public double HomeCardOpacity { get; set; } = 0.60;
    [JsonPropertyName("drum_color")] public string DrumColor { get; set; } = "#000000";
    [JsonPropertyName("drum_opacity")] public double DrumOpacity { get; set; } = 0.60;
    [JsonPropertyName("selection_color")] public string SelectionColor { get; set; } = "#3A6A96";
    [JsonPropertyName("selection_color_version")] public int SelectionColorVersion { get; set; }
    [JsonPropertyName("winner_card_color")] public string WinnerCardColor { get; set; } = "#D2691E";
    [JsonPropertyName("winner_card_border_color")] public string WinnerCardBorderColor { get; set; } = "#E9B965";
    [JsonPropertyName("winner_card_color_version")] public int WinnerCardColorVersion { get; set; }
    [JsonPropertyName("primary_button_color")] public string PrimaryButtonColor { get; set; } = "#D2691E";
    [JsonPropertyName("primary_button_color_version")] public int PrimaryButtonColorVersion { get; set; }
    [JsonPropertyName("show_remaining_header")] public bool ShowRemainingHeader { get; set; } = true;
    [JsonPropertyName("show_winner_position")] public bool ShowWinnerPosition { get; set; }
    [JsonPropertyName("participants_caption")] public string ParticipantsCaption { get; set; } = "ЕЩЁ МОГУТ ВЫИГРАТЬ";
    [JsonPropertyName("prizes_caption")] public string PrizesCaption { get; set; } = "ДОСТУПНЫХ ВИДОВ ПРИЗОВ";
    [JsonPropertyName("show_intro_countdown")] public bool ShowIntroCountdown { get; set; }
    [JsonPropertyName("verifiable_draw")] public bool VerifiableDraw { get; set; }
    [JsonPropertyName("countdown_seconds")] public int CountdownSeconds { get; set; } = 300;
    [JsonPropertyName("countdown_caption")] public string CountdownCaption { get; set; } = "Конкурс начнётся через";
    [JsonPropertyName("countdown_ring_color")] public string CountdownRingColor { get; set; } = "#D2691E";
    [JsonPropertyName("max_chat_id")] public string MaxChatId { get; set; } = "";
    [JsonPropertyName("max_api_host")] public string MaxApiHost { get; set; } = "platform-api.max.ru";

    public void Validate()
    {
        if (SpinSeconds is not (8 or 12 or 20)) SpinSeconds = 20;
        BackgroundDim = Math.Clamp(BackgroundDim, 30, 85);
        IdleSpeedPercent = Math.Clamp(IdleSpeedPercent, 0, 200);
        SpinSpeedPercent = Math.Clamp(SpinSpeedPercent, 50, 200);
        if (AnimationFps is not (0 or 30 or 60 or 120 or 144)) AnimationFps = 0;
        if (WinnerEffect is not ("balloons" or "stars" or "sparks" or "random")) WinnerEffect = "balloons";
        if (string.IsNullOrWhiteSpace(MaxApiHost)) MaxApiHost = "platform-api.max.ru";
        HomeCardOpacity = Math.Clamp(HomeCardOpacity, 0, 1);
        DrumOpacity = Math.Clamp(DrumOpacity, 0, 1);
        if (!ValidColor(HomeCardColor)) HomeCardColor = "#000000";
        if (!ValidColor(DrumColor)) DrumColor = "#000000";
        if (SelectionColorVersion == 0)
        {
            if (string.Equals(SelectionColor, "#D36A1C", StringComparison.OrdinalIgnoreCase))
                SelectionColor = "#3A6A96";
            SelectionColorVersion = 1;
        }
        if (!ValidColor(SelectionColor)) SelectionColor = "#3A6A96";
        if (WinnerCardColorVersion == 0)
        {
            if (string.Equals(WinnerCardColor, "#4B250E", StringComparison.OrdinalIgnoreCase))
                WinnerCardColor = "#D2691E";
            WinnerCardColorVersion = 1;
        }
        if (!ValidColor(WinnerCardColor)) WinnerCardColor = "#D2691E";
        if (!ValidColor(WinnerCardBorderColor)) WinnerCardBorderColor = "#E9B965";
        ParticipantsCaption = NormalizeCaption(ParticipantsCaption, "ЕЩЁ МОГУТ ВЫИГРАТЬ");
        PrizesCaption = NormalizeCaption(PrizesCaption, "ДОСТУПНЫХ ВИДОВ ПРИЗОВ");
        CountdownSeconds = Math.Clamp(CountdownSeconds, 10, 86400);
        CountdownCaption = NormalizeCaption(CountdownCaption, "Конкурс начнётся через");
        if (!ValidColor(CountdownRingColor)) CountdownRingColor = "#D2691E";
        if (PrimaryButtonColorVersion == 0)
        {
            if (string.Equals(PrimaryButtonColor, "#D36A1C", StringComparison.OrdinalIgnoreCase))
                PrimaryButtonColor = "#D2691E";
            PrimaryButtonColorVersion = 1;
        }
        if (!ValidColor(PrimaryButtonColor)) PrimaryButtonColor = "#D2691E";
    }

    private static bool ValidColor(string? value) => value is { Length: 7 } && value[0] == '#'
        && value.AsSpan(1).ToString().All(Uri.IsHexDigit);

    private static string NormalizeCaption(string? value, string fallback)
    {
        var caption = value?.Trim();
        return caption is null ? fallback : caption[..Math.Min(caption.Length, 200)];
    }
}

public sealed class WinnerHistory
{
    [JsonPropertyName("listFingerprint")] public string ListFingerprint { get; set; } = "";
    [JsonPropertyName("ids")] public List<string> Ids { get; set; } = [];
}

public static class RaffleData
{
    private static readonly SemaphoreSlim SettingsSaveGate = new(1, 1);
    public static bool IsIsolatedPreview => File.Exists(Path.Combine(AppContext.BaseDirectory, "preview-isolated.marker"));
    public static string DirectoryPath => Environment.GetEnvironmentVariable("MAX_RAFFLE_DATA_DIR")
        ?? Environment.GetEnvironmentVariable("SOFRINO_RAFFLE_DATA_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            IsIsolatedPreview ? "BonRaffle-Max-Preview" : "Settings");
    public static string BackgroundPath => Path.Combine(DirectoryPath, "background.custom");
    public static string LogoPath => Path.Combine(DirectoryPath, "logo.custom");
    public static string AvatarPlaceholderPath => Path.Combine(DirectoryPath, "avatar-placeholder.custom");

    public static void MigrateLegacyData()
    {
        if (IsIsolatedPreview || Environment.GetEnvironmentVariable("MAX_RAFFLE_DATA_DIR") is not null
            || Environment.GetEnvironmentVariable("SOFRINO_RAFFLE_DATA_DIR") is not null) return;
        var old = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SofrinoRaffle");
        MigrateLegacyDataFrom(old, DirectoryPath);
    }

    internal static void MigrateLegacyDataFrom(string old, string destinationDirectory)
    {
        if (Directory.Exists(destinationDirectory) || !Directory.Exists(old)) return;
        Directory.CreateDirectory(destinationDirectory);
        foreach (var name in new[] { "members.json", "settings.json", "winners.json", "background.custom", "logo.custom", "avatar-placeholder.custom" })
        {
            var source = Path.Combine(old, name);
            var destination = Path.Combine(destinationDirectory, name);
            if (File.Exists(source) && !File.Exists(destination)) File.Copy(source, destination);
        }
    }

    public static string Fingerprint(IEnumerable<Member> members)
    {
        var json = JsonSerializer.Serialize(members.Select(m => m.Id));
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
    }

    public static async Task<WinnerHistory> LoadWinnerHistoryAsync()
    {
        try
        {
            await using var file = File.OpenRead(Path.Combine(DirectoryPath, "winners.json"));
            return await JsonSerializer.DeserializeAsync<WinnerHistory>(file) ?? new();
        }
        catch (FileNotFoundException) { return new(); }
        catch (JsonException) { return new(); }
    }

    public static Task SaveWinnerHistoryAsync(WinnerHistory history) => WriteJsonAsync("winners.json", history);

    public static async Task<List<Member>> LoadMembersAsync()
    {
        try
        {
            await using var file = File.OpenRead(Path.Combine(DirectoryPath, "members.json"));
            return await JsonSerializer.DeserializeAsync<List<Member>>(file) ?? [];
        }
        catch (FileNotFoundException) { return []; }
        catch (JsonException) { return []; }
    }

    public static async Task<RaffleSettings> LoadSettingsAsync()
    {
        try
        {
            await using var file = File.OpenRead(Path.Combine(DirectoryPath, "settings.json"));
            var result = await JsonSerializer.DeserializeAsync<RaffleSettings>(file) ?? new();
            if (!result.LaunchPreferenceConfigured)
            {
                result.Fullscreen = true;
                result.LaunchPreferenceConfigured = true;
            }
            result.Validate();
            return result;
        }
        catch (FileNotFoundException) { return new(); }
        catch (JsonException) { return new(); }
    }

    public static Task SaveMembersAsync(List<Member> members) => WriteJsonAsync("members.json", members);
    public static async Task SaveSettingsAsync(RaffleSettings settings)
    {
        await SettingsSaveGate.WaitAsync();
        try { await WriteJsonAsync("settings.json", settings); }
        finally { SettingsSaveGate.Release(); }
    }

    private static async Task WriteJsonAsync<T>(string name, T value)
    {
        Directory.CreateDirectory(DirectoryPath);
        var target = Path.Combine(DirectoryPath, name);
        var temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var file = File.Create(temp))
                await JsonSerializer.SerializeAsync(file, value);
            File.Move(temp, target, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    public static List<Member> Import(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) throw new FileNotFoundException("Файл не найден.", path);
        if (info.Length > 25 * 1024 * 1024) throw new InvalidDataException("Файл больше 25 МБ.");
        var extension = info.Extension.ToLowerInvariant();
        if (extension != ".csv") throw new InvalidDataException("Выберите CSV.");
        var members = ImportCsv(path);
        if (members.Count == 0) throw new InvalidDataException("Не найдены участники со столбцом user_id.");
        return members;
    }

    private static List<Member> ImportCsv(string path)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        try { return ReadCsv(path, new UTF8Encoding(false, true)); }
        catch (DecoderFallbackException) { return ReadCsv(path, Encoding.GetEncoding(1251)); }
    }

    private static List<Member> ReadCsv(string path, Encoding encoding)
    {
        using var parser = new TextFieldParser(path, encoding, true);
        parser.SetDelimiters(",");
        parser.HasFieldsEnclosedInQuotes = true;
        var headers = parser.ReadFields() ?? [];
        var result = new List<Member>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var count = 0;
        while (!parser.EndOfData)
        {
            if (++count > 100_000) throw new InvalidDataException("В файле больше 100 000 строк.");
            AddRow(result, seen, headers, parser.ReadFields() ?? []);
        }
        return result;
    }

    private static void AddRow(List<Member> result, HashSet<string> seen, string[] headers, string[] values)
    {
        string Get(params string[] names)
        {
            for (var i = 0; i < headers.Length && i < values.Length; i++)
                if (names.Contains(headers[i].Trim('\uFEFF', ' '), StringComparer.Ordinal)) return values[i]?.Trim() ?? "";
            return "";
        }
        var id = Get("user_id");
        if (id.Length == 0 || !seen.Add(id)) return;
        result.Add(new Member
        {
            Id = id,
            Name = Get("name", "Имя", "имя") is { Length: > 0 } name ? name : "?",
            Username = Get("username", "Username", "юзернейм"),
            Avatar = Get("avatar_url", "Аватар", "аватар")
        });
    }
}
