using System.Net;
using System.Net.Sockets;
using System.Text;

namespace BonRaffle;

internal static class RaffleData
{
    public static string DirectoryPath { get; } = Path.Combine(Path.GetTempPath(), "bonraffle-avatar-cache-test-" + Guid.NewGuid());
}

internal static class Program
{
    private static async Task Main()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var serving = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    using var client = await listener.AcceptTcpClientAsync();
                    var stream = client.GetStream();
                    var request = new byte[2048];
                    await stream.ReadAsync(request);
                    var image = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/B9sAAAAASUVORK5CYII=");
                    var header = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: {image.Length}\r\nConnection: close\r\n\r\n");
                    await stream.WriteAsync(header);
                    await stream.WriteAsync(image);
                }
            }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
        });
        var cache = new AvatarCache();
        cache.StartBatch(Enumerable.Range(0, 8).Select(i => $"http://127.0.0.1:{port}/avatar{i}.png"));
        for (var i = 0; i < 200 && cache.BatchRemaining > 0; i++) await Task.Delay(50);
        if (cache.BatchCompleted != 8 || cache.BatchFailed != 0 || cache.SizeBytes <= 0)
            throw new Exception($"Batch failed: {cache.BatchCompleted}/{cache.BatchTotal}, failed {cache.BatchFailed}, bytes {cache.SizeBytes}");
        cache.Clear();
        if (cache.SizeBytes != 0 || cache.BatchTotal != 0) throw new Exception("Cache clear failed");
        listener.Stop();
        await serving;
        Console.WriteLine("PASS: eight avatars cached, progress reached completion, cache cleared");
    }
}
