using System.Text;
using BonRaffle;

if (args.Length > 0)
{
    var imported = RaffleData.Import(args[0]);
    Console.WriteLine($"Imported: {imported.Count:N0} participants");
    return;
}

var root = Path.Combine(Path.GetTempPath(), "BonRaffleWinUiTest-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
Environment.SetEnvironmentVariable("MAX_RAFFLE_DATA_DIR", root);
try
{
    var csv = Path.Combine(root, "large.csv");
    await using (var file = File.Create(csv))
    await using (var writer = new StreamWriter(file, new UTF8Encoding(false)))
    {
        await writer.WriteLineAsync("user_id,name,username,avatar_url");
        for (var i = 1; i <= 11237; i++) await writer.WriteLineAsync($"{i},Участник {i},user{i},");
        await writer.WriteLineAsync("1,Дубликат,,");
    }
    var members = RaffleData.Import(csv);
    Check(members.Count == 11237, "CSV count/deduplication");
    Check(members[0].Avatar == "", "Missing avatar");
    await RaffleData.SaveMembersAsync(members);
    Check((await RaffleData.LoadMembersAsync()).Count == 11237, "Persist members");

    var unsupported = Path.Combine(root, "members.xlsx");
    await File.WriteAllTextAsync(unsupported, "not a CSV file");
    try { RaffleData.Import(unsupported); throw new Exception("FAIL: XLSX must be rejected"); }
    catch (InvalidDataException ex) when (ex.Message.Contains("CSV")) { }
    var settings = new RaffleSettings { SpinSeconds = 12, Fullscreen = true, IdleSpeedPercent = 80,
        AnimationFps = 120, ConfirmReplace = true, UseBackgroundPhoto = false,
        WinnerCardBorderColor = "#123ABC", ParticipantsCaption = "Сегодня разыгрываем места",
        PrizesCaption = "Призы в наличии", ShowCountdown = true,
        CountdownSeconds = 600, CountdownCaption = "Начало через", CountdownRingColor = "#AABBCC" };
    await RaffleData.SaveSettingsAsync(settings);
    var loadedSettings = await RaffleData.LoadSettingsAsync();
    Check(loadedSettings.SpinSeconds == 12 && loadedSettings.Fullscreen && loadedSettings.AnimationFps == 120
        && loadedSettings.ConfirmReplace && !loadedSettings.UseBackgroundPhoto
        && loadedSettings.WinnerCardBorderColor == "#123ABC"
        && loadedSettings.ParticipantsCaption == "Сегодня разыгрываем места"
        && loadedSettings.PrizesCaption == "Призы в наличии"
        && loadedSettings.ShowCountdown && loadedSettings.CountdownSeconds == 600
        && loadedSettings.CountdownCaption == "Начало через"
        && loadedSettings.CountdownRingColor == "#AABBCC", "Persist settings");
    Check(loadedSettings.LaunchPreferenceConfigured, "Migrate old launch preference");
    loadedSettings.Fullscreen = false;
    await RaffleData.SaveSettingsAsync(loadedSettings);
    Check(!(await RaffleData.LoadSettingsAsync()).Fullscreen, "Respect explicit windowed preference");
    var legacy = Path.Combine(root, "legacy");
    var migrated = Path.Combine(root, "migrated");
    Directory.CreateDirectory(legacy);
    foreach (var name in new[] { "background.custom", "logo.custom", "avatar-placeholder.custom" })
        await File.WriteAllTextAsync(Path.Combine(legacy, name), "old asset");
    RaffleData.MigrateLegacyDataFrom(legacy, migrated);
    foreach (var name in new[] { "background.custom", "logo.custom", "avatar-placeholder.custom" })
    {
        var asset = Path.Combine(migrated, name);
        Check(File.Exists(asset), $"Initial migration of {name}");
        File.Delete(asset);
    }
    RaffleData.MigrateLegacyDataFrom(legacy, migrated);
    foreach (var name in new[] { "background.custom", "logo.custom", "avatar-placeholder.custom" })
        Check(!File.Exists(Path.Combine(migrated, name)), $"Reset of {name} survives relaunch");
    var fingerprint = RaffleData.Fingerprint(members);
    await RaffleData.SaveWinnerHistoryAsync(new WinnerHistory { ListFingerprint = fingerprint, Ids = ["1"] });
    var history = await RaffleData.LoadWinnerHistoryAsync();
    Check(history.ListFingerprint == fingerprint && history.Ids.Count == 1 && history.Ids[0] == "1", "Winner exclusion persistence");
    Check(RaffleData.Fingerprint(members.ToArray()) == fingerprint, "Same ids have same fingerprint");
    Check(RaffleData.Fingerprint(members.Skip(1)) != fingerprint, "New list changes fingerprint");
    Console.WriteLine("PASS: CSV-only import, persistence, winner history, settings, asset resets");
}
finally { Directory.Delete(root, true); }

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception("FAIL: " + message);
}
