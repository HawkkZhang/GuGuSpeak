using System.Globalization;
using System.Text;
using GuGuTalk.Core.Models;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Serilog;

namespace GuGuTalk.Core.Services;

internal sealed record PhoneticCandidate(
    int Start,
    int Length,
    string Original,
    string Replacement,
    double PhoneticDistance);

internal sealed class PhoneticCandidateFinder
{
    private sealed record PhoneticToken(
        int Start,
        int Length,
        int Segment,
        IReadOnlyList<string> Pronunciations,
        int EstimatedUnits);

    private sealed record PreparedTerm(
        string Text,
        IReadOnlyList<string> Pronunciations,
        int EstimatedUnits);

    private readonly Dictionary<int, HashSet<string>> _readings = [];
    private readonly Dictionary<string, HashSet<string>> _englishReadings = new(StringComparer.Ordinal);
    private readonly object _cacheLock = new();
    private string[] _cachedTermTexts = [];
    private IReadOnlyList<PreparedTerm> _cachedTerms = [];

    public PhoneticCandidateFinder(string pinyinData, string englishPronunciationData = "")
    {
        foreach (string rawLine in pinyinData.Split('\n'))
        {
            string line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            int colon = line.IndexOf(':');
            if (colon <= 2 || !line.StartsWith("U+", StringComparison.Ordinal)) continue;
            if (!int.TryParse(line.AsSpan(2, colon - 2), NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture, out int codePoint)) continue;
            int comment = line.IndexOf('#', colon + 1);
            string value = line[(colon + 1)..(comment >= 0 ? comment : line.Length)];
            var readings = value.Split(',', StringSplitOptions.RemoveEmptyEntries)
                .Select(PinyinPronunciation)
                .Where(reading => reading.Length > 0)
                .ToHashSet(StringComparer.Ordinal);
            if (readings.Count > 0) _readings[codePoint] = readings;
        }

        foreach (string rawLine in englishPronunciationData.Split('\n'))
        {
            string[] fields = rawLine.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2 || fields[0].StartsWith(";;;", StringComparison.Ordinal)) continue;
            string word = fields[0].ToLowerInvariant();
            int variantStart = word.IndexOf('(');
            if (variantStart >= 0) word = word[..variantStart];
            string pronunciation = string.Join(' ', fields.Skip(1)
                .Select(NormalizeEnglishPhoneme)
                .Where(value => value.Length > 0));
            if (word.Length == 0 || pronunciation.Length == 0) continue;
            if (!_englishReadings.TryGetValue(word, out var values))
            {
                values = new HashSet<string>(StringComparer.Ordinal);
                _englishReadings[word] = values;
            }
            values.Add(pronunciation);
        }
    }

    public IReadOnlyList<PhoneticCandidate> Find(
        string text,
        IReadOnlyList<PersonalTerm> terms,
        int limit = 16)
    {
        var elements = TextElements(text);
        var tokens = Tokenize(elements);
        if (tokens.Count == 0) return [];
        var result = new List<PhoneticCandidate>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var term in PrepareTerms(terms))
        {
            int maximumTokenCount = Math.Min(tokens.Count, Math.Max(4, term.EstimatedUnits + 2));
            for (int start = 0; start < tokens.Count; start++)
            {
                for (int tokenCount = 1; tokenCount <= maximumTokenCount; tokenCount++)
                {
                    int end = start + tokenCount;
                    if (end > tokens.Count) break;
                    var slice = tokens.GetRange(start, tokenCount);
                    if (slice[^1].Segment != slice[0].Segment) break;

                    int elementStart = slice[0].Start;
                    int elementEnd = slice[^1].Start + slice[^1].Length;
                    string original = string.Concat(elements.Skip(elementStart).Take(elementEnd - elementStart));
                    if (string.Equals(original, term.Text, StringComparison.OrdinalIgnoreCase)) continue;
                    var sourcePronunciations = CombinePronunciations(
                        slice.Select(token => token.Pronunciations));
                    double? distance = MinimumDistance(sourcePronunciations, term.Pronunciations);
                    if (distance is null) continue;

                    string key = $"{elementStart}:{elementEnd}:{term.Text.ToLowerInvariant()}";
                    if (!seen.Add(key)) continue;
                    result.Add(new PhoneticCandidate(
                        elementStart,
                        elementEnd - elementStart,
                        original,
                        term.Text,
                        distance.Value));
                }
            }
        }

        return result.OrderBy(candidate => candidate.PhoneticDistance)
            .ThenByDescending(candidate => candidate.Length)
            .Take(limit)
            .ToArray();
    }

    private IReadOnlyList<PreparedTerm> PrepareTerms(IReadOnlyList<PersonalTerm> terms)
    {
        // Personal lists are small; rebuild their bounded pronunciation index only after an edit.
        string[] texts = terms.Select(term => term.Text.Trim())
            .Where(text => text.Length > 0)
            .ToArray();
        lock (_cacheLock)
        {
            if (texts.SequenceEqual(_cachedTermTexts, StringComparer.Ordinal)) return _cachedTerms;
            _cachedTermTexts = texts;
            _cachedTerms = texts.Select(text =>
                {
                    var tokens = Tokenize(TextElements(text));
                    var pronunciations = CombinePronunciations(
                        tokens.Select(token => token.Pronunciations));
                    return pronunciations.Count == 0
                        ? null
                        : new PreparedTerm(
                            text,
                            pronunciations,
                            tokens.Sum(token => token.EstimatedUnits));
                })
                .Where(term => term is not null)
                .Cast<PreparedTerm>()
                .ToArray();
            return _cachedTerms;
        }
    }

    private List<PhoneticToken> Tokenize(IReadOnlyList<string> elements)
    {
        var tokens = new List<PhoneticToken>();
        int index = 0;
        int segment = 0;
        while (index < elements.Count)
        {
            if (IsAsciiWordElement(elements[index]))
            {
                int end = index + 1;
                while (end < elements.Count && IsAsciiWordElement(elements[end])) end++;
                string word = string.Concat(elements.Skip(index).Take(end - index));
                var pronunciations = LatinPronunciations(word);
                if (pronunciations.Count > 0)
                    tokens.Add(new PhoneticToken(
                        index,
                        end - index,
                        segment,
                        pronunciations,
                        Math.Max(1, SplitLatinWord(word).Count)));
                index = end;
                continue;
            }

            Rune rune = elements[index].EnumerateRunes().First();
            if (_readings.TryGetValue(rune.Value, out var values))
                tokens.Add(new PhoneticToken(
                    index, 1, segment, values.Order(StringComparer.Ordinal).ToArray(), 1));
            else if (IsCjk(rune.Value))
                tokens.Add(new PhoneticToken(index, 1, segment, [elements[index]], 1));
            else if (SymbolPronunciations.TryGetValue(elements[index], out var pronunciations))
                tokens.Add(new PhoneticToken(index, 1, segment, pronunciations, 1));
            else if (!Rune.IsWhiteSpace(rune))
            {
                UnicodeCategory category = Rune.GetUnicodeCategory(rune);
                if (category is UnicodeCategory.ConnectorPunctuation
                    or UnicodeCategory.DashPunctuation
                    or UnicodeCategory.OpenPunctuation
                    or UnicodeCategory.ClosePunctuation
                    or UnicodeCategory.InitialQuotePunctuation
                    or UnicodeCategory.FinalQuotePunctuation
                    or UnicodeCategory.OtherPunctuation
                    or UnicodeCategory.MathSymbol
                    or UnicodeCategory.CurrencySymbol
                    or UnicodeCategory.ModifierSymbol
                    or UnicodeCategory.OtherSymbol)
                {
                    segment++;
                }
                else
                {
                    string value = NormalizePhoneticText(elements[index]);
                    if (value.Length > 0)
                        tokens.Add(new PhoneticToken(index, 1, segment, [value], 1));
                }
            }
            index++;
        }
        return tokens;
    }

    private static double? MinimumDistance(
        IReadOnlyList<string> source,
        IReadOnlyList<string> target)
    {
        double best = double.MaxValue;
        foreach (string sourceValue in source)
        {
            foreach (string targetValue in target)
            {
                string[] sourcePhonemes = Phonemes(sourceValue);
                string[] targetPhonemes = Phonemes(targetValue);
                int longest = Math.Max(sourcePhonemes.Length, targetPhonemes.Length);
                int shortest = Math.Min(sourcePhonemes.Length, targetPhonemes.Length);
                if (longest == 0 || shortest / (double)longest < 0.64) continue;
                double distance = WeightedEditDistance(sourcePhonemes, targetPhonemes);
                double threshold = longest <= 3 ? 0.12 : longest <= 5 ? 0.28 : 0.36;
                if (distance <= threshold) best = Math.Min(best, distance);
            }
        }
        return double.IsFinite(best) && best < double.MaxValue ? best : null;
    }

    private static string[] Phonemes(string value) =>
        value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    private static double WeightedEditDistance(string[] left, string[] right)
    {
        var previous = new double[right.Length + 1];
        for (int index = 0; index < right.Length; index++)
            previous[index + 1] = previous[index] + InsertionCost(right[index]);
        for (int leftIndex = 0; leftIndex < left.Length; leftIndex++)
        {
            var current = new double[right.Length + 1];
            current[0] = previous[0] + DeletionCost(left[leftIndex]);
            for (int rightIndex = 0; rightIndex < right.Length; rightIndex++)
            {
                current[rightIndex + 1] = Math.Min(
                    Math.Min(
                        previous[rightIndex + 1] + DeletionCost(left[leftIndex]),
                        current[rightIndex] + InsertionCost(right[rightIndex])),
                    previous[rightIndex] + SubstitutionCost(left[leftIndex], right[rightIndex]));
            }
            previous = current;
        }
        return previous[right.Length] / Math.Max(1, Math.Max(left.Length, right.Length));
    }

    private static double InsertionCost(string value) => VowelPhonemes.Contains(value) ? 0.75 : 1;

    private static double DeletionCost(string value) => InsertionCost(value);

    private static double SubstitutionCost(string lhs, string rhs)
    {
        if (lhs == rhs) return 0;
        if (VowelPhonemes.Contains(lhs) && VowelPhonemes.Contains(rhs)) return 0.35;
        if (ConfusionGroups.Any(group => group.Contains(lhs) && group.Contains(rhs))) return 0.45;
        return 1;
    }

    private static IReadOnlyList<string> CombinePronunciations(
        IEnumerable<IReadOnlyList<string>> groups,
        int limit = 48)
    {
        IReadOnlyList<string> result = [""];
        foreach (var group in groups)
        {
            result = result.SelectMany(prefix => group
                    .Where(pronunciation => pronunciation.Length > 0)
                    .Select(pronunciation => prefix.Length == 0
                        ? pronunciation
                        : prefix + " " + pronunciation))
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .Take(limit)
                .ToArray();
            if (result.Count == 0) break;
        }
        return result;
    }

    private IReadOnlyList<string> LatinPronunciations(string value)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        var parts = SplitLatinWord(value);
        result.UnionWith(CombinePronunciations(parts.Select(PronunciationsForLatinPart)));
        string key = EnglishDictionaryKey(value);
        if (_englishReadings.TryGetValue(key, out var pronunciations)) result.UnionWith(pronunciations);
        else if (key.Length > 0) result.Add(FallbackEnglishPronunciation(key));
        return result.Where(item => item.Length > 0).Order(StringComparer.Ordinal).ToArray();
    }

    private IReadOnlyList<string> PronunciationsForLatinPart(string value)
    {
        string normalized = NormalizeLatinWord(value);
        if (normalized.Length == 0) return [];
        if (normalized.All(char.IsDigit))
            return CombinePronunciations(normalized.Select(character =>
                DigitPronunciations.GetValueOrDefault(character, [])));
        if (normalized.Length == 1 && LetterPronunciations.TryGetValue(normalized[0], out string? name))
            return [name];

        var result = new HashSet<string>(StringComparer.Ordinal);
        string key = EnglishDictionaryKey(value);
        if (_englishReadings.TryGetValue(key, out var pronunciations)) result.UnionWith(pronunciations);
        else if (key.Length > 0) result.Add(FallbackEnglishPronunciation(key));
        if (value.Length > 1 && value.All(character => char.IsLetter(character) && char.IsUpper(character)))
        {
            result.UnionWith(CombinePronunciations(value.Select(character =>
            {
                char normalizedLetter = char.ToLowerInvariant(character);
                return LetterPronunciations.TryGetValue(normalizedLetter, out string? letterName)
                    ? new[] { letterName }
                    : Array.Empty<string>();
            })));
        }
        return result.Where(item => item.Length > 0).Order(StringComparer.Ordinal).ToArray();
    }

    private static string EnglishDictionaryKey(string value) =>
        string.Concat(NormalizePhoneticText(value).Where(character => char.IsLetter(character) || character == '\''));

    private static string NormalizeEnglishPhoneme(string value) =>
        string.Concat(value.ToUpperInvariant().Where(character => !char.IsDigit(character)));

    private static string FallbackEnglishPronunciation(string value)
    {
        var characters = value.ToList();
        if (characters.Count > 2)
        {
            string prefix = new(characters.Take(2).ToArray());
            if (prefix is "kn" or "wr") characters.RemoveAt(0);
        }

        var result = new List<string>();
        int index = 0;
        while (index < characters.Count)
        {
            if (index == characters.Count - 1 && characters[index] == 'e' && characters.Count > 2) break;
            if (index > 0 && characters[index] == characters[index - 1]
                && Consonants.Contains(characters[index]))
            {
                index++;
                continue;
            }

            string remainder = new(characters.Skip(index).ToArray());
            var rule = EnglishDigraphRules.FirstOrDefault(candidate =>
                remainder.StartsWith(candidate.Text, StringComparison.Ordinal));
            if (rule.Text is not null)
            {
                result.AddRange(rule.Phonemes);
                index += rule.Text.Length;
                continue;
            }

            char? next = index + 1 < characters.Count ? characters[index + 1] : null;
            switch (characters[index])
            {
                case 'a': result.Add("AE"); break;
                case 'b': result.Add("B"); break;
                case 'c': result.Add(next is 'e' or 'i' or 'y' ? "S" : "K"); break;
                case 'd': result.Add("D"); break;
                case 'e': result.Add("EH"); break;
                case 'f': result.Add("F"); break;
                case 'g': result.Add(next is 'e' or 'i' or 'y' ? "JH" : "G"); break;
                case 'h': result.Add("HH"); break;
                case 'i': result.Add("IH"); break;
                case 'j': result.Add("JH"); break;
                case 'k': result.Add("K"); break;
                case 'l': result.Add("L"); break;
                case 'm': result.Add("M"); break;
                case 'n': result.Add("N"); break;
                case 'o': result.Add("AA"); break;
                case 'p': result.Add("P"); break;
                case 'q': result.AddRange(["K", "W"]); break;
                case 'r': result.Add("R"); break;
                case 's': result.Add("S"); break;
                case 't': result.Add("T"); break;
                case 'u': result.Add("AH"); break;
                case 'v': result.Add("V"); break;
                case 'w': result.Add("W"); break;
                case 'x': result.AddRange(["K", "S"]); break;
                case 'y': result.Add(index == 0 ? "Y" : "IY"); break;
                case 'z': result.Add("Z"); break;
            }
            index++;
        }
        return string.Join(' ', result);
    }

    private static string PinyinPronunciation(string value)
    {
        string syllable = NormalizePhoneticText(value);
        if (syllable.Length == 0) return "";
        if (SpecialPinyinPronunciations.TryGetValue(syllable, out string? special)) return special;

        string initial = "";
        string final = syllable;
        foreach (string candidate in PinyinInitialOrder)
        {
            if (!syllable.StartsWith(candidate, StringComparison.Ordinal)) continue;
            initial = candidate;
            final = syllable[candidate.Length..];
            break;
        }
        var phonemes = new List<string>();
        if (PinyinInitials.TryGetValue(initial, out string? initialPhonemes)
            && initialPhonemes.Length > 0)
            phonemes.AddRange(Phonemes(initialPhonemes));
        if (final == "i" && PinyinApicalInitials.Contains(initial))
            phonemes.Add("IH");
        else if (PinyinFinals.TryGetValue(final, out string? finalPhonemes))
            phonemes.AddRange(Phonemes(finalPhonemes));
        else
            phonemes.AddRange(Phonemes(FallbackEnglishPronunciation(final)));
        return string.Join(' ', phonemes);
    }

    private static string NormalizePhoneticText(string value)
    {
        string decomposed = value.Replace('ü', 'v').Trim().Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder();
        foreach (Rune rune in decomposed.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.NonSpacingMark)
                builder.Append(rune.ToString().ToLowerInvariant());
        }
        return builder.ToString();
    }

    private static string NormalizeLatinWord(string value) =>
        string.Concat(NormalizePhoneticText(value).Where(char.IsLetterOrDigit));

    private static IReadOnlyList<string> SplitLatinWord(string value)
    {
        char[] characters = value.ToCharArray();
        if (characters.Length == 0) return [];
        var result = new List<string>();
        int start = 0;
        for (int index = 1; index < characters.Length; index++)
        {
            char previous = characters[index - 1];
            char current = characters[index];
            char? next = index + 1 < characters.Length ? characters[index + 1] : null;
            bool lowerToUpper = char.IsLower(previous) && char.IsUpper(current);
            bool acronymBoundary = char.IsUpper(previous) && char.IsUpper(current)
                && next.HasValue && char.IsLower(next.Value);
            bool digitBoundary = char.IsDigit(previous) != char.IsDigit(current)
                && (char.IsLetter(previous) || char.IsLetter(current));
            if (!lowerToUpper && !acronymBoundary && !digitBoundary) continue;
            result.Add(new string(characters[start..index]));
            start = index;
        }
        result.Add(new string(characters[start..]));
        return result;
    }

    private static List<string> TextElements(string value) =>
        value.EnumerateRunes().Select(rune => rune.ToString()).ToList();

    private static bool IsAsciiWordElement(string value)
    {
        Rune rune = value.EnumerateRunes().First();
        return rune.IsAscii && (Rune.IsLetterOrDigit(rune) || rune.Value == 39);
    }

    private static bool IsCjk(int value) =>
        value is >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF
            or >= 0xF900 and <= 0xFAFF
            or >= 0x20000 and <= 0x323AF;

    private const string Consonants = "bcdfghjklmnpqrstvwxyz";
    private static readonly HashSet<string> VowelPhonemes = new(StringComparer.Ordinal)
    {
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY",
        "IH", "IY", "OW", "OY", "UH", "UW"
    };
    private static readonly HashSet<string>[] ConfusionGroups =
    [
        new(["G", "K"], StringComparer.Ordinal),
        new(["B", "P"], StringComparer.Ordinal),
        new(["D", "T"], StringComparer.Ordinal),
        new(["N", "L", "R"], StringComparer.Ordinal),
        new(["F", "HH"], StringComparer.Ordinal),
        new(["S", "SH", "Z", "ZH"], StringComparer.Ordinal),
        new(["CH", "JH"], StringComparer.Ordinal),
        new(["M", "N"], StringComparer.Ordinal)
    ];
    private static readonly Dictionary<char, string> LetterPronunciations = new()
    {
        ['a'] = "EY", ['b'] = "B IY", ['c'] = "S IY", ['d'] = "D IY", ['e'] = "IY",
        ['f'] = "EH F", ['g'] = "JH IY", ['h'] = "EY CH", ['i'] = "AY", ['j'] = "JH EY",
        ['k'] = "K EY", ['l'] = "EH L", ['m'] = "EH M", ['n'] = "EH N", ['o'] = "OW",
        ['p'] = "P IY", ['q'] = "K Y UW", ['r'] = "AA R", ['s'] = "EH S", ['t'] = "T IY",
        ['u'] = "Y UW", ['v'] = "V IY", ['w'] = "D AH B AH L Y UW", ['x'] = "EH K S",
        ['y'] = "W AY", ['z'] = "Z IY"
    };
    private static readonly Dictionary<char, IReadOnlyList<string>> DigitPronunciations = new()
    {
        ['0'] = ["L IH NG", "Z IH R OW"], ['1'] = ["IY", "W AH N"],
        ['2'] = ["ER", "T UW"], ['3'] = ["S AA N", "TH R IY"],
        ['4'] = ["F AO R", "S IH"], ['5'] = ["F AY V", "UW"],
        ['6'] = ["L Y OW", "S IH K S"], ['7'] = ["CH IY", "S EH V AH N"],
        ['8'] = ["B AA", "EY T"], ['9'] = ["JH Y OW", "N AY N"]
    };
    private static readonly Dictionary<string, IReadOnlyList<string>> SymbolPronunciations =
        new(StringComparer.Ordinal)
        {
            ["+"] = ["JH Y AA", "P L AH S"],
            ["#"] = ["HH AE SH", "JH IH NG HH AW", "SH AA R P"],
            ["&"] = ["AE N D", "HH AH"], ["@"] = ["AE T", "AY T AH"],
            ["%"] = ["B AY F AH N HH AW", "P ER S EH N T"],
            ["-"] = ["D AE SH", "HH AH NG G AA NG", "JH Y EH N", "M AY N AH S"],
            ["."] = ["D AA T", "D Y EH N"]
        };
    private static readonly (string Text, string[] Phonemes)[] EnglishDigraphRules =
    [
        ("tion", ["SH", "AH", "N"]), ("sion", ["ZH", "AH", "N"]),
        ("tch", ["CH"]), ("igh", ["AY"]), ("ch", ["CH"]), ("sh", ["SH"]),
        ("th", ["TH"]), ("ph", ["F"]), ("ng", ["NG"]),
        ("qu", ["K", "W"]), ("qw", ["K", "W"]), ("ck", ["K"]),
        ("wh", ["W"]), ("ee", ["IY"]), ("ea", ["IY"]), ("oo", ["UW"]),
        ("ai", ["EY"]), ("ay", ["EY"]), ("oa", ["OW"]),
        ("ou", ["AW"]), ("ow", ["AW"]), ("oi", ["OY"]), ("oy", ["OY"]),
        ("er", ["ER"]), ("ar", ["AA", "R"]), ("or", ["AO", "R"]),
        ("au", ["AO"]), ("aw", ["AO"])
    ];
    private static readonly string[] PinyinInitialOrder =
    [
        "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l",
        "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"
    ];
    private static readonly Dictionary<string, string> PinyinInitials = new(StringComparer.Ordinal)
    {
        [""] = "", ["b"] = "B", ["p"] = "P", ["m"] = "M", ["f"] = "F",
        ["d"] = "D", ["t"] = "T", ["n"] = "N", ["l"] = "L", ["g"] = "G",
        ["k"] = "K", ["h"] = "HH", ["j"] = "JH", ["q"] = "CH", ["x"] = "SH",
        ["zh"] = "JH", ["ch"] = "CH", ["sh"] = "SH", ["r"] = "R", ["z"] = "Z",
        ["c"] = "T S", ["s"] = "S", ["y"] = "Y", ["w"] = "W"
    };
    private static readonly HashSet<string> PinyinApicalInitials = new(StringComparer.Ordinal)
        { "z", "c", "s", "zh", "ch", "sh", "r" };
    private static readonly Dictionary<string, string> PinyinFinals = new(StringComparer.Ordinal)
    {
        ["a"] = "AA", ["o"] = "AO", ["e"] = "AH", ["ai"] = "AY", ["ei"] = "EY",
        ["ao"] = "AW", ["ou"] = "OW", ["an"] = "AE N", ["en"] = "AH N",
        ["ang"] = "AA NG", ["eng"] = "AH NG", ["er"] = "ER", ["i"] = "IY",
        ["ia"] = "Y AA", ["ie"] = "Y EH", ["iao"] = "Y AW", ["iu"] = "Y OW",
        ["ian"] = "Y EH N", ["in"] = "IY N", ["iang"] = "Y AA NG",
        ["ing"] = "IY NG", ["iong"] = "Y UH NG", ["u"] = "UW", ["ua"] = "W AA",
        ["uo"] = "W AO", ["uai"] = "W AY", ["ui"] = "W EY", ["uan"] = "W AA N",
        ["un"] = "W AH N", ["uang"] = "W AA NG", ["ueng"] = "W AH NG",
        ["ong"] = "UH NG", ["v"] = "Y UW", ["ve"] = "Y EH", ["ue"] = "Y EH",
        ["van"] = "Y EH N", ["vn"] = "Y UW N"
    };
    private static readonly Dictionary<string, string> SpecialPinyinPronunciations = new(StringComparer.Ordinal)
    {
        ["yi"] = "IY", ["ya"] = "Y AA", ["ye"] = "Y EH", ["yao"] = "Y AW",
        ["you"] = "Y OW", ["yan"] = "Y AE N", ["yang"] = "Y AA NG", ["yin"] = "IY N",
        ["ying"] = "IY NG", ["yong"] = "Y UH NG", ["yu"] = "Y UW", ["yue"] = "Y EH",
        ["yuan"] = "Y EH N", ["yun"] = "Y UW N", ["wu"] = "UW", ["wa"] = "W AA",
        ["wo"] = "W AO", ["wai"] = "W AY", ["wei"] = "W EY", ["wan"] = "W AA N",
        ["wang"] = "W AA NG", ["wen"] = "W AH N", ["weng"] = "W AH NG"
    };
}

internal sealed record PersonalLexiconResources(
    string Model,
    string Vocabulary,
    string Pinyin,
    string EnglishPronunciations)
{
    public const string DirectoryName = "distilbert-base-multilingual-cased-onnx-int8";

    public static PersonalLexiconResources? Resolve()
    {
        var candidates = new List<string>();
        string? environment = Environment.GetEnvironmentVariable("GUGUTALK_SEMANTIC_MODEL_DIR");
        if (!string.IsNullOrWhiteSpace(environment))
            candidates.Add(Environment.ExpandEnvironmentVariables(environment));
        candidates.Add(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "GuGuTalk", "models", DirectoryName));
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "models", DirectoryName));

        foreach (string directory in candidates)
        {
            string model = Path.Combine(directory, "model.int8.onnx");
            string vocabulary = Path.Combine(directory, "vocab.txt");
            string pinyin = Path.Combine(directory, "pinyin.txt");
            string englishPronunciations = Path.Combine(directory, "cmudict.dict");
            if (File.Exists(model) && File.Exists(vocabulary) && File.Exists(pinyin)
                && File.Exists(englishPronunciations))
                return new PersonalLexiconResources(model, vocabulary, pinyin, englishPronunciations);
        }
        return null;
    }
}

internal sealed record MaskedLanguageModelInput(
    long[] InputIds,
    long[] AttentionMask,
    long[] TargetPositions,
    long[] TargetTokenIds);

internal sealed class WordPieceTokenizer
{
    private readonly Dictionary<string, long> _vocabulary;
    private readonly long _unknownTokenId;
    private readonly long _classificationTokenId;
    private readonly long _separatorTokenId;
    private readonly long _maskTokenId;

    public WordPieceTokenizer(string vocabularyPath)
    {
        _vocabulary = [];
        long index = 0;
        foreach (string token in File.ReadLines(vocabularyPath))
        {
            if (token.Length > 0) _vocabulary[token] = index;
            index++;
        }
        if (!_vocabulary.TryGetValue("[UNK]", out _unknownTokenId)
            || !_vocabulary.TryGetValue("[CLS]", out _classificationTokenId)
            || !_vocabulary.TryGetValue("[SEP]", out _separatorTokenId)
            || !_vocabulary.TryGetValue("[MASK]", out _maskTokenId))
            throw new InvalidDataException("Personal lexicon vocabulary is invalid.");
    }

    public MaskedLanguageModelInput? MakeMaskedInput(string prefix, string target, string suffix)
    {
        long[] targetIds = Tokenize(target);
        if (targetIds.Length is 0 or > 16) return null;
        long[] prefixIds = Tokenize(prefix);
        long[] suffixIds = Tokenize(suffix);
        int contextBudget = 96 - 2 - targetIds.Length;
        int leftCount = Math.Min(prefixIds.Length, contextBudget / 2);
        int rightCount = Math.Min(suffixIds.Length, contextBudget - leftCount);
        int remaining = contextBudget - leftCount - rightCount;
        int extraLeft = Math.Min(prefixIds.Length - leftCount, remaining);
        leftCount += extraLeft;
        remaining -= extraLeft;
        rightCount += Math.Min(suffixIds.Length - rightCount, remaining);

        var ids = new List<long>(96) { _classificationTokenId };
        ids.AddRange(prefixIds.Skip(prefixIds.Length - leftCount));
        int firstTargetPosition = ids.Count;
        ids.AddRange(Enumerable.Repeat(_maskTokenId, targetIds.Length));
        ids.AddRange(suffixIds.Take(rightCount));
        ids.Add(_separatorTokenId);
        return new MaskedLanguageModelInput(
            ids.ToArray(),
            Enumerable.Repeat(1L, ids.Count).ToArray(),
            Enumerable.Range(firstTargetPosition, targetIds.Length).Select(value => (long)value).ToArray(),
            targetIds);
    }

    private long[] Tokenize(string text) => BasicTokens(text).SelectMany(WordPiece).ToArray();

    private static IEnumerable<string> BasicTokens(string text)
    {
        var result = new List<string>();
        var current = new StringBuilder();
        void Flush()
        {
            if (current.Length == 0) return;
            result.Add(current.ToString());
            current.Clear();
        }

        foreach (Rune rune in text.EnumerateRunes())
        {
            UnicodeCategory category = Rune.GetUnicodeCategory(rune);
            if (Rune.IsWhiteSpace(rune))
            {
                Flush();
            }
            else if (IsCjk(rune.Value) || category.ToString().Contains("Punctuation")
                     || category.ToString().Contains("Symbol"))
            {
                Flush();
                result.Add(rune.ToString());
            }
            else
            {
                current.Append(rune.ToString());
            }
        }
        Flush();
        return result;
    }

    private IEnumerable<long> WordPiece(string token)
    {
        if (_vocabulary.TryGetValue(token, out long exact)) return [exact];
        var runes = token.EnumerateRunes().ToArray();
        if (runes.Length > 100) return [_unknownTokenId];
        var result = new List<long>();
        int start = 0;
        while (start < runes.Length)
        {
            int end = runes.Length;
            long match = -1;
            while (start < end)
            {
                string piece = string.Concat(runes[start..end].Select(rune => rune.ToString()));
                if (start > 0) piece = "##" + piece;
                if (_vocabulary.TryGetValue(piece, out match)) break;
                end--;
            }
            if (match < 0) return [_unknownTokenId];
            result.Add(match);
            start = end;
        }
        return result;
    }

    private static bool IsCjk(int value) =>
        value is >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF
            or >= 0xF900 and <= 0xFAFF
            or >= 0x20000 and <= 0x323AF;
}

public sealed class PersonalLexiconCorrector : IDisposable
{
    private static readonly ILogger Logger = Log.ForContext<PersonalLexiconCorrector>();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private PersonalLexiconResources? _resources;
    private PhoneticCandidateFinder? _candidateFinder;
    private WordPieceTokenizer? _tokenizer;
    private InferenceSession? _session;
    private bool _didAttemptResourceLoad;

    public async Task<string> CorrectAsync(
        string text,
        IReadOnlyList<PersonalTerm> terms,
        CancellationToken cancellationToken = default)
    {
        if (text.Length == 0 || terms.Count == 0) return text;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => CorrectCore(text, terms, cancellationToken), cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Logger.Warning(ex, "Personal lexicon correction skipped");
            return text;
        }
        finally
        {
            _gate.Release();
        }
    }

    private string CorrectCore(string text, IReadOnlyList<PersonalTerm> terms, CancellationToken cancellationToken)
    {
        if (!LoadLightweightResources() || _resources is null || _candidateFinder is null) return text;
        var candidates = _candidateFinder.Find(text, terms);
        if (candidates.Count == 0) return text;
        var elements = text.EnumerateRunes().Select(rune => rune.ToString()).ToList();
        var accepted = new List<(PhoneticCandidate Candidate, double Combined)>();

        foreach (var candidate in candidates)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (ShouldHonorPersonalSpelling(candidate))
            {
                accepted.Add((candidate, 3.2 - candidate.PhoneticDistance * 3.0));
                continue;
            }

            _tokenizer ??= new WordPieceTokenizer(_resources.Vocabulary);
            _session ??= CreateSession(_resources.Model);
            string prefix = string.Concat(elements.Take(candidate.Start));
            string suffix = string.Concat(elements.Skip(candidate.Start + candidate.Length));
            var originalInput = _tokenizer.MakeMaskedInput(prefix, candidate.Original, suffix);
            var replacementInput = _tokenizer.MakeMaskedInput(prefix, candidate.Replacement, suffix);
            if (originalInput is null || replacementInput is null) continue;
            double originalScore = Score(originalInput);
            double replacementScore = Score(replacementInput);
            double semanticDelta = replacementScore - originalScore;
            double prior = 2.6 - candidate.PhoneticDistance * 3.0;
            double combined = semanticDelta + prior;
            if (semanticDelta >= -4.5 && combined >= 0)
                accepted.Add((candidate, combined));
        }

        var selected = SelectNonOverlapping(accepted);
        foreach (var candidate in selected.OrderByDescending(value => value.Start))
        {
            elements.RemoveRange(candidate.Start, candidate.Length);
            elements.InsertRange(candidate.Start,
                candidate.Replacement.EnumerateRunes().Select(rune => rune.ToString()));
        }
        return string.Concat(elements);
    }

    private static bool ShouldHonorPersonalSpelling(PhoneticCandidate candidate)
    {
        // A masked LM often underrates rare names and code-like spellings even when pronunciation is strong.
        if (candidate.PhoneticDistance > 0.30) return false;
        string replacement = string.Concat(candidate.Replacement.ToLowerInvariant()
            .Where(character => !char.IsWhiteSpace(character)));
        string original = string.Concat(candidate.Original.ToLowerInvariant()
            .Where(character => !char.IsWhiteSpace(character)));
        bool hasFormattingSensitiveCharacter = replacement.Any(character =>
            character <= 0x7F && (char.IsLetterOrDigit(character)
                || char.IsPunctuation(character)
                || char.IsSymbol(character)));
        if (hasFormattingSensitiveCharacter) return true;
        if (replacement.Intersect(original).Any()) return true;
        return candidate.PhoneticDistance <= 0.08
            && replacement.EnumerateRunes().Count() >= 3
            && original.EnumerateRunes().Count() >= 3;
    }

    private bool LoadLightweightResources()
    {
        if (_resources is not null && _candidateFinder is not null) return true;
        if (_didAttemptResourceLoad) return false;
        _didAttemptResourceLoad = true;
        _resources = PersonalLexiconResources.Resolve();
        if (_resources is null)
        {
            Logger.Warning("Personal lexicon resources are unavailable; semantic correction is disabled");
            return false;
        }
        _candidateFinder = new PhoneticCandidateFinder(
            File.ReadAllText(_resources.Pinyin),
            File.ReadAllText(_resources.EnglishPronunciations));
        return true;
    }

    private static InferenceSession CreateSession(string modelPath)
    {
        using var options = new SessionOptions
        {
            IntraOpNumThreads = 1,
            InterOpNumThreads = 1,
            GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL
        };
        return new InferenceSession(modelPath, options);
    }

    private double Score(MaskedLanguageModelInput input)
    {
        var inputIds = new DenseTensor<long>(
            input.InputIds.AsMemory(), new[] { 1, input.InputIds.Length });
        var attentionMask = new DenseTensor<long>(
            input.AttentionMask.AsMemory(), new[] { 1, input.AttentionMask.Length });
        using var results = _session!.Run(new[]
        {
            NamedOnnxValue.CreateFromTensor("input_ids", inputIds),
            NamedOnnxValue.CreateFromTensor("attention_mask", attentionMask)
        });
        var tensor = results.First(value => value.Name == "logits").AsTensor<float>();
        if (tensor.Dimensions.Length != 3 || tensor.Dimensions[0] != 1
            || tensor.Dimensions[1] != input.InputIds.Length)
            throw new InvalidDataException("Semantic model returned an unexpected logits shape.");
        int vocabularySize = tensor.Dimensions[2];
        float[] logits = tensor.ToArray();
        double total = 0;
        for (int targetIndex = 0; targetIndex < input.TargetTokenIds.Length; targetIndex++)
        {
            int position = checked((int)input.TargetPositions[targetIndex]);
            int tokenId = checked((int)input.TargetTokenIds[targetIndex]);
            if (position < 0 || position >= input.InputIds.Length || tokenId < 0 || tokenId >= vocabularySize)
                throw new InvalidDataException("Semantic target token is outside the logits tensor.");
            int offset = position * vocabularySize;
            float maximum = logits[offset];
            for (int index = 1; index < vocabularySize; index++)
                maximum = Math.Max(maximum, logits[offset + index]);
            double exponentialSum = 0;
            for (int index = 0; index < vocabularySize; index++)
                exponentialSum += Math.Exp(logits[offset + index] - maximum);
            total += logits[offset + tokenId] - maximum - Math.Log(exponentialSum);
        }
        return total / input.TargetTokenIds.Length;
    }

    private static IReadOnlyList<PhoneticCandidate> SelectNonOverlapping(
        IEnumerable<(PhoneticCandidate Candidate, double Combined)> input)
    {
        var selected = new List<PhoneticCandidate>();
        foreach (var item in input.OrderBy(value => value.Candidate.PhoneticDistance)
                     .ThenByDescending(value => value.Combined)
                     .ThenByDescending(value => value.Candidate.Length))
        {
            int start = item.Candidate.Start;
            int end = start + item.Candidate.Length;
            if (selected.All(existing => end <= existing.Start
                    || start >= existing.Start + existing.Length))
                selected.Add(item.Candidate);
        }
        return selected;
    }

    public void Dispose()
    {
        _session?.Dispose();
        _gate.Dispose();
    }
}
