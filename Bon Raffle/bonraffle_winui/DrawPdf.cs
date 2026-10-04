using System.Globalization;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace BonRaffle;

public static class DrawPdf
{
    private const double Margin = 46;
    private static readonly XColor Ink = XColor.FromArgb(27, 36, 45);
    private static readonly XColor Accent = XColor.FromArgb(210, 105, 30);

    public static void Save(string path, IReadOnlyList<DrawRecord> records)
    {
        using var document = new PdfDocument();
        document.Info.Title = "Bon Raffle - результаты розыгрышей";
        document.Info.Subject = "История победителей";
        var heading = new XFont("Segoe UI", 21, XFontStyleEx.Bold);
        var body = new XFont("Segoe UI", 11);
        var bold = new XFont("Segoe UI", 12, XFontStyleEx.Bold);
        var small = new XFont("Segoe UI", 9);
        XGraphics? graphics = null;
        double y = 0;
        var pageNumber = 0;

        void BeginPage()
        {
            graphics?.Dispose();
            var page = document.AddPage();
            page.Size = PdfSharp.PageSize.A4;
            graphics = XGraphics.FromPdfPage(page);
            pageNumber++;
            graphics.DrawString("Bon Raffle", heading, new XSolidBrush(Ink),
                new XRect(Margin, 36, page.Width.Point - Margin * 2, 32), XStringFormats.TopLeft);
            graphics.DrawString("Результаты розыгрышей", body, new XSolidBrush(Accent),
                new XRect(Margin, 73, page.Width.Point - Margin * 2, 20), XStringFormats.TopLeft);
            graphics.DrawLine(new XPen(Accent, 1), Margin, 104, page.Width.Point - Margin, 104);
            graphics.DrawString($"Страница {pageNumber}", small, new XSolidBrush(Ink),
                new XRect(Margin, page.Height.Point - 32, page.Width.Point - Margin * 2, 14), XStringFormats.TopRight);
            y = 120;
        }

        BeginPage();
        var width = document.Pages[0].Width.Point - Margin * 2;
        for (var i = 0; i < records.Count; i++)
        {
            var record = records[i];
            var when = DateTimeOffset.TryParse(record.TimestampUtc, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var instant)
                ? instant.ToLocalTime().ToString("dd.MM.yyyy HH:mm:ss", CultureInfo.GetCultureInfo("ru-RU"))
                : record.TimestampUtc;
            var mode = record.Mode == "prizes" ? "Приз" : "Участник";
            var lines = new List<(string Text, XFont Font)>
            {
                ($"{i + 1}. {mode} - {when}", bold),
                ("Победитель: " + record.WinnerName, body),
                ("Список: " + record.ListName, body)
            };
            if (record.ListPosition is > 0)
                lines.Add(($"Позиция в списке: {record.ListPosition:N0}", small));
            lines.Add(($"{(record.Mode == "prizes" ? "Доступных видов призов" : "Участников в розыгрыше")}: {record.EligibleCount:N0}", small));
            var wrapped = lines.SelectMany(line => Wrap(graphics!, line.Text, line.Font, width - 30)
                .Select(value => (value, line.Font))).ToList();
            var height = 20 + wrapped.Sum(line => line.Font == small ? 15 : 19) + 8;
            if (y + height > document.Pages[^1].Height.Point - 52) BeginPage();
            graphics!.DrawRoundedRectangle(new XPen(XColor.FromArgb(225, 228, 232), 0.7),
                new XSolidBrush(XColor.FromArgb(250, 250, 250)), Margin, y, width, height, 8, 8);
            var lineY = y + 12;
            foreach (var (value, font) in wrapped)
            {
                graphics.DrawString(value, font, new XSolidBrush(Ink),
                    new XRect(Margin + 15, lineY, width - 30, font == small ? 15 : 19), XStringFormats.TopLeft);
                lineY += font == small ? 15 : 19;
            }
            y += height + 12;
        }
        graphics?.Dispose();
        document.Save(path);
    }

    private static IEnumerable<string> Wrap(XGraphics graphics, string source, XFont font, double width)
    {
        var words = source.Replace('\r', ' ').Replace('\n', ' ').Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var line = "";
        foreach (var word in words)
        {
            var candidate = line.Length == 0 ? word : line + " " + word;
            if (graphics.MeasureString(candidate, font).Width <= width) { line = candidate; continue; }
            if (line.Length != 0) { yield return line; line = ""; }
            foreach (var character in word)
            {
                var next = line + character;
                if (graphics.MeasureString(next, font).Width > width && line.Length != 0)
                { yield return line; line = ""; }
                line += character;
            }
        }
        if (line.Length != 0) yield return line;
    }
}
