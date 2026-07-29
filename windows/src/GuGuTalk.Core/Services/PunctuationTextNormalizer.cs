using System.Text;

namespace GuGuTalk.Core.Services;

public static class PunctuationTextNormalizer
{
    public static string NormalizeForMixedChineseEnglish(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;

        var result = new StringBuilder(text.Length);
        char? previousNonWhitespace = null;

        foreach (var character in text)
        {
            var normalized = previousNonWhitespace is { } previous && IsAsciiAlphaNumeric(previous)
                ? ToAsciiPunctuation(character)
                : character;
            result.Append(normalized);
            if (!char.IsWhiteSpace(normalized)) previousNonWhitespace = normalized;
        }

        return result.ToString();
    }

    private static char ToAsciiPunctuation(char character) => character switch
    {
        '，' => ',',
        '。' => '.',
        '！' => '!',
        '？' => '?',
        '；' => ';',
        '：' => ':',
        _ => character
    };

    private static bool IsAsciiAlphaNumeric(char character) =>
        character is >= '0' and <= '9'
            or >= 'A' and <= 'Z'
            or >= 'a' and <= 'z';
}
