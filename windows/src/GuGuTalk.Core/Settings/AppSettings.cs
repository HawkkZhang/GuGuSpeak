using System.Text.Json;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;
using GuGuTalk.Core.Models;
using Serilog;

namespace GuGuTalk.Core.Settings;

public sealed partial class AppSettings : ObservableObject
{
    private static readonly ILogger Logger = Log.ForContext<AppSettings>();

    private static readonly string SettingsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GuGuTalk");
    private static readonly string SettingsPath = Path.Combine(SettingsDir, "settings.json");

    // Recognition
    [ObservableProperty] private RecognitionMode _preferredMode = RecognitionMode.Local;

    // Hotkeys
    [ObservableProperty] private HotkeyConfiguration _holdToTalkHotkey = HotkeyConfiguration.DefaultHold;
    [ObservableProperty] private bool _holdToTalkEnabled = true;
    [ObservableProperty] private HotkeyConfiguration _toggleToTalkHotkey = HotkeyConfiguration.DefaultToggle;
    [ObservableProperty] private bool _toggleToTalkEnabled = true;

    // Doubao credentials
    [ObservableProperty] private string _doubaoAppId = "";
    [ObservableProperty] private string _doubaoAccessKey = "";
    [ObservableProperty] private string _doubaoResourceId = "";
    [ObservableProperty] private string _doubaoEndpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel";

    // Qwen credentials
    [ObservableProperty] private string _qwenApiKey = "";
    [ObservableProperty] private string _qwenModel = "qwen-turbo-2025-02-11";
    [ObservableProperty] private string _qwenEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference";

    // Post-processing
    [ObservableProperty] private bool _postProcessingEnabled;
    [ObservableProperty] private string? _activePostProcessingPrompt;
    [ObservableProperty] private PunctuationMode _punctuationMode = PunctuationMode.Smart;

    // LLM
    [ObservableProperty] private LLMProviderConfig _llmProviderConfig = LLMProviderConfig.Empty;

    // Appearance
    [ObservableProperty] private bool _followSystemTheme = true;
    [ObservableProperty] private bool _darkMode;

    public DoubaoCredentials DoubaoCredentials => new(DoubaoAppId, DoubaoAccessKey, DoubaoResourceId, DoubaoEndpoint);
    public QwenCredentials QwenCredentials => new(QwenApiKey, QwenModel, QwenEndpoint);

    public RecognitionConfig RecognitionConfig => new(
        LanguageCode: "zh-CN",
        SampleRate: 16000,
        Mode: PreferredMode,
        PartialResultsEnabled: true,
        Endpointing: EndpointingPolicy.Manual,
        DoubaoCredentials: DoubaoCredentials,
        QwenCredentials: QwenCredentials
    );

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDir);
            var dto = ToDto();
            string json = JsonSerializer.Serialize(dto, SerializerOptions);
            File.WriteAllText(SettingsPath, json);
            Logger.Debug("Settings saved");
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "Failed to save settings");
        }
    }

    public static AppSettings Load()
    {
        var settings = new AppSettings();
        try
        {
            if (File.Exists(SettingsPath))
            {
                string json = File.ReadAllText(SettingsPath);
                var dto = JsonSerializer.Deserialize<SettingsDto>(json, SerializerOptions);
                if (dto is not null) settings.ApplyDto(dto);
                Logger.Information("Settings loaded from {Path}", SettingsPath);
            }
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to load settings, using defaults");
        }
        return settings;
    }

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private SettingsDto ToDto() => new()
    {
        PreferredMode = PreferredMode,
        HoldToTalkEnabled = HoldToTalkEnabled,
        ToggleToTalkEnabled = ToggleToTalkEnabled,
        HoldVirtualKey = HoldToTalkHotkey.VirtualKey,
        HoldModifiers = HoldToTalkHotkey.Modifiers,
        ToggleVirtualKey = ToggleToTalkHotkey.VirtualKey,
        ToggleModifiers = ToggleToTalkHotkey.Modifiers,
        DoubaoAppId = DoubaoAppId,
        DoubaoAccessKey = DoubaoAccessKey,
        DoubaoResourceId = DoubaoResourceId,
        DoubaoEndpoint = DoubaoEndpoint,
        QwenApiKey = QwenApiKey,
        QwenModel = QwenModel,
        QwenEndpoint = QwenEndpoint,
        PostProcessingEnabled = PostProcessingEnabled,
        ActivePostProcessingPrompt = ActivePostProcessingPrompt,
        PunctuationMode = PunctuationMode,
        FollowSystemTheme = FollowSystemTheme,
        DarkMode = DarkMode
    };

    private void ApplyDto(SettingsDto dto)
    {
        PreferredMode = dto.PreferredMode;
        HoldToTalkEnabled = dto.HoldToTalkEnabled;
        ToggleToTalkEnabled = dto.ToggleToTalkEnabled;
        HoldToTalkHotkey = new HotkeyConfiguration(dto.HoldVirtualKey, dto.HoldModifiers, FormatHotkey(dto.HoldVirtualKey, dto.HoldModifiers));
        ToggleToTalkHotkey = new HotkeyConfiguration(dto.ToggleVirtualKey, dto.ToggleModifiers, FormatHotkey(dto.ToggleVirtualKey, dto.ToggleModifiers));
        DoubaoAppId = dto.DoubaoAppId;
        DoubaoAccessKey = dto.DoubaoAccessKey;
        DoubaoResourceId = dto.DoubaoResourceId;
        DoubaoEndpoint = dto.DoubaoEndpoint;
        QwenApiKey = dto.QwenApiKey;
        QwenModel = dto.QwenModel;
        QwenEndpoint = dto.QwenEndpoint;
        PostProcessingEnabled = dto.PostProcessingEnabled;
        ActivePostProcessingPrompt = dto.ActivePostProcessingPrompt;
        PunctuationMode = dto.PunctuationMode;
        FollowSystemTheme = dto.FollowSystemTheme;
        DarkMode = dto.DarkMode;
    }

    private static string FormatHotkey(int vk, ModifierKeys mods)
    {
        var parts = new List<string>();
        if (mods.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (mods.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (mods.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (mods.HasFlag(ModifierKeys.Win)) parts.Add("Win");
        parts.Add(VirtualKeyName(vk));
        return string.Join("+", parts);
    }

    private static string VirtualKeyName(int vk) => vk switch
    {
        0x20 => "Space",
        0xC0 => "`",
        _ => $"0x{vk:X2}"
    };
}

internal sealed class SettingsDto
{
    public RecognitionMode PreferredMode { get; set; }
    public bool HoldToTalkEnabled { get; set; } = true;
    public bool ToggleToTalkEnabled { get; set; } = true;
    public int HoldVirtualKey { get; set; } = 0xC0;
    public ModifierKeys HoldModifiers { get; set; } = ModifierKeys.Control;
    public int ToggleVirtualKey { get; set; } = 0x20;
    public ModifierKeys ToggleModifiers { get; set; } = ModifierKeys.Alt;
    public string DoubaoAppId { get; set; } = "";
    public string DoubaoAccessKey { get; set; } = "";
    public string DoubaoResourceId { get; set; } = "";
    public string DoubaoEndpoint { get; set; } = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel";
    public string QwenApiKey { get; set; } = "";
    public string QwenModel { get; set; } = "qwen-turbo-2025-02-11";
    public string QwenEndpoint { get; set; } = "wss://dashscope.aliyuncs.com/api-ws/v1/inference";
    public bool PostProcessingEnabled { get; set; }
    public string? ActivePostProcessingPrompt { get; set; }
    public PunctuationMode PunctuationMode { get; set; }
    public bool FollowSystemTheme { get; set; } = true;
    public bool DarkMode { get; set; }
}
