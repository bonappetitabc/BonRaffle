using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Pickers;
using Windows.UI;

namespace BonRaffle;

public sealed partial class MainPage
{
    private async void PrizeRaffle_Click(object sender, RoutedEventArgs e)
    {
        if (_spinning) return;
        try
        {
            var catalog = await PrizeStore.LoadCatalogAsync();
            if (catalog.Lists.Count == 0)
                catalog.Lists.Add(new PrizeListProfile { Id = "prizelist-" + Guid.NewGuid().ToString("N"), Name = "Мои призы" });
            var currentId = catalog.Lists.FirstOrDefault(p => p.Id == catalog.ActiveId)?.Id ?? catalog.Lists[0].Id;
            var entries = catalog.Lists.First(p => p.Id == currentId).Prizes.Select(p => new Prize
            { Id = p.Id, Name = p.Name, Image = p.Image, Quantity = p.Quantity, Weight = p.Weight }).ToList();
            var profilePicker = new ComboBox { Header = "Выберите список призов", HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var profile in catalog.Lists)
                profilePicker.Items.Add(new ComboBoxItem { Content = profile.Name, Tag = profile.Id });
            var profileNameBox = new TextBox { Header = "Название списка", Text = catalog.Lists.First(p => p.Id == currentId).Name,
                PlaceholderText = "Например, Призы для праздника" };
            var createProfile = new Button { Content = "Новый список" };
            var deleteProfile = new Button { Content = "Удалить список" };
            var nameBox = new TextBox { Header = "Название приза", PlaceholderText = "Например, сертификат или подарок" };
            var quantityBox = new NumberBox { Header = "Количество", Minimum = 0, Maximum = 10000, Value = 1,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
            var weightBox = new NumberBox { Header = "Вес шанса", Minimum = 1, Maximum = 1000, Value = 1,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
            var preview = new Image { Width = 64, Height = 64, Stretch = Stretch.UniformToFill };
            var previewFallback = new TextBlock { Text = "🎁", FontSize = 40, HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center };
            var imageStatus = new TextBlock { Text = "Без картинки", Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis };
            var message = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
            var list = new ListView { Height = 315, SelectionMode = ListViewSelectionMode.Single };
            var add = new Button { Content = "Добавить приз", Background = new SolidColorBrush(ParseColor("#D2691E")),
                Foreground = new SolidColorBrush(Colors.White) };
            var remove = new Button { Content = "Удалить выбранный", IsEnabled = false };
            var newEntry = new Button { Content = "Новый приз" };
            var chooseImage = new Button { Content = "Выбрать картинку…" };
            var clearImage = new Button { Content = "Без картинки" };
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Мои списки призов",
                PrimaryButtonText = "Сохранить и использовать", CloseButtonText = "Закрыть" };
            var scroll = new ScrollViewer { MaxHeight = 610 };
            var dialogWidth = Math.Min(940, Math.Max(440, XamlRoot.Size.Width - 48));
            dialog.Resources["ContentDialogMaxWidth"] = dialogWidth;
            string? pendingImage = null;

            void ShowImage(string? source)
            {
                pendingImage = source;
                var path = PrizeStore.LocalImage(source) ?? source;
                if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
                var exists = !string.IsNullOrWhiteSpace(path) && File.Exists(path);
                imageStatus.Text = exists ? Path.GetFileName(path) : "Без картинки — будет значок подарка";
                preview.Source = exists ? new BitmapImage(new Uri(path!)) : null;
                previewFallback.Visibility = exists ? Visibility.Collapsed : Visibility.Visible;
            }

            void Refresh(int selected = -1)
            {
                list.Items.Clear();
                var total = entries.Where(p => p.Quantity > 0).Sum(p => p.Weight);
                foreach (var prize in entries)
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                    var path = PrizeStore.LocalImage(prize.Image);
                    if (path is null && Uri.TryCreate(prize.Image, UriKind.Absolute, out var uri) && uri.IsFile)
                        path = uri.LocalPath;
                    if (path is not null && File.Exists(path))
                        row.Children.Add(RoundAvatarFrame(new Image { Source = new BitmapImage(new Uri(path)),
                            Width = 40, Height = 40, Stretch = Stretch.UniformToFill }, 40));
                    else row.Children.Add(new TextBlock { Text = "🎁", FontSize = 27, Width = 40 });
                    var labels = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
                    labels.Children.Add(new TextBlock { Text = prize.Name, FontSize = 15, MaxWidth = 260,
                        TextTrimming = TextTrimming.CharacterEllipsis });
                    var chance = RaffleEngine.PrizeChance(entries, prize)
                        .ToString("P1", new System.Globalization.CultureInfo("ru-RU"));
                    labels.Children.Add(new TextBlock { Text = $"Осталось: {prize.Quantity} · Шанс: {chance} · Вес: {prize.Weight}",
                        FontSize = 11, Opacity = 0.72 });
                    row.Children.Add(labels); list.Items.Add(row);
                }
                list.SelectedIndex = selected;
                remove.IsEnabled = selected >= 0;
                message.Text = total > 0
                    ? "Вес задаёт относительный шанс. Сохраните список, затем откройте барабан на главной."
                    : "Добавьте призы с количеством больше нуля, чтобы открыть розыгрыш.";
            }

            void StashCurrent()
            {
                var profile = catalog.Lists.FirstOrDefault(p => p.Id == currentId);
                if (profile is null) return;
                profile.Name = profileNameBox.Text;
                profile.Prizes = entries;
                var item = profilePicker.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string?)i.Tag == currentId);
                if (item is not null) item.Content = profile.Name;
            }
            profilePicker.SelectionChanged += (_, _) =>
            {
                if (profilePicker.SelectedItem is not ComboBoxItem item || item.Tag is not string id || id == currentId) return;
                StashCurrent();
                currentId = id;
                var profile = catalog.Lists.First(p => p.Id == id);
                profileNameBox.Text = profile.Name;
                entries = profile.Prizes.Select(p => new Prize
                { Id = p.Id, Name = p.Name, Image = p.Image, Quantity = p.Quantity, Weight = p.Weight }).ToList();
                nameBox.Text = ""; quantityBox.Value = 1; weightBox.Value = 1; ShowImage(null);
                Refresh();
            };
            createProfile.Click += (_, _) =>
            {
                StashCurrent();
                var number = 1;
                while (catalog.Lists.Any(p => p.Name.Equals($"Мои призы {number}", StringComparison.OrdinalIgnoreCase))) number++;
                var profile = new PrizeListProfile { Id = "prizelist-" + Guid.NewGuid().ToString("N"), Name = $"Мои призы {number}" };
                catalog.Lists.Add(profile);
                profilePicker.Items.Add(new ComboBoxItem { Content = profile.Name, Tag = profile.Id });
                profilePicker.SelectedIndex = profilePicker.Items.Count - 1;
            };
            deleteProfile.Click += async (_, _) =>
            {
                if (catalog.Lists.Count == 1)
                {
                    try
                    {
                        var removed = catalog.Lists[0];
                        if (_prizeMode && catalog.ActiveId == removed.Id)
                            await ActivateParticipantModeAsync();
                        catalog.Lists.Clear(); catalog.ActiveId = null;
                        await PrizeStore.SaveCatalogAsync(catalog);
                        foreach (var prize in removed.Prizes)
                        {
                            var image = PrizeStore.LocalImage(prize.Image);
                            if (image is not null) File.Delete(image);
                        }
                        _prizes = []; _activePrizeListName = "";
                        dialog.Hide();
                    }
                    catch (Exception ex) { message.Text = $"Не удалось удалить список: {ex.Message}"; }
                    return;
                }
                var index = catalog.Lists.FindIndex(p => p.Id == currentId);
                if (index < 0) return;
                catalog.Lists.RemoveAt(index);
                profilePicker.Items.RemoveAt(index);
                profilePicker.SelectedIndex = Math.Min(index, catalog.Lists.Count - 1);
            };

            list.SelectionChanged += (_, _) =>
            {
                var index = list.SelectedIndex;
                remove.IsEnabled = index >= 0;
                if (index < 0 || index >= entries.Count) return;
                var prize = entries[index];
                nameBox.Text = prize.Name; quantityBox.Value = prize.Quantity; weightBox.Value = prize.Weight;
                ShowImage(prize.Image);
                add.Content = "Сохранить изменения";
            };
            newEntry.Click += (_, _) =>
            {
                list.SelectedIndex = -1; nameBox.Text = ""; quantityBox.Value = 1; weightBox.Value = 1;
                ShowImage(null); add.Content = "Добавить приз";
            };
            chooseImage.Click += async (_, _) =>
            {
                var picker = new FileOpenPicker();
                WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Instance));
                foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".webp" }) picker.FileTypeFilter.Add(ext);
                var file = await picker.PickSingleFileAsync();
                if (file is null) return;
                if (new FileInfo(file.Path).Length > 5 * 1024 * 1024)
                { message.Text = "Картинка должна быть меньше 5 МБ."; return; }
                ShowImage(file.Path);
            };
            clearImage.Click += (_, _) => ShowImage(null);
            bool CommitEditor()
            {
                var name = nameBox.Text.Trim();
                if (name.Length is < 1 or > 120 || double.IsNaN(quantityBox.Value) || double.IsNaN(weightBox.Value)
                    || quantityBox.Value % 1 != 0 || weightBox.Value % 1 != 0
                    || quantityBox.Value is < 0 or > 10000 || weightBox.Value is < 1 or > 1000)
                { message.Text = "Введите название до 120 символов, количество 0–10000 и вес 1–1000."; return false; }
                var index = list.SelectedIndex;
                var prize = index >= 0 && index < entries.Count ? entries[index] :
                    new Prize { Id = "prize-" + Guid.NewGuid().ToString("N") };
                prize.Name = name; prize.Quantity = (int)quantityBox.Value; prize.Weight = (int)weightBox.Value;
                prize.Image = pendingImage ?? "";
                if (index < 0) entries.Add(prize);
                Refresh(); nameBox.Text = ""; quantityBox.Value = 1; weightBox.Value = 1;
                ShowImage(null); add.Content = "Добавить приз";
                return true;
            }
            add.Click += (_, _) => CommitEditor();
            remove.Click += (_, _) =>
            {
                var index = list.SelectedIndex;
                if (index < 0 || index >= entries.Count) return;
                entries.RemoveAt(index); Refresh(); nameBox.Text = ""; ShowImage(null);
                add.Content = "Добавить приз";
            };
            dialog.PrimaryButtonClick += async (_, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    if (!string.IsNullOrWhiteSpace(nameBox.Text) && !CommitEditor())
                    { args.Cancel = true; return; }
                    StashCurrent();
                    await ActivatePrizeListAsync(catalog, currentId);
                }
                catch (Exception ex) { args.Cancel = true; message.Text = $"Не удалось сохранить призы: {ex.Message}"; }
                finally { deferral.Complete(); }
            };

            var imageFrame = new Grid { Width = 70, Height = 70 };
            imageFrame.Children.Add(RoundAvatarFrame(preview, 64)); imageFrame.Children.Add(previewFallback);
            var imageButtons = new StackPanel { Spacing = 6 };
            imageButtons.Children.Add(chooseImage); imageButtons.Children.Add(clearImage);
            var imageRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            imageRow.Children.Add(imageFrame); imageRow.Children.Add(imageButtons);
            var numbers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            quantityBox.Width = 145; weightBox.Width = 145;
            numbers.Children.Add(quantityBox); numbers.Children.Add(weightBox);
            var editor = new StackPanel { Spacing = 12 };
            editor.Children.Add(new TextBlock { Text = "Новый приз", FontSize = 19,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            editor.Children.Add(new TextBlock { Text = "Название, картинка и шанс. Количество уменьшается после каждого выигрыша.",
                TextWrapping = TextWrapping.Wrap, Opacity = 0.75 });
            editor.Children.Add(nameBox); editor.Children.Add(numbers); editor.Children.Add(imageStatus);
            editor.Children.Add(imageRow); editor.Children.Add(add); editor.Children.Add(newEntry);
            var roster = new StackPanel { Spacing = 12 };
            roster.Children.Add(new TextBlock { Text = "Что может выпасть", FontSize = 19,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            roster.Children.Add(list); roster.Children.Add(remove);
            var brush = new SolidColorBrush(Color.FromArgb(45, 58, 106, 150));
            var editorCard = new Border { Padding = new Thickness(16), CornerRadius = new CornerRadius(16),
                Background = brush, Child = editor };
            var rosterCard = new Border { Padding = new Thickness(16), CornerRadius = new CornerRadius(16),
                Background = brush, Child = roster };
            var layout = new StackPanel { Width = dialogWidth - 72, Spacing = 14 };
            var profileBar = new StackPanel { Spacing = 10 };
            profileBar.Children.Add(new TextBlock { Text = "Мои списки призов", FontSize = 19,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            profileBar.Children.Add(profilePicker); profileBar.Children.Add(profileNameBox);
            var profileActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            profileActions.Children.Add(createProfile); profileActions.Children.Add(deleteProfile);
            profileBar.Children.Add(profileActions);
            layout.Children.Add(new Border { Child = profileBar, Padding = new Thickness(16),
                CornerRadius = new CornerRadius(16), Background = brush });
            if (dialogWidth >= 800)
            {
                var columns = new Grid { ColumnSpacing = 14 };
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(350) });
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Grid.SetColumn(editorCard, 0); Grid.SetColumn(rosterCard, 1);
                columns.Children.Add(editorCard); columns.Children.Add(rosterCard); layout.Children.Add(columns);
            }
            else { list.Height = 220; layout.Children.Add(editorCard); layout.Children.Add(rosterCard); }
            layout.Children.Add(message);
            scroll.Content = layout;
            dialog.Content = scroll;
            profilePicker.SelectedIndex = catalog.Lists.FindIndex(p => p.Id == currentId);
            ShowImage(null); Refresh();
            await dialog.ShowAsync();
        }
        catch (Exception ex) { await ShowErrorAsync("Не удалось открыть розыгрыш призов", ex); }
    }
}
