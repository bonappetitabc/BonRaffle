using Windows.ApplicationModel;
using Windows.ApplicationModel.Activation;
using Windows.Foundation;
using Windows.Foundation.Collections;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;

// To learn more about WinUI, the WinUI project structure,
// and more about our project templates, see: http://aka.ms/winui-project-info.

namespace BonRaffle;

/// <summary>
/// Provides application-specific behavior to supplement the default Application class.
/// </summary>
public partial class App : Application
{
    private Window? _window;

    /// <summary>
    /// Initializes the singleton application object.  This is the first line of authored code
    /// executed, and as such is the logical equivalent of main() or WinMain().
    /// </summary>
    public App()
    {
        InitializeComponent();
        UnhandledException += (_, error) => WriteCrashLog(error.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, error) =>
            WriteCrashLog(error.ExceptionObject as Exception);
    }

    private static void WriteCrashLog(Exception? exception)
    {
        try
        {
            Directory.CreateDirectory(RaffleData.DirectoryPath);
            File.AppendAllText(System.IO.Path.Combine(RaffleData.DirectoryPath, "crash.log"),
                $"[{DateTimeOffset.Now:O}] {exception}\n");
        }
        catch { /* A failed diagnostic write must not hide the original error. */ }
    }

    /// <summary>
    /// Invoked when the application is launched.
    /// </summary>
    /// <param name="args">Details about the launch request and process.</param>
    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
