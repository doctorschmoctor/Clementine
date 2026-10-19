// The window every tool shares: a preview on the left, controls on the right, and Cancel / Save at the bottom.
// Saving always writes new files next to the originals, which are never changed.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State shared by a tool's window: its files, and the save that is running.
@MainActor
final class ToolContext: ObservableObject {
    let files: [URL]
    let title: String
    weak var window: NSWindow?
    /// Testing (--auto-save): Save is pressed automatically, new files are printed instead of shown, errors exit.
    static var isAutomated = false

    @Published var isBusy = false
    /// 0...1 while saving, when the work reports it.
    @Published var progress: Double?
    @Published var status: String?

    init(files: [URL], title: String) {
        self.files = files
        self.title = title
    }

    var file: URL { files[0] }

    func close() { window?.close() }

    /// Runs a save: shows progress, then selects the new files in Finder and closes; an error is shown and the window
    /// stays open.
    func save(_ work: @escaping (ToolContext) async throws -> [URL]) {
        guard !isBusy else { return }
        isBusy = true
        progress = nil
        status = "Saving…"
        Task { @MainActor in
            do {
                let outputs = try await work(self)
                isBusy = false
                status = nil
                if Self.isAutomated {
                    print(outputs.map(\.path).joined(separator: "\n"))
                } else if !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
                close()
            } catch is CancellationError {
                isBusy = false
                status = nil
            } catch {
                isBusy = false
                status = nil
                if Self.isAutomated {
                    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
                Alerts.fail(error.localizedDescription, in: window)
            }
        }
    }
}

enum Alerts {
    @MainActor
    static func fail(_ message: String, in window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Something went wrong"
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// A plain error with a message for the user.
struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Where new files go: next to the original, "name_suffix.ext", numbered when that exists.
enum Output {
    static func file(for source: URL, suffix: String, ext: String? = nil, folder: URL? = nil) -> URL {
        let directory = folder ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = ext ?? source.pathExtension
        return unique(directory, base + (suffix.isEmpty ? "" : "_" + suffix), ext)
    }

    /// A new folder next to <source>, "name_suffix", for tools that save many files.
    static func folder(for source: URL, suffix: String) throws -> URL {
        let directory = source.deletingLastPathComponent()
        let url = unique(directory, source.deletingPathExtension().lastPathComponent + "_" + suffix, "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(_ directory: URL, _ name: String, _ ext: String) -> URL {
        func make(_ n: Int) -> URL {
            let stem = n == 1 ? name : "\(name) \(n)"
            return ext.isEmpty ? directory.appendingPathComponent(stem, isDirectory: true)
                : directory.appendingPathComponent(stem).appendingPathExtension(ext)
        }
        var n = 1
        while FileManager.default.fileExists(atPath: make(n).path) { n += 1 }
        return make(n)
    }

    static func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clementine-" + UUID().uuidString)
            .appendingPathExtension(ext)
    }
}

/// The shared layout. <preview> fills the left, <controls> scroll in the sidebar.
struct ToolShell<Preview: View, Controls: View>: View {
    @EnvironmentObject var context: ToolContext
    var saveTitle = "Save"
    var canSave = true
    var sidebarWidth: CGFloat = 300
    let onSave: () -> Void
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        controls()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: sidebarWidth)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            HStack(spacing: 12) {
                if context.isBusy {
                    if let progress = context.progress {
                        ProgressView(value: progress).frame(width: 160)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status = context.status {
                    Text(status).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { context.close() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || context.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clementineAutoSave)) { _ in
            if canSave && !context.isBusy { onSave() } else {
                FileHandle.standardError.write("error: Save isn't available\n".data(using: .utf8)!)
                exit(3)
            }
        }
    }
}

/// A titled group of controls in the sidebar.
struct ControlSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// A slider with its label and value.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

/// A number field bound to a Double, with a label.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var width: CGFloat = 80

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
        }
    }
}

/// An empty preview area with a message.
struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Picks files with an open panel.
@MainActor
enum FilePicker {
    static func pick(types: [UTType], multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }
}

extension Notification.Name {
    static let clementineAutoSave = Notification.Name("ClementineAutoSave")
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
}
