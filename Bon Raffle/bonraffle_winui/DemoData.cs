namespace BonRaffle;

internal static class DemoData
{
    private static string Marker => Path.Combine(RaffleData.DirectoryPath, "demo-lists.initialized");
    private static string CurrentMarker => Path.Combine(RaffleData.DirectoryPath, "demo-lists-v2.initialized");
    private static string Asset(string name) => Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", name);
    private static Member Person(string name, string image) => new()
    {
        Id = "manual-" + Guid.NewGuid().ToString("N"), Name = name, Avatar = Asset(image)
    };
    private static Prize Gift(string name, string image, int quantity, int weight) => new()
    {
        Id = "prize-" + Guid.NewGuid().ToString("N"), Name = name, Image = Asset(image),
        Quantity = quantity, Weight = weight
    };

    public static async Task SeedIfNeededAsync()
    {
        if (File.Exists(CurrentMarker)) return;
        Directory.CreateDirectory(RaffleData.DirectoryPath);
        {
            var existingCatalog = await ManualRoster.LoadCatalogAsync();
            var current = await RaffleData.LoadMembersAsync();
            var useDemoNow = current.Count == 0;
            string? firstDemoId = null;
            if (!existingCatalog.Lists.Any(p => p.Name.Equals("Пример · участники", StringComparison.OrdinalIgnoreCase)))
            {
            var people = new ManualListProfile
            {
                Id = "list-" + Guid.NewGuid().ToString("N"),
                Name = "Пример · участники",
                Members = [
                    Person("Алина", "demo-person-1.png"),
                    Person("Кирилл", "demo-person-2.png"),
                    Person("Марина", "demo-person-3.png"),
                    Person("Денис", "demo-person-4.png")
                ]
            };
            existingCatalog.Lists.Add(people);
            firstDemoId = people.Id;
            }
            if (!existingCatalog.Lists.Any(p => p.Name.Equals("Пример · столики", StringComparison.OrdinalIgnoreCase)))
            {
            var tables = new ManualListProfile
            {
                Id = "list-" + Guid.NewGuid().ToString("N"),
                Name = "Пример · столики",
                Members = [
                    Person("Стол № 12", "demo-table.png"),
                    Person("Стол № 15", "demo-table.png")
                ]
            };
            existingCatalog.Lists.Add(tables);
            firstDemoId ??= tables.Id;
            }
            if (useDemoNow && firstDemoId is not null) existingCatalog.ActiveId = firstDemoId;
            await ManualRoster.SaveCatalogAsync(existingCatalog);
            if (useDemoNow && firstDemoId is not null) await ManualRoster.ActivateAsync(existingCatalog, firstDemoId);
        }
        {
            var existingCatalog = await PrizeStore.LoadCatalogAsync();
            string? firstDemoId = null;
            if (!existingCatalog.Lists.Any(p => p.Name.Equals("Пример · подарки", StringComparison.OrdinalIgnoreCase)))
            {
            var gifts = new PrizeListProfile
            {
                Id = "prizelist-" + Guid.NewGuid().ToString("N"),
                Name = "Пример · подарки",
                Prizes = [
                    Gift("Подарочная карта", "demo-prize-card.png", 2, 3),
                    Gift("Наушники", "demo-prize-headphones.png", 1, 1)
                ]
            };
            existingCatalog.Lists.Add(gifts);
            firstDemoId = gifts.Id;
            }
            if (!existingCatalog.Lists.Any(p => p.Name.Equals("Пример · для дома", StringComparison.OrdinalIgnoreCase)))
            {
            var home = new PrizeListProfile
            {
                Id = "prizelist-" + Guid.NewGuid().ToString("N"),
                Name = "Пример · для дома",
                Prizes = [
                    Gift("Настольная лампа", "demo-prize-lamp.png", 1, 2),
                    Gift("Термокружка", "demo-prize-cup.png", 3, 4)
                ]
            };
            existingCatalog.Lists.Add(home);
            firstDemoId ??= home.Id;
            }
            existingCatalog.ActiveId ??= firstDemoId;
            await PrizeStore.SaveCatalogAsync(existingCatalog);
        }
        await File.WriteAllTextAsync(Marker, "1");
        await File.WriteAllTextAsync(CurrentMarker, "2");
    }

    private static string UniqueName(string proposed, IEnumerable<string> existing)
    {
        var names = existing.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!names.Contains(proposed)) return proposed;
        var number = 2;
        while (names.Contains($"{proposed} ({number})")) number++;
        return $"{proposed} ({number})";
    }
}
