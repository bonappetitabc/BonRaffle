using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace BonRaffle;

public sealed partial class MainPage
{
    private void WinnerPosition_Click(object sender, RoutedEventArgs e)
    {
        if (WinnerPositionButton.Tag is string position)
            WinnerPositionButton.Content = position;
    }

    private async void ClearDrawLog_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if ((await DrawLog.LoadAsync()).Count == 0) return;
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "Очистить историю результатов?",
                Content = "Записи о прошлых победителях будут удалены. Уже выигравшие в текущем списке останутся исключёнными из новых розыгрышей.",
                PrimaryButtonText = "Очистить",
                CloseButtonText = "Отмена",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                await DrawLog.ClearAsync();
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось очистить историю", ex); }
    }

    private async void ExportDrawPdf_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var records = await DrawLog.LoadAsync();
            if (records.Count == 0)
            {
                await new ContentDialog
                {
                    XamlRoot = XamlRoot,
                    Title = "Протокол пока пуст",
                    Content = "Проведите хотя бы один розыгрыш, затем сохраните протокол.",
                    CloseButtonText = "Закрыть"
                }.ShowAsync();
                return;
            }
            var picker = new FileSavePicker { SuggestedFileName = "Bon-Raffle-results" };
            picker.FileTypeChoices.Add("PDF", [".pdf"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker,
                WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance));
            var file = await picker.PickSaveFileAsync();
            if (file is null) return;
            DrawPdf.Save(file.Path, records);
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось экспортировать протокол", ex); }
    }
}
