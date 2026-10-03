using System.Net;
using System.Net.Http;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using Windows.Security.Credentials;

namespace BonRaffle;

internal static class MaxConnection
{
    private static string Resource => RaffleData.IsIsolatedPreview
        ? "Bon Raffle MAX preview bot token" : "Bon Raffle MAX bot token";
    private const string Account = "bot";

    public static string? LoadToken()
    {
        try
        {
            var credential = new PasswordVault().Retrieve(Resource, Account);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or KeyNotFoundException)
        {
            return null;
        }
    }

    public static void SaveToken(string token)
    {
        var vault = new PasswordVault();
        try
        {
            foreach (var existing in vault.FindAllByResource(Resource))
                vault.Remove(existing);
        }
        catch (System.Runtime.InteropServices.COMException) { }
        vault.Add(new PasswordCredential(Resource, Account, token));
    }

    public static void DeleteToken()
    {
        var vault = new PasswordVault();
        try
        {
            foreach (var existing in vault.FindAllByResource(Resource))
                vault.Remove(existing);
        }
        catch (System.Runtime.InteropServices.COMException) { }
    }
}

internal static class MaxRosterExporter
{
    private static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false })
        { Timeout = TimeSpan.FromSeconds(30) };

    private static bool IsCertificateError(HttpRequestException error) =>
        error.InnerException is AuthenticationException ||
        error.Message.Contains("certificate", StringComparison.OrdinalIgnoreCase) ||
        error.Message.Contains("SSL", StringComparison.OrdinalIgnoreCase);

    public static string NormalizeHost(string? value)
    {
        var host = (value ?? "").Trim().ToLowerInvariant();
        if (host.StartsWith("https://", StringComparison.Ordinal)) host = host[8..];
        host = host.TrimEnd('/');
        if (host.Length == 0) return "platform-api.max.ru";
        if (!host.EndsWith(".max.ru", StringComparison.Ordinal) ||
            host.Split('.').Any(label => label.Length is < 1 or > 63 ||
                label[0] == '-' || label[^1] == '-' ||
                label.Any(c => !(char.IsAsciiLetterOrDigit(c) || c == '-'))))
            throw new InvalidDataException("Укажите HTTPS-адрес API на домене max.ru без пути, например platform-api2.max.ru.");
        return host;
    }

    public static async Task<(string Path, int Count)> ExportAsync(string token, long chatId, string apiHost,
        IProgress<int>? progress = null, CancellationToken cancellationToken = default)
    {
        var members = new List<(string Id, string Name, string Username, string Avatar)>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var seenMarkers = new HashSet<string>(StringComparer.Ordinal);
        var host = NormalizeHost(apiHost);
        string? marker = null;
        do
        {
            var url = $"https://{host}/chats/{chatId}/members?count=100";
            if (marker is not null) url += "&marker=" + Uri.EscapeDataString(marker);
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("Authorization", token);
            HttpResponseMessage response;
            try { response = await Client.SendAsync(request, cancellationToken); }
            catch (HttpRequestException ex) when (IsCertificateError(ex) &&
                                                   host == "platform-api2.max.ru")
            {
                var fallbackUrl = url.Replace("platform-api2.max.ru", "platform-api.max.ru", StringComparison.Ordinal);
                using var fallback = new HttpRequestMessage(HttpMethod.Get, fallbackUrl);
                fallback.Headers.TryAddWithoutValidation("Authorization", token);
                try { response = await Client.SendAsync(fallback, cancellationToken); }
                catch (HttpRequestException retry) when (IsCertificateError(retry))
                {
                    throw new InvalidOperationException("Не удалось безопасно подключиться к MAX. Проверьте адрес API в настройках.", retry);
                }
            }
            catch (HttpRequestException ex) when (IsCertificateError(ex))
            {
                throw new InvalidOperationException("Не удалось безопасно подключиться к MAX. Проверьте адрес API в настройках.", ex);
            }
            using (response)
            {
            if (response.StatusCode == HttpStatusCode.Unauthorized)
                throw new InvalidOperationException("Токен MAX недействителен. Проверьте его в настройках.");
            if (response.StatusCode == HttpStatusCode.Forbidden)
                throw new InvalidOperationException("Бот должен быть администратором этого канала или чата MAX.");
            if (response.StatusCode == HttpStatusCode.NotFound)
                throw new InvalidOperationException("Канал или чат MAX с таким chat_id не найден.");
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"MAX вернул ошибку HTTP {(int)response.StatusCode}. Попробуйте позже.");

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            var root = document.RootElement;
            if (!root.TryGetProperty("members", out var page) || page.ValueKind != JsonValueKind.Array)
                throw new InvalidDataException("MAX вернул ответ без списка участников.");
            foreach (var member in page.EnumerateArray())
            {
                if (member.TryGetProperty("is_bot", out var bot) && bot.ValueKind == JsonValueKind.True) continue;
                var id = Value(member, "user_id");
                if (string.IsNullOrWhiteSpace(id) || !ids.Add(id)) continue;
                var name = string.Join(" ", new[] { Value(member, "first_name"), Value(member, "last_name") }
                    .Where(s => !string.IsNullOrWhiteSpace(s))).Trim();
                if (name.Length == 0) name = Value(member, "name");
                if (name.Length == 0) name = Value(member, "username");
                if (name.Length == 0) name = id;
                members.Add((id, name, Value(member, "username"), Value(member, "avatar_url")));
            }
            progress?.Report(members.Count);
            if (members.Count > 100_000) throw new InvalidDataException("В списке больше 100 000 участников — предел импорта Bon Raffle.");
            marker = root.TryGetProperty("marker", out var next) && next.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)
                ? next.ToString() : null;
            if (string.IsNullOrEmpty(marker)) marker = null;
            if (marker is not null && !seenMarkers.Add(marker))
                throw new InvalidDataException("MAX повторил страницу списка участников.");
            }
        } while (marker is not null);

        if (members.Count == 0) throw new InvalidDataException("MAX не вернул участников для выгрузки.");
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        Directory.CreateDirectory(downloads);
        var path = Path.Combine(downloads, $"BonRaffle-MAX-members-{DateTime.Now:yyyy-MM-dd-HH-mm-ss}.csv");
        var csv = new StringBuilder("user_id,name,username,avatar_url\r\n");
        foreach (var member in members)
            csv.Append(Csv(member.Id)).Append(',').Append(Csv(member.Name)).Append(',')
               .Append(Csv(member.Username)).Append(',').Append(Csv(member.Avatar)).Append("\r\n");
        await File.WriteAllTextAsync(path, csv.ToString(), new UTF8Encoding(true), cancellationToken);
        return (path, members.Count);
    }

    private static string Value(JsonElement item, string key) =>
        item.TryGetProperty(key, out var value) && value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)
            ? value.ToString().Trim() : "";

    private static string Csv(string value)
    {
        // Prevent a member name from becoming a formula when the CSV is opened in Excel.
        if (value.Length > 0 && "=+-@\t\r".Contains(value[0])) value = "'" + value;
        return '"' + value.Replace("\"", "\"\"") + '"';
    }
}
