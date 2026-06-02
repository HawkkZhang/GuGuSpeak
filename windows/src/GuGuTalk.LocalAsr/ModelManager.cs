namespace GuGuTalk.LocalAsr;

public static class ModelManager
{
    public const string DefaultModelName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17";

    // Path next to the executable (used when WiX bundles models with the install)
    private static string BundledModelsRoot => Path.Combine(
        AppContext.BaseDirectory, "models");

    // Per-user override (model downloaded by app or manually placed by user)
    private static string UserModelsRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "GuGuTalk", "models");

    private static string? EnvironmentModelDir
    {
        get
        {
            var value = Environment.GetEnvironmentVariable("GUGUTALK_LOCAL_ASR_MODEL_DIR");
            return string.IsNullOrWhiteSpace(value) ? null : Environment.ExpandEnvironmentVariables(value);
        }
    }

    /// <summary>
    /// Returns the directory containing tokens.txt + onnx files. Search order:
    /// explicit env override -> user override -> bundled (next to exe).
    /// </summary>
    public static string GetModelDirectory()
    {
        if (EnvironmentModelDir is { } envDir)
        {
            var envPath = ResolveModelDir(envDir);
            if (envPath is not null) return envPath;
        }

        var userPath = ResolveModelDir(UserModelsRoot);
        if (userPath is not null) return userPath;

        var bundledPath = ResolveModelDir(BundledModelsRoot);
        if (bundledPath is not null) return bundledPath;

        // Default to user dir (for download target)
        return Path.Combine(UserModelsRoot, DefaultModelName);
    }

    public static bool IsModelAvailable() => GetTokensPath() is not null && GetModelPath() is not null;

    public static string? GetTokensPath()
    {
        foreach (var root in CandidateRoots())
        {
            var dir = ResolveModelDir(root);
            if (dir is null) continue;

            var tokens = Path.Combine(dir, "tokens.txt");
            if (File.Exists(tokens)) return tokens;
        }
        return null;
    }

    public static string? GetModelPath()
    {
        foreach (var root in CandidateRoots())
        {
            var dir = ResolveModelDir(root);
            if (dir is null) continue;

            var int8Model = Path.Combine(dir, "model.int8.onnx");
            if (File.Exists(int8Model)) return int8Model;

            var fp32Model = Path.Combine(dir, "model.onnx");
            if (File.Exists(fp32Model)) return fp32Model;
        }
        return null;
    }

    public static void EnsureUserModelDirectory()
    {
        Directory.CreateDirectory(UserModelsRoot);
    }

    private static IEnumerable<string> CandidateRoots()
    {
        if (EnvironmentModelDir is { } envDir) yield return envDir;
        yield return UserModelsRoot;
        yield return BundledModelsRoot;
    }

    /// <summary>
    /// Looks for tokens.txt + SenseVoice model directly inside `root`, or one
    /// level deep in named subdirs. Returns the directory that contains the
    /// usable model files, or null if not found.
    /// </summary>
    private static string? ResolveModelDir(string root)
    {
        if (!Directory.Exists(root)) return null;

        // Direct hit: tokens.txt + model at root
        if (IsSenseVoiceModelDir(root)) return root;

        // One level deep: collect all subdirs with tokens.txt + model.
        try
        {
            var candidates = new List<string>();
            foreach (var sub in Directory.EnumerateDirectories(root))
            {
                if (IsSenseVoiceModelDir(sub))
                    candidates.Add(sub);
            }

            if (candidates.Count == 0) return null;

            // Prefer the selected SenseVoice bundle if multiple ASR models exist.
            var preferred = candidates.FirstOrDefault(c =>
                string.Equals(Path.GetFileName(c), DefaultModelName, StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(c).Contains("sense-voice", StringComparison.OrdinalIgnoreCase));

            return preferred ?? candidates[0];
        }
        catch { }

        return null;
    }

    private static bool IsSenseVoiceModelDir(string dir)
    {
        if (!File.Exists(Path.Combine(dir, "tokens.txt"))) return false;
        return File.Exists(Path.Combine(dir, "model.int8.onnx")) ||
               File.Exists(Path.Combine(dir, "model.onnx"));
    }
}
