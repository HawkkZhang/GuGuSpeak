using GuGuTalk.Core.Models;
using GuGuTalk.Core.Settings;

namespace GuGuTalk.Core.Providers;

public sealed class ProviderFactory
{
    private readonly AppSettings _settings;
    private ISpeechProvider? _localProvider;

    public ProviderFactory(AppSettings settings)
    {
        _settings = settings;
    }

    public void RegisterLocalProvider(ISpeechProvider provider)
    {
        _localProvider = provider;
    }

    public List<ProviderSelection> ResolveProviders()
    {
        var selections = new List<ProviderSelection>();

        switch (_settings.PreferredMode)
        {
            case RecognitionMode.Local:
                if (_localProvider is not null)
                    selections.Add(new ProviderSelection(RecognitionMode.Local, _localProvider));
                break;
            case RecognitionMode.Doubao:
                if (_settings.DoubaoCredentials.IsConfigured)
                    selections.Add(new ProviderSelection(RecognitionMode.Doubao, new DoubaoSpeechProvider()));
                if (_settings.QwenCredentials.IsConfigured)
                    selections.Add(new ProviderSelection(RecognitionMode.Qwen, new QwenSpeechProvider()));
                break;
            case RecognitionMode.Qwen:
                if (_settings.QwenCredentials.IsConfigured)
                    selections.Add(new ProviderSelection(RecognitionMode.Qwen, new QwenSpeechProvider()));
                if (_settings.DoubaoCredentials.IsConfigured)
                    selections.Add(new ProviderSelection(RecognitionMode.Doubao, new DoubaoSpeechProvider()));
                break;
        }

        return selections;
    }
}
