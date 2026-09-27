using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace BonRaffle;

public sealed class Member
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Username { get; set; } = "";
    public string Avatar { get; set; } = "";
}
public sealed class WinnerHistory
{
    public string ListFingerprint { get; set; } = "";
    public List<string> Ids { get; set; } = [];
}
public static class RaffleData
{
    public static string DirectoryPath { get; set; } = "";
    public static string Fingerprint(IEnumerable<Member> members) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
            JsonSerializer.Serialize(members.Select(m => m.Id))))).ToLowerInvariant();
    public static Task SaveMembersAsync(List<Member> members) => Save("members.json", members);
    public static Task SaveWinnerHistoryAsync(WinnerHistory history) => Save("winners.json", history);
    public static Task<List<Member>> LoadMembersAsync() => Load("members.json", new List<Member>());
    public static Task<WinnerHistory> LoadWinnerHistoryAsync() => Load("winners.json", new WinnerHistory());
    private static async Task Save<T>(string name, T value)
    {
        Directory.CreateDirectory(DirectoryPath);
        await File.WriteAllTextAsync(Path.Combine(DirectoryPath, name), JsonSerializer.Serialize(value));
    }
    private static async Task<T> Load<T>(string name, T fallback)
    {
        var path = Path.Combine(DirectoryPath, name);
        return File.Exists(path) ? JsonSerializer.Deserialize<T>(await File.ReadAllTextAsync(path)) ?? fallback : fallback;
    }
}
internal static class Program
{
    private static async Task Main()
    {
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "manual-smoke-data"));
        var demoRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "demo-smoke-data"));
        var legacyRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "legacy-demo-smoke-data"));
        RaffleData.DirectoryPath = root;
        var source = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "../../../../bonraffle_winui/Assets/AvatarPlaceholder.png"));
        try
        {
            var firstId = "list-" + Guid.NewGuid().ToString("N");
            var secondId = "list-" + Guid.NewGuid().ToString("N");
            var memberId = "manual-" + Guid.NewGuid().ToString("N");
            var catalog = new ManualListCatalog { Lists = [
                new ManualListProfile { Id = firstId, Name = "Мероприятие", Members = [
                    new Member { Id = memberId, Name = "Вася Петров", Avatar = source }] },
                new ManualListProfile { Id = secondId, Name = "Другое", Members = [
                    new Member { Id = "manual-" + Guid.NewGuid().ToString("N"), Name = "Кира" }] }
            ]};
            await ManualRoster.SaveCatalogAsync(catalog);
            if (Directory.GetFiles(root, "*.csv", SearchOption.AllDirectories).Length != 0)
                throw new Exception("Manual list unexpectedly exported a CSV.");
            var loaded = await ManualRoster.LoadCatalogAsync();
            if (loaded.Lists.Count != 2 || ManualRoster.LocalPhoto(loaded.Lists[0].Members[0].Avatar) is null)
                throw new Exception("Named lists or local image failed to persist.");
            await ManualRoster.ActivateAsync(loaded, firstId);
            await ManualRoster.RecordWinnerAsync(loaded.Lists[0].Members, memberId);
            loaded = await ManualRoster.LoadCatalogAsync();
            if (!loaded.Lists[0].WinnerIds.Contains(memberId)) throw new Exception("Winner history was lost.");
            await ManualRoster.ActivateAsync(loaded, secondId);
            loaded = await ManualRoster.LoadCatalogAsync();
            if (loaded.Lists[0].WinnerIds.Count != 1 || loaded.ActiveId != secondId)
                throw new Exception("Switching lists lost their separate state.");
            Console.WriteLine("Named manual lists, images, switch, history, no CSV: OK");
            var prizeId = "prize-" + Guid.NewGuid().ToString("N");
            var prizes = new PrizeListCatalog { Lists = [
                new PrizeListProfile { Id = "prizelist-" + Guid.NewGuid().ToString("N"), Name = "Подарки", Prizes = [
                    new Prize { Id = prizeId, Name = "Сертификат", Image = source, Quantity = 2, Weight = 7 },
                    new Prize { Id = "prize-" + Guid.NewGuid().ToString("N"), Name = "Исчерпан", Quantity = 0, Weight = 99 }] },
                new PrizeListProfile { Id = "prizelist-" + Guid.NewGuid().ToString("N"), Name = "Ещё", Prizes = [] }
            ]};
            prizes.ActiveId = prizes.Lists[0].Id;
            await PrizeStore.SaveCatalogAsync(prizes);
            var savedPrizes = await PrizeStore.LoadCatalogAsync();
            if (savedPrizes.Lists.Count != 2 || PrizeStore.LocalImage(savedPrizes.Lists[0].Prizes[0].Image) is null)
                throw new Exception("Prize lists or image failed to persist.");
            for (var i = 0; i < 100; i++)
                if (PrizeStore.Draw(savedPrizes.Lists[0].Prizes).Id != prizeId)
                    throw new Exception("Exhausted prize was selected.");
            var weighted = new[] {
                new Prize { Id = prizeId, Name = "Частый", Quantity = 1, Weight = 7 },
                new Prize { Id = "prize-" + Guid.NewGuid().ToString("N"), Name = "Редкий", Quantity = 1, Weight = 3 }
            };
            var frequent = Enumerable.Range(0, 10000).Count(_ => PrizeStore.Draw(weighted).Id == prizeId);
            if (frequent is < 6300 or > 7700) throw new Exception($"Weighted odds: {frequent}/10000");
            savedPrizes.Lists[0].Prizes[0].Quantity = 1;
            await PrizeStore.SaveCatalogAsync(savedPrizes);
            if ((await PrizeStore.LoadCatalogAsync()).Lists[0].Prizes[0].Quantity != 1)
                throw new Exception("Prize quantity did not persist.");
            Console.WriteLine("Named prize lists, images, availability, odds, quantity: OK");

            var existingManualActive = (await ManualRoster.LoadCatalogAsync()).ActiveId;
            var existingPrizeActive = (await PrizeStore.LoadCatalogAsync()).ActiveId;
            await DemoData.SeedIfNeededAsync();
            var upgradedManual = await ManualRoster.LoadCatalogAsync();
            var upgradedPrizes = await PrizeStore.LoadCatalogAsync();
            if (upgradedManual.Lists.Count != 4 || upgradedPrizes.Lists.Count != 4 ||
                upgradedManual.ActiveId != existingManualActive || upgradedPrizes.ActiveId != existingPrizeActive)
                throw new Exception("Upgrade demos replaced an existing list or selection.");
            Console.WriteLine("Upgrade demos preserve existing lists and selection: OK");

            RaffleData.DirectoryPath = demoRoot;
            await DemoData.SeedIfNeededAsync();
            var demoPeople = await ManualRoster.LoadCatalogAsync();
            var demoPrizes = await PrizeStore.LoadCatalogAsync();
            if (demoPeople.Lists.Count != 2 || demoPeople.Lists[0].Members.Count != 4 ||
                demoPeople.Lists[1].Members.Count != 2 || demoPrizes.Lists.Count != 2 ||
                demoPrizes.Lists[0].Prizes.Count != 2 || demoPrizes.Lists[1].Prizes.Count != 2 ||
                (await RaffleData.LoadMembersAsync()).Count != 4 ||
                ManualRoster.LocalPhoto(demoPeople.Lists[0].Members[0].Avatar) is null ||
                PrizeStore.LocalImage(demoPrizes.Lists[0].Prizes[0].Image) is null)
                throw new Exception("Demo lists were not seeded or activated correctly.");
            File.Delete(Path.Combine(demoRoot, "manual-lists.json"));
            await DemoData.SeedIfNeededAsync();
            if (File.Exists(Path.Combine(demoRoot, "manual-lists.json")))
                throw new Exception("Deleted demo list was recreated.");
            Console.WriteLine("First-run demos and permanent removal: OK");

            RaffleData.DirectoryPath = legacyRoot;
            Directory.CreateDirectory(legacyRoot);
            await File.WriteAllTextAsync(Path.Combine(legacyRoot, "demo-lists.initialized"), "1");
            var legacyMemberListId = "list-" + Guid.NewGuid().ToString("N");
            var legacyPrizeListId = "prizelist-" + Guid.NewGuid().ToString("N");
            var legacyPeople = new ManualListCatalog { Lists = [new ManualListProfile
            {
                Id = legacyMemberListId, Name = "Пример · гости и столики",
                Members = [new Member { Id = "manual-" + Guid.NewGuid().ToString("N"), Name = "Гость" }]
            }], ActiveId = legacyMemberListId };
            await ManualRoster.SaveCatalogAsync(legacyPeople);
            await RaffleData.SaveMembersAsync(legacyPeople.Lists[0].Members);
            var legacyPrizes = new PrizeListCatalog { Lists = [new PrizeListProfile
            {
                Id = legacyPrizeListId, Name = "Пример · подарки",
                Prizes = [new Prize { Id = "prize-" + Guid.NewGuid().ToString("N"), Name = "Подарок", Quantity = 1, Weight = 1 }]
            }], ActiveId = legacyPrizeListId };
            await PrizeStore.SaveCatalogAsync(legacyPrizes);
            await DemoData.SeedIfNeededAsync();
            var migratedPeople = await ManualRoster.LoadCatalogAsync();
            var migratedPrizes = await PrizeStore.LoadCatalogAsync();
            if (!migratedPeople.Lists.Any(p => p.Name == "Пример · участники") ||
                !migratedPeople.Lists.Any(p => p.Name == "Пример · столики") ||
                !migratedPrizes.Lists.Any(p => p.Name == "Пример · для дома") ||
                migratedPrizes.Lists.Count(p => p.Name == "Пример · подарки") != 1 ||
                migratedPeople.ActiveId != legacyMemberListId || migratedPrizes.ActiveId != legacyPrizeListId)
                throw new Exception("Legacy demo marker prevented new examples or changed the active list.");
            migratedPeople.Lists.RemoveAll(p => p.Name == "Пример · столики");
            await ManualRoster.SaveCatalogAsync(migratedPeople);
            await DemoData.SeedIfNeededAsync();
            if ((await ManualRoster.LoadCatalogAsync()).Lists.Any(p => p.Name == "Пример · столики"))
                throw new Exception("A deleted v2 example was recreated.");
            Console.WriteLine("Legacy marker adds missing examples once and keeps active lists: OK");
        }
        finally
        {
            var allowed = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (root.StartsWith(allowed, StringComparison.OrdinalIgnoreCase) && Directory.Exists(root))
                Directory.Delete(root, recursive: true);
            if (demoRoot.StartsWith(allowed, StringComparison.OrdinalIgnoreCase) && Directory.Exists(demoRoot))
                Directory.Delete(demoRoot, recursive: true);
            if (legacyRoot.StartsWith(allowed, StringComparison.OrdinalIgnoreCase) && Directory.Exists(legacyRoot))
                Directory.Delete(legacyRoot, recursive: true);
        }
    }
}
