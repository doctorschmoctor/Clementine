// Share: AirDrop, Messages, Mail, Notes and every other share service macOS offers for the files, plus copying them
// (as files or as paths), copying or moving them to a folder, opening them with an app, Finder and Terminal.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShareTool: View {
    @EnvironmentObject var context: ToolContext
    @StateObject private var sharer = Sharer()
    @State private var done: String?

    private var services: [NSSharingService] { NSSharingService.sharingServices(forItems: context.files) }

    private var apps: [URL] {
        guard let first = context.files.first else { return [] }
        let all = NSWorkspace.shared.urlsForApplications(toOpen: first)
        let filtered = all.filter { app in context.files.allSatisfy { NSWorkspace.shared.urlsForApplications(toOpen: $0).contains(app) } }
        var seen = Set<String>()
        return filtered.filter { seen.insert($0.deletingPathExtension().lastPathComponent).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let done {
                Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text("SEND").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(services, id: \.title) { service in
                    ActionTile(title: service.menuItemTitle, image: Image(nsImage: service.image)) {
                        sharer.share(context.files, with: service, from: context.window) { ok in if ok { finish("Sent") } }
                    }
                }
                ActionTile(title: "More…", image: Image(systemName: "ellipsis.circle")) { showPicker() }
            }
            Text("FILE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ActionTile(title: "Copy", image: Image(systemName: "doc.on.doc")) { copyFiles() }
                    .keyboardShortcut("c", modifiers: .command)
                ActionTile(title: "Copy path", image: Image(systemName: "link")) { copyPaths() }
                ActionTile(title: "Copy to…", image: Image(systemName: "folder.badge.plus")) { transfer(move: false) }
                ActionTile(title: "Move to…", image: Image(systemName: "folder")) { transfer(move: true) }
                ActionTile(title: "Show in Finder", image: Image(systemName: "magnifyingglass")) {
                    NSWorkspace.shared.activateFileViewerSelecting(context.files)
                    context.close()
                }
                ActionTile(title: "Terminal", image: Image(systemName: "terminal")) { openTerminal() }
                ActionTile(title: "Open with…", image: Image(systemName: "arrow.up.forward.app")) { showOpenWith() }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") { context.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFiles: context.files.map(\.path)) ?? NSWorkspace.shared.icon(for: .data))
                .resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.files.count == 1 ? context.file.lastPathComponent : "\(context.files.count) files")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(formatBytes(context.files.reduce(0) { $0 + fileSize($1) })).foregroundStyle(.secondary)
            }
        }
    }

    private func finish(_ message: String) {
        done = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { context.close() }
    }

    private func showPicker() {
        guard let view = context.window?.contentView else { return }
        let picker = NSSharingServicePicker(items: context.files)
        picker.delegate = sharer
        sharer.onFinish = { ok in if ok { finish("Sent") } }
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// A menu of the apps that open every one of the files, at the pointer.
    private func showOpenWith() {
        let menu = NSMenu()
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(Sharer.openWith(_:)), keyEquivalent: "")
            item.target = sharer
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if apps.isEmpty { menu.addItem(withTitle: "No app opens all of these files", action: nil, keyEquivalent: "") }
        sharer.files = context.files
        sharer.onFinish = { _ in context.close() }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func copyFiles() {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects(context.files as [NSURL])
        finish(context.files.count == 1 ? "Copied — paste it in Finder or an app" : "Copied \(context.files.count) files")
    }

    private func copyPaths() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(context.files.map(\.path).joined(separator: "\n"), forType: .string)
        finish(context.files.count == 1 ? "Path copied" : "Paths copied")
    }

    private func transfer(move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move here" : "Copy here"
        panel.directoryURL = context.file.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var placed: [URL] = []
        do {
            for file in context.files {
                let ext = file.pathExtension
                let target = Output.unique(folder, file.deletingPathExtension().lastPathComponent, ext)
                if move { try FileManager.default.moveItem(at: file, to: target) } else { try FileManager.default.copyItem(at: file, to: target) }
                placed.append(target)
            }
            NSWorkspace.shared.activateFileViewerSelecting(placed)
            context.close()
        } catch {
            Alerts.fail(error.localizedDescription, in: context.window)
        }
    }

    private func openTerminal() {
        let folder = context.file.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        context.close()
    }
}

/// A square button with an icon and a title.
struct ActionTile: View {
    let title: String
    let image: Image
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                image.resizable().scaledToFit().frame(width: 26, height: 26)
                Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

/// Runs share services and reports when they finish.
@MainActor
final class Sharer: NSObject, ObservableObject, NSSharingServiceDelegate, NSSharingServicePickerDelegate {
    var onFinish: ((Bool) -> Void)?
    var files: [URL] = []

    @objc func openWith(_ item: NSMenuItem) {
        guard let app = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        onFinish?(true)
    }
    private weak var window: NSWindow?

    func share(_ items: [URL], with service: NSSharingService, from window: NSWindow?, done: @escaping (Bool) -> Void) {
        self.window = window
        onFinish = done
        service.delegate = self
        service.perform(withItems: items)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in onFinish?(true) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        Task { @MainActor in onFinish?(false) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { window ?? NSApp.keyWindow }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }
}
