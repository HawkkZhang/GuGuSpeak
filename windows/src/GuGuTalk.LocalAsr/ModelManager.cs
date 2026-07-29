namespace GuGuTalk.LocalAsr;

public static class ModelManager
{
    public const string DefaultAsrModelName =
        "sherpa-onnx-streaming-paraformer-bilingual-zh-en";
    public const string DefaultPunctuationModelName =
        "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8";

    private static string BundledModelsRoot => Path.Combine(AppContext.BaseDirectory, "models");

    private static string UserModelsRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "GuGuTalk", "models");

    public static bool IsModelAvailable() =>
        GetTokensPath() is not null
        && GetEncoderPath() is not null
        && GetDecoderPath() is not null
        && GetPunctuationModelPath() is not null;

    public static string GetAsrModelDirectory() =>
        ResolveAsrModelDirectoryFromCandidates()
        ?? Path.Combine(UserModelsRoot, DefaultAsrModelName);

    public static string GetPunctuationModelDirectory() =>
        ResolvePunctuationModelDirectoryFromCandidates()
        ?? Path.Combine(UserModelsRoot, DefaultPunctuationModelName);

    public static string? GetTokensPath() => GetAsrFile("tokens.txt");

    public static string? GetEncoderPath() =>
        GetAsrFile("encoder.int8.onnx") ?? GetAsrFile("encoder.onnx");

    public static string? GetDecoderPath() =>
        GetAsrFile("decoder.int8.onnx") ?? GetAsrFile("decoder.onnx");

    public static string? GetPunctuationModelPath()
    {
        var directory = ResolvePunctuationModelDirectoryFromCandidates();
        if (directory is null) return null;

        var int8Model = Path.Combine(directory, "model.int8.onnx");
        if (File.Exists(int8Model)) return int8Model;

        var fp32Model = Path.Combine(directory, "model.onnx");
        return File.Exists(fp32Model) ? fp32Model : null;
    }

    public static void EnsureUserModelDirectory() => Directory.CreateDirectory(UserModelsRoot);

    private static string? GetAsrFile(string filename)
    {
        var directory = ResolveAsrModelDirectoryFromCandidates();
        if (directory is null) return null;
        var path = Path.Combine(directory, filename);
        return File.Exists(path) ? path : null;
    }

    private static string? ResolveAsrModelDirectoryFromCandidates()
    {
        foreach (var root in AsrCandidateRoots())
        {
            var directory = ResolveAsrModelDirectory(root);
            if (directory is not null) return directory;
        }
        return null;
    }

    private static string? ResolvePunctuationModelDirectoryFromCandidates()
    {
        var punctuationOverride = EnvironmentDirectory("GUGUTALK_LOCAL_PUNCTUATION_MODEL_DIR");
        if (punctuationOverride is not null)
        {
            var directory = ResolvePunctuationModelDirectory(punctuationOverride, allowDirect: true);
            if (directory is not null) return directory;
        }

        foreach (var root in SharedCandidateRoots())
        {
            var directory = ResolvePunctuationModelDirectory(root, allowDirect: false);
            if (directory is not null) return directory;
        }

        var asrOverride = EnvironmentDirectory("GUGUTALK_LOCAL_ASR_MODEL_DIR");
        return asrOverride is null
            ? null
            : ResolvePunctuationModelDirectory(asrOverride, allowDirect: false);
    }

    private static IEnumerable<string> AsrCandidateRoots()
    {
        var environment = EnvironmentDirectory("GUGUTALK_LOCAL_ASR_MODEL_DIR");
        if (environment is not null) yield return environment;
        foreach (var root in SharedCandidateRoots()) yield return root;
    }

    private static IEnumerable<string> SharedCandidateRoots()
    {
        yield return UserModelsRoot;
        yield return BundledModelsRoot;
    }

    private static string? EnvironmentDirectory(string variableName)
    {
        var value = Environment.GetEnvironmentVariable(variableName);
        return string.IsNullOrWhiteSpace(value)
            ? null
            : Environment.ExpandEnvironmentVariables(value);
    }

    private static string? ResolveAsrModelDirectory(string root)
    {
        if (!Directory.Exists(root)) return null;
        if (IsAsrModelDirectory(root)) return root;

        var candidates = EnumerateChildDirectories(root)
            .Where(IsAsrModelDirectory)
            .ToList();
        return candidates.FirstOrDefault(path =>
                   string.Equals(Path.GetFileName(path), DefaultAsrModelName, StringComparison.OrdinalIgnoreCase))
               ?? candidates.FirstOrDefault(path =>
                   Path.GetFileName(path).Contains("paraformer", StringComparison.OrdinalIgnoreCase))
               ?? candidates.FirstOrDefault();
    }

    private static string? ResolvePunctuationModelDirectory(string root, bool allowDirect)
    {
        if (!Directory.Exists(root)) return null;
        if (allowDirect && IsPunctuationModelDirectory(root)) return root;

        var candidates = EnumerateChildDirectories(root)
            .Where(path =>
                string.Equals(Path.GetFileName(path), DefaultPunctuationModelName, StringComparison.OrdinalIgnoreCase)
                || Path.GetFileName(path).Contains("punct", StringComparison.OrdinalIgnoreCase))
            .Where(IsPunctuationModelDirectory)
            .ToList();
        return candidates.FirstOrDefault(path =>
                   string.Equals(Path.GetFileName(path), DefaultPunctuationModelName, StringComparison.OrdinalIgnoreCase))
               ?? candidates.FirstOrDefault();
    }

    private static IEnumerable<string> EnumerateChildDirectories(string root)
    {
        try
        {
            return Directory.EnumerateDirectories(root).ToArray();
        }
        catch
        {
            return [];
        }
    }

    private static bool IsAsrModelDirectory(string directory)
    {
        if (!File.Exists(Path.Combine(directory, "tokens.txt"))) return false;
        var hasEncoder = File.Exists(Path.Combine(directory, "encoder.int8.onnx"))
                         || File.Exists(Path.Combine(directory, "encoder.onnx"));
        var hasDecoder = File.Exists(Path.Combine(directory, "decoder.int8.onnx"))
                         || File.Exists(Path.Combine(directory, "decoder.onnx"));
        return hasEncoder && hasDecoder;
    }

    private static bool IsPunctuationModelDirectory(string directory) =>
        File.Exists(Path.Combine(directory, "model.int8.onnx"))
        || File.Exists(Path.Combine(directory, "model.onnx"));
}
