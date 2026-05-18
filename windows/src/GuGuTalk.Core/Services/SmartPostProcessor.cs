using GuGuTalk.Core.Models;
using GuGuTalk.Core.Settings;
using Serilog;

namespace GuGuTalk.Core.Services;

public sealed class SmartPostProcessor
{
    private static readonly ILogger Logger = Log.ForContext<SmartPostProcessor>();

    private readonly AppSettings _settings;
    private readonly HotwordStore _hotwordStore;
    private readonly LLMClient _llmClient;
    private readonly TranscriptPostProcessor _postProcessor = new();

    public SmartPostProcessor(AppSettings settings, HotwordStore hotwordStore, LLMClient llmClient)
    {
        _settings = settings;
        _hotwordStore = hotwordStore;
        _llmClient = llmClient;
    }

    public string ProcessRulesOnly(string text)
    {
        string result = _postProcessor.Finalize(text);
        result = _hotwordStore.ApplyReplacements(result);
        return ApplyPunctuationRules(result);
    }

    public async Task<string> ProcessAsync(string text, string? targetApp = null)
    {
        string result = _postProcessor.Finalize(text);
        result = _hotwordStore.ApplyReplacements(result);

        if (string.IsNullOrEmpty(result)) return result;

        if (!_settings.PostProcessingEnabled)
            return ApplyPunctuationRules(result);

        string? prompt = _settings.ActivePostProcessingPrompt;
        if (string.IsNullOrEmpty(prompt))
            return ApplyPunctuationRules(result);

        if (!_settings.LlmProviderConfig.IsConfigured)
        {
            Logger.Information("LLM not configured, skipping post-processing");
            return ApplyPunctuationRules(result);
        }

        string systemPrompt = BuildSystemPrompt(prompt);

        try
        {
            string llmResult = await _llmClient.CompleteAsync(systemPrompt, result, _settings.LlmProviderConfig);
            if (!string.IsNullOrEmpty(llmResult))
            {
                result = llmResult;
            }
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "LLM post-processing failed, using rule-only result");
        }

        result = _hotwordStore.ApplyReplacements(result);
        return ApplyPunctuationRules(result);
    }

    private string BuildSystemPrompt(string basePrompt)
    {
        if (_hotwordStore.IsEmpty) return basePrompt;

        var wordList = string.Join("、", _hotwordStore.Replacements.Select(r => r.Replacement));
        return basePrompt + $"\n\n参考热词表（如果识别结果中有发音相近但拼写不同的词，优先使用热词表中的正确写法）：{wordList}";
    }

    private string ApplyPunctuationRules(string text)
    {
        string result = _postProcessor.Finalize(text);

        return _settings.PunctuationMode switch
        {
            PunctuationMode.Remove => RemoveAllPunctuation(result),
            PunctuationMode.SpaceReplace => ReplacePunctuationWithSpace(result),
            PunctuationMode.RemoveTrailingPeriod => RemoveTrailingPeriod(result),
            _ => result // Smart: keep as-is
        };
    }

    private static string RemoveAllPunctuation(string text) =>
        new string(text.Where(c => !IsCjkPunctuation(c) && !char.IsPunctuation(c)).ToArray()).Trim();

    private static string ReplacePunctuationWithSpace(string text)
    {
        var chars = new List<char>();
        foreach (char c in text)
        {
            if (IsCjkPunctuation(c) || char.IsPunctuation(c))
                chars.Add(' ');
            else
                chars.Add(c);
        }
        return TranscriptPostProcessor.NormalizeSpeechText(new string(chars.ToArray()));
    }

    private static string RemoveTrailingPeriod(string text)
    {
        string trimmed = text.TrimEnd();
        if (trimmed.EndsWith('。') || trimmed.EndsWith('.'))
            return trimmed[..^1];
        return trimmed;
    }

    private static bool IsCjkPunctuation(char c) =>
        c is '，' or '。' or '！' or '？' or '；' or '：' or '、'
        or '（' or '）' or '《' or '》' or '「' or '」' or '『' or '』' or '【' or '】';
}
