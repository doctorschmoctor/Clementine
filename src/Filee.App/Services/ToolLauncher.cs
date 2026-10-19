// Opens the file tools: the native windows of the macOS helper bundled at Filee.app/Contents/Helpers.

using System.Diagnostics;
using Filee.Core.Presets;

namespace Filee.App.Services;

public static class ToolLauncher
{
    /// <summary>Name of the helper app inside Filee.app/Contents/Helpers.</summary>
    public const string HelperBundle = "Clementine Tools.app";
    private const string HelperExecutable = "ClementineTools";

    /// <summary>
    /// The helper's executable, or null when there is none (not macOS, or a build without it). The environment
    /// variable CLEMENTINE_TOOLS_HELPER points at another one, for development.
    /// </summary>
    public static string? HelperPath
    {
        get
        {
            if (Environment.GetEnvironmentVariable("CLEMENTINE_TOOLS_HELPER") is { Length: > 0 } custom && File.Exists(custom))
                return custom;
            if (!OperatingSystem.IsMacOS())
                return null;
            // Filee.app/Contents/MacOS/ → Filee.app/Contents/Helpers/Clementine Tools.app/Contents/MacOS/ClementineTools
            var path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Helpers", HelperBundle, "Contents", "MacOS", HelperExecutable));
            return File.Exists(path) ? path : null;
        }
    }

    public static bool IsAvailable => HelperPath is not null;

    /// <summary>Opens the window of <paramref name="toolId"/> with <paramref name="files"/>. False when it couldn't start.</summary>
    public static bool Launch(string toolId, IReadOnlyList<string> files)
    {
        if (HelperPath is not { } helper || ToolCatalog.Find(toolId) is null || files.Count == 0)
            return false;
        var start = new ProcessStartInfo(helper) { UseShellExecute = false };
        start.ArgumentList.Add("--tool");
        start.ArgumentList.Add(toolId);
        foreach (var file in files)
            start.ArgumentList.Add(file);
        try
        {
            using var process = Process.Start(start);
            return process is not null;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
