// Merge PDFs: several PDFs into one, in an order you choose (it starts in the order they were selected in Finder).

import PDFKit
import SwiftUI

struct MergePdfsTool: View {
    @EnvironmentObject var context: ToolContext
    @State private var files: [URL] = []
    @State private var selection: URL?

    var body: some View {
        ToolShell(saveTitle: "Merge", canSave: files.count >= 1, onSave: save) {
            if let url = selection ?? files.first, let doc = PDFDocument(url: url) {
                PDFKitView(document: doc).id(url)
            } else {
                Placeholder(text: "Add PDFs to merge")
            }
        } controls: {
            ControlSection("Order") {
                List(selection: $selection) {
                    ForEach(files, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc.richtext")
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text("\(PDFDocument(url: url)?.pageCount ?? 0) pages").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(url)
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 260)
                HStack {
                    Button("Add…") { files += FilePicker.pick(types: [.pdf]) }
                    Button("Remove") { files.removeAll { $0 == selection }; selection = nil }.disabled(selection == nil)
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection == nil)
                    Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection == nil)
                }
                Text("Drag to reorder. \(files.reduce(0) { $0 + (PDFDocument(url: $1)?.pageCount ?? 0) }) pages in total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if files.isEmpty { files = context.files } }
    }

    private func move(_ delta: Int) {
        guard let selection, let i = files.firstIndex(of: selection) else { return }
        let j = min(max(0, i + delta), files.count - 1)
        files.swapAt(i, j)
    }

    private func save() {
        let files = self.files
        context.save { _ in
            let merged = PDFDocument()
            for url in files {
                guard let doc = PDFDocument(url: url) else { throw ToolError("“\(url.lastPathComponent)” couldn't be opened.") }
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            }
            let out = Output.file(for: files[0], suffix: "merged", ext: "pdf")
            guard merged.write(to: out) else { throw ToolError("The merged PDF couldn't be written.") }
            return [out]
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
