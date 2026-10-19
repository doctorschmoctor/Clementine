// Entry point: `ClementineTools --tool <id> <file>...` opens that tool's window with the files. Quits when it closes.

import AppKit
import SwiftUI

@main
enum Main {
    static var delegate: AppDelegate?

    static func main() {
        var toolId = ""
        var files: [URL] = []
        var snapshot: String?
        var args = Array(CommandLine.arguments.dropFirst())[...]
        while let arg = args.popFirst() {
            if arg == "--tool", let id = args.popFirst() {
                toolId = id
            } else if arg == "--snapshot", let path = args.popFirst() {
                snapshot = path
            } else if arg == "--auto-save" {
                ToolContext.isAutomated = true
            } else if !arg.hasPrefix("-psn_") {
                files.append(URL(fileURLWithPath: arg).standardizedFileURL)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(toolId: toolId, files: files)
        delegate.snapshot = snapshot
        Main.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let toolId: String
    let files: [URL]
    /// Testing: save a picture of the window here after a few seconds, then quit.
    var snapshot: String?
    private var window: NSWindow?

    init(toolId: String, files: [URL]) {
        self.toolId = toolId
        self.files = files
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        guard let tool = ToolRegistry.tool(toolId) else {
            Alerts.fail("Unknown tool “\(toolId)”.")
            NSApp.terminate(nil)
            return
        }
        guard !files.isEmpty || tool.allowsNoFiles else {
            Alerts.fail("No files were given to \(tool.title).")
            NSApp.terminate(nil)
            return
        }
        let context = ToolContext(files: files, title: tool.title)
        let root = tool.makeView(context).environmentObject(context)
        let host = NSHostingController(rootView: AnyView(root))
        let window = NSWindow(contentViewController: host)
        window.title = files.count == 1 ? "\(tool.title) — \(files[0].lastPathComponent)" : tool.title
        window.styleMask = tool.resizable ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(tool.size)
        window.contentMinSize = tool.resizable ? NSSize(width: 760, height: 520) : tool.size
        window.delegate = self
        window.center()
        if tool.resizable { window.setFrameAutosaveName("ClementineTools.\(tool.id)") }
        context.window = window
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if ToolContext.isAutomated {
            // Testing: press Save once the files have loaded; quit when the window closes (or after a minute).
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                NotificationCenter.default.post(name: .clementineAutoSave, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                FileHandle.standardError.write("timed out\n".data(using: .utf8)!)
                exit(2)
            }
        }
        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Clementine Tools", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clementine Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}

/// One tool: its id (as Filee passes it), title and window.
struct ToolDefinition {
    let id: String
    let title: String
    var size = NSSize(width: 1080, height: 720)
    var allowsNoFiles = false
    /// Resizable windows remember their size and place; small fixed ones (Share) don't.
    var resizable = true
    let makeView: (ToolContext) -> AnyView
}
