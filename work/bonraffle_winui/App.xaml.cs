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
    // The installer waits for all application instances to exit before replacing files.
    private readonly Mutex _runningMutex = new(false, @"Local\BonRaffle.Running");
    public static bool NotificationsAvailable { get; private set; }

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
        if (Environment.GetCommandLineArgs().Contains("--uninstall-notifications"))
        {
            try { Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat.Uninstall(); } catch { }
            Exit();
            return;
        }
        _window = new MainWindow();
        try
        {
            // The App SDK 2.5.1 registration requires a runtime resource absent from
            // self-contained deployment. The toolkit registers native Win32 toasts locally.
            Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat.OnActivated += args =>
            {
                if (args.Argument == "action=updates")
                    _window.DispatcherQueue.TryEnqueue(() => { _window.Activate(); MainPage.Current?.OpenUpdatesWindow(); });
            };
            _ = Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat.CreateToastNotifier();
            NotificationsAvailable = true;
        }
        catch (Exception error)
        {
            NotificationsAvailable = false;
            try { File.AppendAllText(System.IO.Path.Combine(RaffleData.DirectoryPath, "updates.log"),
                $"Notification registration: 0x{error.HResult:X8} {error.Message}\n"); } catch { }
        }
        _window.Closed += (_, _) => _runningMutex.Dispose();
        _window.Activate();
    }
}
