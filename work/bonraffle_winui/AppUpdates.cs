using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace BonRaffle;

public sealed record AppRelease(Version Version, string Notes, Uri Page, string FileName,
    Uri Download, long Size, string Sha256);

// Public GitHub endpoints only. No credentials or participant data are sent.
public sealed class AppUpdateClient(HttpClient http)
{
    public const string Repository = "https://github.com/bonappetitabc/BonRaffle";
    private const long MaxSize = 1024L * 1024 * 1024;

    public async Task<AppRelease?> FindAsync(string platform, Version current, CancellationToken token = default)
    {
        AppRelease? latest = null;
        // GitHub's single /latest endpoint is shared by both platforms.
        for (var page = 1; page <= 10; page++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get,
                $"https://api.github.com/repos/bonappetitabc/BonRaffle/releases?per_page=100&page={page}");
            request.Headers.UserAgent.ParseAdd("BonRaffle/" + current.ToString(3));
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var response = await http.SendAsync(request, token);
            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException("GitHub временно недоступен. Повторите проверку позже.");
            var bytes = await response.Content.ReadAsByteArrayAsync(token);
            if (bytes.Length > 4 * 1024 * 1024) throw new InvalidDataException("Ответ GitHub слишком большой.");
            using var json = JsonDocument.Parse(bytes);
            var releases = json.RootElement;
            if (releases.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Некорректный ответ GitHub.");
            foreach (var item in releases.EnumerateArray())
            {
                var candidate = Parse(item, platform);
                if (candidate is not null && candidate.Version > current &&
                    (latest is null || candidate.Version > latest.Version)) latest = candidate;
            }
            if (releases.GetArrayLength() < 100) break;
            if (page == 10) throw new InvalidDataException("Слишком много выпусков. Откройте страницу GitHub.");
        }
        return latest;
    }

    internal static AppRelease? Parse(JsonElement item, string platform)
    {
        if (platform is not ("windows" or "macos") || item.GetProperty("draft").GetBoolean() ||
            item.GetProperty("prerelease").GetBoolean()) return null;
        var tag = item.GetProperty("tag_name").GetString() ?? "";
        // Keep older platform releases discoverable while accepting one release with both installers.
        var match = Regex.Match(tag, "^(?:" + platform + @"-v|v)([0-9]+\.[0-9]+\.[0-9]+)$");
        if (!match.Success || !Version.TryParse(match.Groups[1].Value, out var version)) return null;
        var name = platform == "windows" ? $"Bon-Raffle-Setup-{version}.exe" : $"BonRaffle-macOS15-plus-{version}.dmg";
        var page = new Uri($"{Repository}/releases/tag/{tag}");
        foreach (var asset in item.GetProperty("assets").EnumerateArray())
        {
            if (asset.GetProperty("name").GetString() != name) continue;
            var expected = $"{Repository}/releases/download/{tag}/{name}";
            if (asset.GetProperty("browser_download_url").GetString() != expected) continue;
            var size = asset.GetProperty("size").GetInt64();
            if (size <= 0 || size > MaxSize) continue;
            var digest = asset.TryGetProperty("digest", out var d) ? d.GetString() ?? "" : "";
            // An older GitHub asset may have no digest. Offer its release page instead of running it.
            var hash = Regex.IsMatch(digest, @"^sha256:[a-fA-F0-9]{64}$") ? digest[7..].ToLowerInvariant() : "";
            var notes = item.TryGetProperty("body", out var b) ? b.GetString() ?? "" : "";
            return new(version, notes.Length > 12_000 ? notes[..12_000] : notes, page, name, new(expected), size, hash);
        }
        return null;
    }

    public async Task<string> DownloadAsync(AppRelease release, string directory,
        IProgress<double>? progress, CancellationToken token)
    {
        if (release.Sha256.Length != 64) throw new InvalidDataException("Для этого файла нет контрольной суммы. Откройте страницу выпуска.");
        Directory.CreateDirectory(directory);
        // A unique directory avoids overwriting a user's existing download.
        var folder = Path.Combine(directory, "BonRaffle-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, release.FileName);
        var partial = path + ".part";
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, release.Download);
            request.Headers.UserAgent.ParseAdd("BonRaffle-Updater");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            if (response.RequestMessage?.RequestUri?.Scheme != Uri.UriSchemeHttps)
                throw new InvalidDataException("Для обновления требуется HTTPS.");
            if (response.Content.Headers.ContentLength is long length && length != release.Size)
                throw new InvalidDataException("Размер обновления не совпал с выпуском.");
            await using (var source = await response.Content.ReadAsStreamAsync(token))
            await using (var destination = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[65536];
                long total = 0;
                int count;
                while ((count = await source.ReadAsync(buffer, token)) > 0)
                {
                    total += count;
                    if (total > release.Size) throw new InvalidDataException("Обновление больше ожидаемого размера.");
                    hash.AppendData(buffer, 0, count);
                    await destination.WriteAsync(buffer.AsMemory(0, count), token);
                    progress?.Report((double)total / release.Size);
                }
                var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                if (total != release.Size || digest != release.Sha256)
                    throw new InvalidDataException("Проверка файла не прошла. Скачайте обновление заново.");
            }
            token.ThrowIfCancellationRequested();
            File.Move(partial, path);
            return path;
        }
        catch
        {
            File.Delete(partial);
            if (!Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder);
            throw;
        }
    }

    public static async Task VerifyAsync(string path, AppRelease release)
    {
        await using var file = File.OpenRead(path);
        if (file.Length != release.Size ||
            !Convert.ToHexString(await SHA256.HashDataAsync(file)).Equals(release.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Скачанный файл изменился. Скачайте его заново.");
    }
}
