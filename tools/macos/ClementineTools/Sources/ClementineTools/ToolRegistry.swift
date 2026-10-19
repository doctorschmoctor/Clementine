// Every tool the helper has, by the id Filee passes (src/Filee.Core/Presets/ToolCatalog.cs).

import SwiftUI

enum ToolRegistry {
    static let all: [ToolDefinition] = [
        ToolDefinition(id: "compress", title: "Compress", size: NSSize(width: 960, height: 640)) { _ in AnyView(CompressTool()) },
        ToolDefinition(id: "merge-pdfs", title: "Merge PDFs") { _ in AnyView(MergePdfsTool()) },
        ToolDefinition(id: "video-speed", title: "Change Video Speed") { _ in AnyView(VideoSpeedTool()) },
        ToolDefinition(id: "audio-channels", title: "Convert Audio Channels", size: NSSize(width: 980, height: 560)) { _ in AnyView(AudioChannelsTool()) },
        ToolDefinition(id: "normalize-audio", title: "Normalize Volume", size: NSSize(width: 1040, height: 640)) { _ in AnyView(NormalizeAudioTool()) },
        ToolDefinition(id: "join-videos", title: "Join Videos") { _ in AnyView(JoinVideosTool()) },
        ToolDefinition(id: "split-video", title: "Split Video") { _ in AnyView(SplitVideoTool()) },
        ToolDefinition(id: "crop-image", title: "Crop Image") { _ in AnyView(CropImageTool()) },
        ToolDefinition(id: "background", title: "Add a Background") { _ in AnyView(BackgroundTool()) },
        ToolDefinition(id: "collage", title: "Create a Collage") { _ in AnyView(CollageTool()) },
        ToolDefinition(id: "redact-image", title: "Redact Photo") { _ in AnyView(RedactImageTool()) },
        ToolDefinition(id: "annotate", title: "Annotate", size: NSSize(width: 1180, height: 780)) { _ in AnyView(AnnotateTool()) },
        ToolDefinition(id: "edit-photo", title: "Edit Photo", size: NSSize(width: 1180, height: 780)) { _ in AnyView(EditPhotoTool()) },
        ToolDefinition(id: "trim-video", title: "Trim Video") { _ in AnyView(TrimVideoTool()) },
        ToolDefinition(id: "crop-video", title: "Crop Video") { _ in AnyView(CropVideoTool()) },
        ToolDefinition(id: "video-frames", title: "Save Video Frames") { _ in AnyView(VideoFramesTool()) },
        ToolDefinition(id: "redact-video", title: "Redact Video") { _ in AnyView(RedactVideoTool()) },
        ToolDefinition(id: "trim-audio", title: "Trim Audio", size: NSSize(width: 1040, height: 560)) { _ in AnyView(TrimAudioTool()) },
        ToolDefinition(id: "bleep-audio", title: "Bleep Audio", size: NSSize(width: 1080, height: 600)) { _ in AnyView(BleepAudioTool()) },
        ToolDefinition(id: "audio-visualizer", title: "Audio Visualizer") { _ in AnyView(VisualizerTool()) },
        ToolDefinition(id: "metadata", title: "Edit Metadata", size: NSSize(width: 1000, height: 700)) { _ in AnyView(MetadataTool()) },
        ToolDefinition(id: "organize-pdf", title: "Organize PDF Pages") { _ in AnyView(OrganizePdfTool()) },
        ToolDefinition(id: "share", title: "Share", size: NSSize(width: 480, height: 430), resizable: false) { _ in AnyView(ShareTool()) },
    ]

    static func tool(_ id: String) -> ToolDefinition? { all.first { $0.id == id } }
}
