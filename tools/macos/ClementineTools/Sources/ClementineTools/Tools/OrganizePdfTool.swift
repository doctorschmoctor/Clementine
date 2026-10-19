// Organize PDF pages: reorder, rotate, duplicate or remove pages, seen as thumbnails.

import PDFKit
import SwiftUI

struct OrganizePdfTool: View {
    @EnvironmentObject var context: ToolContext
    @State private var document: PDFDocument?
    @State private var pages: [PageItem] = []
    @State private var selection: Set<UUID> = []
    @State private var dragging: UUID?

    struct PageItem: Identifiable {
        let id = UUID()
        let source: Int
        var rotation: Int = 0
        var thumb: CGImage?
    }

    var body: some View {
        ToolShell(saveTitle: "Save", canSave: !pages.isEmpty, sidebarWidth: 250, onSave: save) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 4) {
                            Group {
                                if let thumb = page.thumb {
                                    Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                                        .rotationEffect(.degrees(Double(page.rotation)))
                                } else { Rectangle().fill(.white) }
                            }
                            .frame(width: 140, height: 180)
                            .background(Color.white)
                            .shadow(radius: 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selection.contains(page.id) ? Color.accentColor : .clear, lineWidth: 3))
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(page.id) }
                        .onDrag { dragging = page.id; return NSItemProvider(object: page.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: PageDrop(target: page.id, pages: $pages, dragging: $dragging))
                    }
                }
                .padding(20)
            }
        } controls: {
            ControlSection("Selected pages") {
                Text(selection.isEmpty ? "Click pages to select them (⌘-click for more)." : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { rotate(-90) } label: { Label("Left", systemImage: "rotate.left") }
                    Button { rotate(90) } label: { Label("Right", systemImage: "rotate.right") }
                }
                .disabled(selection.isEmpty)
                Button("Duplicate") { duplicate() }.disabled(selection.isEmpty)
                Button("Remove") { pages.removeAll { selection.contains($0.id) }; selection = [] }
                    .disabled(selection.isEmpty).keyboardShortcut(.delete, modifiers: [])
                Button("Select all") { selection = Set(pages.map(\.id)) }
            }
            Text("Drag pages to put them in a new order. \(pages.count) pages.").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            guard let doc = PDFDocument(url: context.file) else { return }
            document = doc
            // Thumbnails first, then the list in one go.
            pages = (0..<doc.pageCount).map { i in
                var item = PageItem(source: i)
                if let page = doc.page(at: i) {
                    let bounds = page.bounds(for: .cropBox)
                    let scale = 360 / max(bounds.width, bounds.height)
                    if let ctx = Drawing.context(CGSize(width: bounds.width * scale, height: bounds.height * scale), opaque: true) {
                        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
                        // PDF pages draw bottom-up: undo the context's top-left flip.
                        ctx.translateBy(x: 0, y: bounds.height * scale)
                        ctx.scaleBy(x: scale, y: -scale)
                        page.draw(with: .cropBox, to: ctx)
                        item.thumb = ctx.makeImage()
                    }
                }
                return item
            }
        }
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    private func rotate(_ degrees: Int) {
        for i in pages.indices where selection.contains(pages[i].id) { pages[i].rotation = (pages[i].rotation + degrees + 360) % 360 }
    }

    private func duplicate() {
        var out: [PageItem] = []
        for p in pages {
            out.append(p)
            if selection.contains(p.id) {
                var copy = PageItem(source: p.source, rotation: p.rotation)
                copy.thumb = p.thumb
                out.append(copy)
            }
        }
        pages = out
    }

    private func save() {
        guard let document else { return }
        let pages = self.pages, source = context.file
        context.save { _ in
            let result = PDFDocument()
            for item in pages {
                guard let page = document.page(at: item.source)?.copy() as? PDFPage else { continue }
                page.rotation = (page.rotation + item.rotation) % 360
                result.insert(page, at: result.pageCount)
            }
            let out = Output.file(for: source, suffix: "organized", ext: "pdf")
            guard result.write(to: out) else { throw ToolError("The PDF couldn't be written.") }
            return [out]
        }
    }
}

private struct PageDrop: DropDelegate {
    let target: UUID
    @Binding var pages: [OrganizePdfTool.PageItem]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = pages.firstIndex(where: { $0.id == dragging }), let to = pages.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
