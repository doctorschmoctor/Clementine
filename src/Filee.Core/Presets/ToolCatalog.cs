// The file tools: interactive windows of the bundled macOS helper (Clementine Tools), offered on the donut as tool
// slices (PresetKind.Tool). Dropping files on one opens its window with those files; nothing is converted by Filee.

using Filee.Core.Formats;

namespace Filee.Core.Presets;

/// <summary>One file tool.</summary>
/// <param name="Id">Stable id, passed to the helper as <c>--tool</c>.</param>
/// <param name="NameKey">Localization key of its name (<c>NameKey + ".short"</c> is the name on a group's ring).</param>
/// <param name="Categories">The kinds of file it works on: every dropped file must be one of them.</param>
public sealed record ToolInfo(string Id, string NameKey, IReadOnlyList<FormatCategory> Categories);

/// <summary>Every file tool.</summary>
public static class ToolCatalog
{
    private static readonly FormatCategory[] Media = [FormatCategory.Image, FormatCategory.Video, FormatCategory.Audio, FormatCategory.Pdf];
    private static readonly FormatCategory[] AnyFile = Enum.GetValues<FormatCategory>();

    public static readonly IReadOnlyList<ToolInfo> All =
    [
        // Any file
        new("compress", "tool.compress", Media),
        new("metadata", "tool.metadata", Media),
        // Images
        new("edit-photo", "tool.edit_photo", [FormatCategory.Image]),
        new("annotate", "tool.annotate", [FormatCategory.Image]),
        new("background", "tool.background", [FormatCategory.Image]),
        new("crop-image", "tool.crop_image", [FormatCategory.Image]),
        new("redact-image", "tool.redact_image", [FormatCategory.Image]),
        new("collage", "tool.collage", [FormatCategory.Image]),
        // Video
        new("trim-video", "tool.trim_video", [FormatCategory.Video]),
        new("crop-video", "tool.crop_video", [FormatCategory.Video]),
        new("video-speed", "tool.video_speed", [FormatCategory.Video]),
        new("join-videos", "tool.join_videos", [FormatCategory.Video]),
        new("video-frames", "tool.video_frames", [FormatCategory.Video]),
        new("split-video", "tool.split_video", [FormatCategory.Video]),
        new("redact-video", "tool.redact_video", [FormatCategory.Video]),
        // Audio
        new("normalize-audio", "tool.normalize_audio", [FormatCategory.Audio]),
        new("audio-visualizer", "tool.audio_visualizer", [FormatCategory.Audio]),
        new("trim-audio", "tool.trim_audio", [FormatCategory.Audio]),
        new("audio-channels", "tool.audio_channels", [FormatCategory.Audio]),
        new("bleep-audio", "tool.bleep_audio", [FormatCategory.Audio]),
        // PDF
        new("merge-pdfs", "tool.merge_pdfs", [FormatCategory.Pdf]),
        new("organize-pdf", "tool.organize_pdf", [FormatCategory.Pdf]),
        // Every file: AirDrop, Messages, Mail and the other share services, copy, move, open with...
        new("share", "tool.share", AnyFile),
    ];

    public static ToolInfo? Find(string? id) => id is null ? null : All.FirstOrDefault(t => t.Id == id);

    /// <summary>True when every one of <paramref name="formats"/> is a kind of file the tool works on.</summary>
    public static bool Accepts(ToolInfo tool, IReadOnlyList<FileFormat> formats) =>
        formats.Count > 0 && formats.All(f => tool.Categories.Contains(f.Category));
}
