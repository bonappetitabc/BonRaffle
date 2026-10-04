using System.Security.Cryptography;

namespace BonRaffle;

// Selection rules are independent of WinUI and can be exercised with a fixed ticket in tests.
public static class RaffleEngine
{
    public static Member[] Remaining(IReadOnlyList<Member> members, IReadOnlySet<string> winnerIds) =>
        members.Where(member => !winnerIds.Contains(member.Id)).ToArray();

    public static Member? DrawParticipant(IReadOnlyList<Member> eligible, Func<int, int>? nextIndex = null)
    {
        if (eligible.Count == 0) return null;
        var index = (nextIndex ?? RandomNumberGenerator.GetInt32)(eligible.Count);
        if ((uint)index >= (uint)eligible.Count) throw new ArgumentOutOfRangeException(nameof(nextIndex));
        return eligible[index];
    }

    public static Prize DrawPrize(IReadOnlyList<Prize> entries, Func<int, int>? nextTicket = null)
    {
        var available = entries.Where(prize => prize.Quantity > 0 && prize.Weight > 0).ToArray();
        var total = available.Sum(prize => prize.Weight);
        if (total <= 0) throw new InvalidOperationException("Доступные призы закончились.");
        var ticket = (nextTicket ?? RandomNumberGenerator.GetInt32)(total);
        if ((uint)ticket >= (uint)total) throw new ArgumentOutOfRangeException(nameof(nextTicket));
        foreach (var prize in available)
        {
            if (ticket < prize.Weight) return prize;
            ticket -= prize.Weight;
        }
        throw new InvalidOperationException("Не удалось выбрать приз.");
    }

    public static double PrizeChance(IReadOnlyList<Prize> entries, Prize prize)
    {
        if (prize.Quantity <= 0 || prize.Weight <= 0) return 0;
        var total = entries.Where(item => item.Quantity > 0 && item.Weight > 0).Sum(item => item.Weight);
        return total > 0 ? (double)prize.Weight / total : 0;
    }
}
