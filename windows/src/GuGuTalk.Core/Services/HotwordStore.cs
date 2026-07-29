using System.Text.Json;
using GuGuTalk.Core.Models;
using Serilog;

namespace GuGuTalk.Core.Services;

public sealed class HotwordStore
{
    private sealed record PersonalLexiconDocument(int Version, IReadOnlyList<PersonalTerm> Terms);

    private static readonly ILogger Logger = Log.ForContext<HotwordStore>();
    private static readonly string StoragePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "GuGuTalk", "hotwords.json");
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    private List<PersonalTerm> _terms = [];
    private readonly string _storagePath;

    public IReadOnlyList<PersonalTerm> Terms => _terms;
    public IReadOnlyList<TextReplacement> Replacements => _terms
        .SelectMany(term => term.Aliases.Select(alias => new TextReplacement(alias, term.Text)))
        .ToArray();
    public bool IsEmpty => _terms.Count == 0;

    public HotwordStore() : this(StoragePath) { }

    internal HotwordStore(string storagePath)
    {
        _storagePath = storagePath;
        Load();
    }

    public void AddTerm(string text)
    {
        string value = text.Trim();
        if (string.IsNullOrEmpty(value)) return;
        if (_terms.Any(term => string.Equals(term.Text, value, StringComparison.OrdinalIgnoreCase))) return;
        _terms.Add(new PersonalTerm(value));
        SortAndSave();
    }

    public void RemoveTerm(Guid id)
    {
        _terms.RemoveAll(term => term.Id == id);
        Save();
    }

    // Retained for migration-compatible callers and explicit aliases from older builds.
    public void Add(string from, string to)
    {
        string alias = from.Trim();
        string canonical = to.Trim();
        if (string.IsNullOrEmpty(alias) || string.IsNullOrEmpty(canonical)) return;

        int index = _terms.FindIndex(term =>
            string.Equals(term.Text, canonical, StringComparison.OrdinalIgnoreCase));
        if (index >= 0)
        {
            if (_terms[index].Aliases.Any(value =>
                    string.Equals(value, alias, StringComparison.OrdinalIgnoreCase))) return;
            _terms[index] = _terms[index] with { Aliases = [.. _terms[index].Aliases, alias] };
        }
        else
        {
            _terms.Add(new PersonalTerm(Guid.NewGuid(), canonical, [alias]));
        }
        SortAndSave();
    }

    public void Remove(string from)
    {
        _terms = _terms.Select(term => term with
        {
            Aliases = term.Aliases.Where(alias => alias != from).ToArray()
        }).ToList();
        Save();
    }

    public string ApplyReplacements(string text)
    {
        string result = text;
        var matches = _terms.SelectMany(term => term.Aliases
                .Append(term.Text)
                .Select(pattern => (Pattern: pattern, Replacement: term.Text)))
            .Where(match => !string.IsNullOrEmpty(match.Pattern))
            .OrderByDescending(match => match.Pattern.Length);

        foreach (var match in matches)
        {
            result = result.Replace(
                match.Pattern,
                match.Replacement,
                StringComparison.OrdinalIgnoreCase);
        }
        return result;
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_storagePath)) return;
            string json = File.ReadAllText(_storagePath);

            if (json.TrimStart().StartsWith('{'))
            {
                var document = JsonSerializer.Deserialize<PersonalLexiconDocument>(json, JsonOptions);
                if (document?.Terms is not null)
                {
                    _terms = Normalize(document.Terms);
                    return;
                }
            }

            var legacy = JsonSerializer.Deserialize<List<TextReplacement>>(json, JsonOptions) ?? [];
            foreach (var replacement in legacy)
            {
                AddInMemory(replacement.Pattern, replacement.Replacement);
            }
            _terms = Normalize(_terms);
            Save();
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to load personal lexicon");
            _terms = [];
        }
    }

    private void AddInMemory(string from, string to)
    {
        string alias = from.Trim();
        string canonical = to.Trim();
        if (string.IsNullOrEmpty(alias) || string.IsNullOrEmpty(canonical)) return;
        int index = _terms.FindIndex(term =>
            string.Equals(term.Text, canonical, StringComparison.OrdinalIgnoreCase));
        if (index >= 0)
        {
            _terms[index] = _terms[index] with { Aliases = [.. _terms[index].Aliases, alias] };
        }
        else
        {
            _terms.Add(new PersonalTerm(Guid.NewGuid(), canonical, [alias]));
        }
    }

    private static List<PersonalTerm> Normalize(IEnumerable<PersonalTerm> input)
    {
        var result = new List<PersonalTerm>();
        foreach (var term in input)
        {
            string text = term.Text.Trim();
            if (string.IsNullOrEmpty(text)) continue;
            var aliases = term.Aliases
                .Select(value => value.Trim())
                .Where(value => !string.IsNullOrEmpty(value))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
                .ToArray();
            int existing = result.FindIndex(value =>
                string.Equals(value.Text, text, StringComparison.OrdinalIgnoreCase));
            if (existing >= 0)
            {
                result[existing] = result[existing] with
                {
                    Aliases = result[existing].Aliases.Concat(aliases)
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
                        .ToArray()
                };
            }
            else
            {
                result.Add(new PersonalTerm(term.Id == Guid.Empty ? Guid.NewGuid() : term.Id, text, aliases));
            }
        }
        return result.OrderBy(term => term.Text, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private void SortAndSave()
    {
        _terms = _terms.OrderBy(term => term.Text, StringComparer.OrdinalIgnoreCase).ToList();
        Save();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_storagePath)!);
            string json = JsonSerializer.Serialize(new PersonalLexiconDocument(2, _terms), JsonOptions);
            File.WriteAllText(_storagePath, json);
        }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Failed to save personal lexicon");
        }
    }
}
