using System.Windows;
using GuGuTalk.App.Interop;
using GuGuTalk.App.TrayIcon;
using GuGuTalk.App.Views;
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Providers;
using GuGuTalk.Core.Services;
using GuGuTalk.Core.Settings;
using GuGuTalk.LocalAsr;
using Serilog;

namespace GuGuTalk.App;

public partial class App : Application
{
    private AppSettings _settings = null!;
    private AudioCaptureEngine _audioEngine = null!;
    private HotkeyManager _hotkeyManager = null!;
    private RecognitionOrchestrator _orchestrator = null!;
    private TrayIconManager _trayIcon = null!;
    private KeyboardHook _keyboardHook = null!;
    private OverlayWindow _overlayWindow = null!;
    private SettingsWindow? _settingsWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Debug()
            .WriteTo.File(
                System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "GuGuTalk", "logs", "gugutalk-.log"),
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 7,
                flushToDiskInterval: TimeSpan.FromSeconds(1))
            .CreateLogger();

        AppDomain.CurrentDomain.UnhandledException += (_, ev) =>
        {
            Log.Fatal(ev.ExceptionObject as Exception, "Unhandled domain exception (terminating={Term})", ev.IsTerminating);
            Log.CloseAndFlush();
        };
        TaskScheduler.UnobservedTaskException += (_, ev) =>
        {
            Log.Error(ev.Exception, "Unobserved task exception");
            ev.SetObserved();
        };
        DispatcherUnhandledException += (_, ev) =>
        {
            Log.Error(ev.Exception, "Unhandled dispatcher exception");
            ev.Handled = true;
        };

        Log.Information("GuGuTalk starting");

        _settings = AppSettings.Load();
        _audioEngine = new AudioCaptureEngine();
        _audioEngine.Prewarm();

        var hotwordStore = new HotwordStore();
        var llmClient = new LLMClient();
        var providerFactory = new ProviderFactory(_settings);
        var localProvider = new SherpaOnnxProvider();
        localProvider.Prewarm();
        providerFactory.RegisterLocalProvider(localProvider);
        var textInsertion = new TextInsertionService();
        var postProcessor = new SmartPostProcessor(_settings, hotwordStore, llmClient);

        _hotkeyManager = new HotkeyManager(_settings);
        _orchestrator = new RecognitionOrchestrator(
            _settings, _audioEngine, providerFactory, textInsertion, postProcessor);

        _hotkeyManager.OnHoldPress += () =>
        {
            // Snapshot the foreground window now -- we're inside the keyboard
            // hook callback, so the user's editor still has focus. By the time
            // post-processing finishes and we paste, focus may have wandered
            // (overlay show, hook re-entry, async delays). Restoring this HWND
            // before paste is what actually makes the insertion land.
            _orchestrator.CaptureTargetWindow();
            _ = _orchestrator.BeginCaptureAsync();
        };
        _hotkeyManager.OnHoldRelease += () => _ = _orchestrator.EndCaptureAsync();
        _hotkeyManager.OnTogglePress += () =>
        {
            if (_orchestrator.HasActiveWork)
                _ = _orchestrator.EndCaptureAsync();
            else
            {
                _orchestrator.CaptureTargetWindow();
                _ = _orchestrator.BeginCaptureAsync();
            }
        };

        _keyboardHook = new KeyboardHook();
        _keyboardHook.KeyEvent += (vk, isDown, mods) =>
            _hotkeyManager.HandleKeyEvent(vk, isDown, mods);
        _keyboardHook.Install();
        _hotkeyManager.Start();

        _overlayWindow = new OverlayWindow(_orchestrator);

        _trayIcon = new TrayIconManager(_settings, _orchestrator, OpenSettings, ExitApp);
        _trayIcon.Initialize();

        Log.Information("GuGuTalk ready. Mode={Mode}", _settings.PreferredMode.Title());
    }

    private void OpenSettings()
    {
        if (_settingsWindow is null || !_settingsWindow.IsLoaded)
        {
            _settingsWindow = new SettingsWindow(_settings, _hotkeyManager);
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void ExitApp()
    {
        _keyboardHook.Dispose();
        _hotkeyManager.Stop();
        _audioEngine.Dispose();
        _trayIcon.Dispose();
        _settings.Save();
        Log.Information("GuGuTalk exiting");
        Log.CloseAndFlush();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _keyboardHook.Dispose();
        _trayIcon.Dispose();
        _audioEngine.Dispose();
        Log.CloseAndFlush();
        base.OnExit(e);
    }
}

