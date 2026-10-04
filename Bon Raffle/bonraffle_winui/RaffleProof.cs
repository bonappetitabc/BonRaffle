using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace BonRaffle;

public sealed class DrawProof
{
    [JsonPropertyName("snapshot")] public string Snapshot { get; set; } = "";
    [JsonPropertyName("snapshotHash")] public string SnapshotHash { get; set; } = "";
    [JsonPropertyName("commitment")] public string Commitment { get; set; } = "";
    [JsonPropertyName("seedHex")] public string SeedHex { get; set; } = "";
    [JsonPropertyName("audienceCode")] public string AudienceCode { get; set; } = "";
    [JsonPropertyName("ticket")] public int Ticket { get; set; }
}

public sealed class RaffleProof
{
    private const string Format = "BonRaffleProofV1";
    private readonly byte[] _seed;
    public string Snapshot { get; }
    public string SnapshotHash { get; }
    public string Commitment { get; }

    private RaffleProof(string snapshot, byte[] seed)
    {
        if (seed.Length != 32) throw new ArgumentException("Seed must be 32 bytes.", nameof(seed));
        _seed = (byte[])seed.Clone();
        Snapshot = snapshot;
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(snapshot));
        SnapshotHash = Convert.ToHexStringLower(digest);
        Commitment = Convert.ToHexStringLower(SHA256.HashData([.. _seed, .. digest]));
    }

    public static RaffleProof ForParticipants(IReadOnlyList<Member> eligible, byte[]? seed = null) =>
        Create("participants", eligible.Select(member => (member.Id, 1)), seed);

    public static RaffleProof ForPrizes(IReadOnlyList<Prize> entries, byte[]? seed = null) =>
        Create("prizes", entries.Where(prize => prize.Quantity > 0 && prize.Weight > 0)
            .Select(prize => (prize.Id, prize.Weight)), seed);

    private static RaffleProof Create(string mode, IEnumerable<(string Id, int Weight)> candidates, byte[]? seed)
    {
        var rows = candidates.Select(item =>
            Convert.ToBase64String(Encoding.UTF8.GetBytes(item.Id)) + ":" + item.Weight);
        return new RaffleProof(Format + "\n" + mode + "\n" + string.Join("\n", rows),
            seed ?? RandomNumberGenerator.GetBytes(32));
    }

    public int Ticket(string audienceCode, int upperBound)
    {
        if (string.IsNullOrWhiteSpace(audienceCode)) throw new ArgumentException("Введите код зрителя.", nameof(audienceCode));
        if (upperBound <= 0) throw new ArgumentOutOfRangeException(nameof(upperBound));
        var range = 1UL << 32;
        var limit = range - range % (ulong)upperBound;
        for (var counter = 0; ; counter++)
        {
            var message = Encoding.UTF8.GetBytes(SnapshotHash + "\n" + audienceCode + "\n" + counter);
            var hash = HMACSHA256.HashData(_seed, message);
            var value = BinaryPrimitives.ReadUInt32BigEndian(hash);
            if ((ulong)value < limit) return (int)((ulong)value % (ulong)upperBound);
        }
    }

    public DrawProof Reveal(string audienceCode, int ticket) => new()
    {
        Snapshot = Snapshot,
        SnapshotHash = SnapshotHash,
        Commitment = Commitment,
        SeedHex = Convert.ToHexStringLower(_seed),
        AudienceCode = audienceCode,
        Ticket = ticket
    };

    public static bool Verify(DrawRecord record)
    {
        var proof = record.Proof;
        if (proof is null || string.IsNullOrWhiteSpace(proof.AudienceCode)) return false;
        try
        {
            var seed = Convert.FromHexString(proof.SeedHex);
            var draft = new RaffleProof(proof.Snapshot, seed);
            if (draft.SnapshotHash != proof.SnapshotHash || draft.Commitment != proof.Commitment) return false;
            var lines = proof.Snapshot.Split('\n');
            if (lines.Length < 3 || lines[0] != Format || lines[1] != record.Mode) return false;
            var candidates = lines.Skip(2).Select(line =>
            {
                var parts = line.Split(':');
                return (Id: Encoding.UTF8.GetString(Convert.FromBase64String(parts[0])),
                    Weight: int.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture));
            }).ToArray();
            if (candidates.Length == 0 || candidates.Length != record.EligibleCount ||
                candidates.Any(item => item.Weight <= 0) ||
                (record.Mode == "participants" && candidates.Any(item => item.Weight != 1))) return false;
            var total = record.Mode == "prizes" ? candidates.Sum(item => item.Weight) : candidates.Length;
            var ticket = draft.Ticket(proof.AudienceCode, total);
            if (ticket != proof.Ticket) return false;
            var selected = record.Mode == "prizes"
                ? candidates.First(item => (ticket -= item.Weight) < 0).Id
                : candidates[ticket].Id;
            return selected == record.WinnerId;
        }
        catch (Exception ex) when (ex is ArgumentException or FormatException or IndexOutOfRangeException
            or InvalidOperationException or OverflowException) { return false; }
    }
}
