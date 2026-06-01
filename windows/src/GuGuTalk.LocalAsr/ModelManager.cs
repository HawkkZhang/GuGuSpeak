namespace GuGuTalk.LocalAsr;

public static class ModelManager
{
    public const string DefaultModelName = "sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30";

    // Path next to the executable (used when WiX bundles models with the install)
    private static string BundledModelsRoot => Path.Combine(
        AppContext.BaseDirectory, "models");

    // Per-user override (model downloaded by app or manually placed by user)
    private static string UserModelsRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "GuGuTalk", "models");

    /// <summary>
    /// Returns the directory containing tokens.txt + onnx files.
    /// Search order: user override → bundled (next to exe).
    /// </summary>
    public static string GetModelDirectory()
    {
        var userPath = ResolveModelDir(UserModelsRoot);
        if (userPath is not null) return userPath;

        var bundledPath = ResolveModelDir(BundledModelsRoot);
        if (bundledPath is not null) return bundledPath;

        // Default to user dir (for download target)
        return Path.Combine(UserModelsRoot, DefaultModelName);
    }

    public static bool IsModelAvailable() => GetTokensPath() is not null;

    public static string? GetTokensPath()
    {
        foreach (var root in new[] { UserModelsRoot, BundledModelsRoot })
        {
            var dir = ResolveModelDir(root);
            if (dir is null) continue;

            var tokens = Path.Combine(dir, "tokens.txt");
            if (File.Exists(tokens)) return tokens;
        }
        return null;
    }

    public static void EnsureUserModelDirectory()
    {
        Directory.CreateDirectory(UserModelsRoot);
    }

    /// <summary>
    /// Looks for tokens.txt directly inside `root`, or one level deep in named subdirs
    /// (e.g. models/sherpa-onnx-streaming-zipformer-zh-14M-.../tokens.txt).
    /// Returns the directory that contains tokens.txt, or null if not found.
    /// If multiple subdirs exist, prioritizes directories with "2025" or "int8-2025" in the name.
    /// </summary>
    private static string? ResolveModelDir(string root)
    {
        if (!Directory.Exists(root)) return null;

        // Direct hit: tokens.txt at root
        if (File.Exists(Path.Combine(root, "tokens.txt"))) return root;

        // One level deep: collect all subdirs with tokens.txt
        try
        {
            var candidates = new List<string>();
            foreach (var sub in Directory.EnumerateDirectories(root))
            {
                if (File.Exists(Path.Combine(sub, "tokens.txt")))
                    candidates.Add(sub);
            }

            if (candidates.Count == 0) return null;

            // Prioritize directories with "2025" or "int8-2025" in the name
            var preferred = candidates.FirstOrDefault(c =>
                Path.GetFileName(c).Contains("2025", StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(c).Contains("int8-2025", StringComparison.OrdinalIgnoreCase));

            return preferred ?? candidates[0];
        }
        catch { }

        return null;
    }
}
