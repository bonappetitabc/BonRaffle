using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace BonRaffle;

internal sealed class AvatarCache
{
    private const int MaxImageBytes = 3 * 1024 * 1024;
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly SemaphoreSlim _slots = new(4);
    private readonly ConcurrentDictionary<string, Task<string?>> _pending = new();
    private readonly ConcurrentDictionary<string, byte> _failed = new();
    private int _generation;
    private int _active;
    private int _batchGeneration;
    private int _batchTotal;
    private int _batchCompleted;
    private int _batchFailed;

    public event Action<int>? ActivityChanged;
    public string Folder => Path.Combine(RaffleData.DirectoryPath, "avatars");
    public int ActiveCount => Volatile.Read(ref _active);
    public int PendingCount => _pending.Count;
    public int BatchTotal => Volatile.Read(ref _batchTotal);
    public int BatchGeneration => Volatile.Read(ref _batchGeneration);
    public int BatchCompleted => Volatile.Read(ref _batchCompleted);
    public int BatchFailed => Volatile.Read(ref _batchFailed);
    public int BatchRemaining => Math.Max(0, BatchTotal - BatchCompleted);

    public void StartBatch(IEnumerable<string> sources)
    {
        _failed.Clear();
        var urls = sources.Where(source => Uri.TryCreate(source, UriKind.Absolute, out var uri)
            && uri.Scheme is "http" or "https").Distinct(StringComparer.Ordinal).ToArray();
        var generation = Interlocked.Increment(ref _batchGeneration);
        Volatile.Write(ref _batchTotal, urls.Length);
        Volatile.Write(ref _batchCompleted, 0);
        Volatile.Write(ref _batchFailed, 0);
        ActivityChanged?.Invoke(ActiveCount);
        var index = -1;
        for (var worker = 0; worker < Math.Min(3, urls.Length); worker++)
            _ = Task.Run(async () =>
            {
                while (generation == Volatile.Read(ref _batchGeneration))
                {
                    var next = Interlocked.Increment(ref index);
                    if (next >= urls.Length) break;
                    var result = await GetAsync(urls[next]);
                    if (generation != Volatile.Read(ref _batchGeneration)) break;
                    if (result is null) Interlocked.Increment(ref _batchFailed);
                    var completed = Interlocked.Increment(ref _batchCompleted);
                    if (completed % 20 == 0 || completed == urls.Length)
                        ActivityChanged?.Invoke(ActiveCount);
                }
            });
    }

    public long SizeBytes
    {
        get
        {
            if (!Directory.Exists(Folder)) return 0;
            try { return Directory.EnumerateFiles(Folder).Sum(path => new FileInfo(path).Length); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return 0; }
        }
    }

    public Task<string?> GetAsync(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            return Task.FromResult<string?>(null);
        var file = Path.Combine(Folder, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(url))) + ".img");
        if (File.Exists(file)) return Task.FromResult<string?>(file);
        if (_failed.ContainsKey(url)) return Task.FromResult<string?>(null);
        var task = _pending.GetOrAdd(url, _ => DownloadAsync(url, uri, file, Volatile.Read(ref _generation)));
        return task;
    }

    private async Task<string?> DownloadAsync(string url, Uri uri, string file, int generation)
    {
        await _slots.WaitAsync();
        Interlocked.Increment(ref _active);
        ActivityChanged?.Invoke(ActiveCount);
        try
        {
            if (File.Exists(file)) return file;
            using var response = await Client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentType?.MediaType?.StartsWith("image/", StringComparison.OrdinalIgnoreCase) != true
                || response.Content.Headers.ContentLength > MaxImageBytes) return null;
            await using var stream = await response.Content.ReadAsStreamAsync();
            await using var buffer = new MemoryStream();
            var chunk = new byte[64 * 1024];
            int count;
            while ((count = await stream.ReadAsync(chunk)) > 0)
            {
                if (buffer.Length + count > MaxImageBytes) return null;
                await buffer.WriteAsync(chunk.AsMemory(0, count));
            }
            if (buffer.Length == 0 || generation != Volatile.Read(ref _generation)) return null;
            Directory.CreateDirectory(Folder);
            var temporary = file + ".tmp";
            try
            {
                await File.WriteAllBytesAsync(temporary, buffer.ToArray());
                if (generation != Volatile.Read(ref _generation)) return null;
                File.Move(temporary, file, true);
                return file;
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException or UnauthorizedAccessException)
        {
            _failed.TryAdd(url, 0);
            return null;
        }
        finally
        {
            _pending.TryRemove(url, out _);
            Interlocked.Decrement(ref _active);
            ActivityChanged?.Invoke(ActiveCount);
            _slots.Release();
        }
    }

    public void Clear()
    {
        Interlocked.Increment(ref _generation);
        Interlocked.Increment(ref _batchGeneration);
        Volatile.Write(ref _batchTotal, 0);
        Volatile.Write(ref _batchCompleted, 0);
        Volatile.Write(ref _batchFailed, 0);
        _failed.Clear();
        if (!Directory.Exists(Folder)) return;
        try
        {
            foreach (var file in Directory.EnumerateFiles(Folder))
            {
                try { File.Delete(file); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
