// Edit metadata: inspect, change or remove the information inside images, videos, audio and PDFs, searchable and
// grouped by file, track and chapter. Images are rewritten without re-encoding.

import AVFoundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MetaField: Identifiable, Equatable {
    let id = UUID()
    var group: String
    var name: String
    /// Where it is written: an XMP path for images, a key for media and PDFs; nil = can't be edited.
    var path: String?
    var value: String
    var original: String
    var removed = false
}

struct MetadataTool: View {
    @EnvironmentObject var context: ToolContext
    @State private var fields: [MetaField] = []
    @State private var search = ""
    @State private var kind: Kind = .image
    @State private var note: String?
    @State private var loaded = false

    enum Kind { case image, media, pdf }

    private var groups: [String] {
        var seen: [String] = []
        for f in fields where !seen.contains(f.group) { seen.append(f.group) }
        return seen
    }

    private func matches(_ f: MetaField) -> Bool {
        search.isEmpty || f.name.localizedCaseInsensitiveContains(search) || f.value.localizedCaseInsensitiveContains(search)
            || f.group.localizedCaseInsensitiveContains(search)
    }

    private var changed: Bool { fields.contains { $0.removed || $0.value != $0.original } }

    var body: some View {
        ToolShell(saveTitle: "Save copy", canSave: loaded && changed && note == nil, sidebarWidth: 270, onSave: save) {
            VStack(spacing: 0) {
                TextField("Search fields", text: $search).textFieldStyle(.roundedBorder).padding(12)
                if !loaded { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if fields.isEmpty { Placeholder(text: "This file has no metadata.") }
                else {
                    List {
                        ForEach(groups, id: \.self) { group in
                            let rows = fields.indices.filter { fields[$0].group == group && matches(fields[$0]) }
                            if !rows.isEmpty {
                                Section(group) {
                                    ForEach(rows, id: \.self) { i in row(i) }
                                }
                            }
                        }
                    }
                }
            }
        } controls: {
            ControlSection("Remove") {
                if kind != .pdf { Button("Remove location") { removeWhere(isLocation) } }
                if kind == .image { Button("Remove camera and processing data") { removeWhere(isCamera) } }
                Button("Remove everything") { for i in fields.indices where fields[i].path != nil { fields[i].removed = true } }
                Button("Undo all changes") { for i in fields.indices { fields[i].value = fields[i].original; fields[i].removed = false } }
                    .disabled(!changed)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Text("A copy is saved; the original keeps its information. Greyed fields can only be read.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await load() }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(fields[i].name).frame(width: 200, alignment: .leading).foregroundStyle(fields[i].removed ? .secondary : .primary)
                .strikethrough(fields[i].removed)
            if fields[i].path != nil && !fields[i].removed {
                TextField("", text: $fields[i].value).textFieldStyle(.roundedBorder)
            } else {
                Text(fields[i].removed ? "removed" : fields[i].value).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Spacer()
            }
            if fields[i].path != nil {
                Button { fields[i].removed.toggle() } label: {
                    Image(systemName: fields[i].removed ? "arrow.uturn.backward.circle" : "trash")
                }
                .buttonStyle(.borderless)
                .help(fields[i].removed ? "Keep" : "Remove")
            }
        }
    }

    private func removeWhere(_ test: (MetaField) -> Bool) {
        for i in fields.indices where fields[i].path != nil && test(fields[i]) { fields[i].removed = true }
    }

    private func isLocation(_ f: MetaField) -> Bool {
        let p = (f.path ?? "").lowercased()
        return p.contains("gps") || p.contains("location") || p.contains("iso6709") || f.group.lowercased().contains("gps")
    }

    private func isCamera(_ f: MetaField) -> Bool {
        let p = (f.path ?? "")
        let camera = ["tiff:Make", "tiff:Model", "tiff:Software", "exif:LensModel", "exif:LensMake", "exif:LensSpecification",
                      "exif:BodySerialNumber", "exif:LensSerialNumber", "exif:CameraOwnerName", "exifEX:LensModel", "exifEX:LensMake",
                      "exifEX:BodySerialNumber", "exifEX:LensSerialNumber", "exifEX:CameraOwnerName", "exifEX:LensSpecification",
                      "aux:", "xmp:CreatorTool", "photoshop:", "crs:", "MakerNote", "exif:MakerNote"]
        let processing = ["exif:ExposureTime", "exif:FNumber", "exif:ISOSpeedRatings", "exif:ExposureProgram", "exif:MeteringMode",
                          "exif:Flash", "exif:FocalLength", "exif:WhiteBalance", "exif:ExposureBiasValue", "exif:ShutterSpeedValue",
                          "exif:ApertureValue", "exif:BrightnessValue", "exif:SceneType", "exif:SensingMethod", "exif:FocalLenIn35mmFilm",
                          "exif:SubjectArea", "exif:ExposureMode", "exif:DigitalZoomRatio", "exif:SubsecTimeOriginal", "exif:SubsecTimeDigitized"]
        return (camera + processing).contains { p.hasPrefix($0) }
    }

    // MARK: Loading

    private func load() async {
        let url = context.file
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if url.pathExtension.lowercased() == "pdf" {
            kind = .pdf
            loadPdf(url)
        } else if type?.conforms(to: .image) == true {
            kind = .image
            loadImage(url)
        } else {
            kind = .media
            await loadMedia(url)
        }
        loaded = true
    }

    private func loadImage(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        // Basics that aren't tags.
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            fields.append(MetaField(group: "File", name: "Size", path: nil, value: "\(w) × \(h)", original: ""))
            if let model = props[kCGImagePropertyColorModel] as? String {
                fields.append(MetaField(group: "File", name: "Colour", path: nil, value: model, original: ""))
            }
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return }
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let path = path as String
            // Items of a list are shown with the list itself.
            guard !path.contains("["), let value = CGImageMetadataTagCopyValue(tag) else { return true }
            let type = CGImageMetadataTagGetType(tag)
            let isText = type == .string
            let text = Self.describe(value)
            guard !text.isEmpty, type != .structure, type != .arrayOrdered && type != .arrayUnordered || text.count < 200 else { return true }
            let prefix = path.split(separator: ":").first.map(String.init) ?? ""
            let name = (path.split(separator: ":").last.map(String.init) ?? path)
            fields.append(MetaField(group: Self.groupName(prefix, name), name: Self.spaced(name), path: path,
                                    value: text, original: text, removed: false))
            if !isText, let i = fields.indices.last { fields[i].path = path } // still removable; edits are written as text
            return true
        }
    }

    nonisolated static func describe(_ value: CFTypeRef) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let a = value as? [Any] { return a.map { describe($0 as CFTypeRef) }.joined(separator: ", ") }
        if CFGetTypeID(value) == CGImageMetadataTagGetTypeID() {
            let tag = value as! CGImageMetadataTag
            return CGImageMetadataTagCopyValue(tag).map { describe($0) } ?? ""
        }
        return String(describing: value)
    }

    nonisolated static func groupName(_ prefix: String, _ name: String) -> String {
        if name.hasPrefix("GPS") { return "Location" }
        switch prefix {
        case "exif", "exifEX", "aux": return "Camera (EXIF)"
        case "tiff": return "Image (TIFF)"
        case "dc", "photoshop", "Iptc4xmpCore", "iptc": return "Description (IPTC)"
        case "xmp", "xmpMM": return "XMP"
        default: return prefix.isEmpty ? "Other" : prefix
        }
    }

    nonisolated static func spaced(_ name: String) -> String {
        var out = ""
        for (i, c) in name.enumerated() {
            if i > 0, c.isUppercase, let prev = out.last, prev.isLowercase { out.append(" ") }
            out.append(c)
        }
        return out
    }

    private func loadMedia(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let ext = url.pathExtension.lowercased()
        if !["mp4", "m4v", "mov", "m4a", "3gp"].contains(ext) {
            note = "Reading works for this file, but saving changed information needs an MP4, MOV or M4A file."
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        fields.append(MetaField(group: "File", name: "Duration", path: nil, value: Timecode.format(duration), original: ""))
        fields.append(MetaField(group: "File", name: "Size", path: nil, value: formatBytes(fileSize(url)), original: ""))
        let common: [(AVMetadataIdentifier, String)] = [
            (.commonIdentifierTitle, "Title"), (.commonIdentifierArtist, "Artist"), (.commonIdentifierAlbumName, "Album"),
            (.commonIdentifierCreator, "Creator"), (.commonIdentifierDescription, "Description"), (.commonIdentifierCopyrights, "Copyright"),
            (.commonIdentifierCreationDate, "Created"), (.commonIdentifierSoftware, "Software"), (.commonIdentifierType, "Genre"),
        ]
        let all = (try? await asset.load(.metadata)) ?? []
        let commonItems = (try? await asset.load(.commonMetadata)) ?? []
        var used = Set<String>()
        for (identifier, name) in common {
            let item = AVMetadataItem.metadataItems(from: commonItems, filteredByIdentifier: identifier).first
            let value = (try? await item?.load(.stringValue)) ?? nil
            fields.append(MetaField(group: "File", name: name, path: identifier.rawValue, value: value ?? "", original: value ?? ""))
            used.insert(identifier.rawValue)
        }
        for item in all {
            guard let key = item.identifier?.rawValue, !used.contains(key) else { continue }
            let value = (try? await item.load(.stringValue)) ?? nil
            let name = Self.spaced(key.split(separator: "/").last.map(String.init) ?? key)
            fields.append(MetaField(group: "File", name: name, path: key, value: value ?? "(data)", original: value ?? "(data)"))
            used.insert(key)
        }
        // Tracks (read only) and chapters.
        for (n, track) in ((try? await asset.load(.tracks)) ?? []).enumerated() {
            let group = "Track \(n + 1) (\(track.mediaType.rawValue))"
            if let desc = try? await track.load(.formatDescriptions).first {
                let code = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "?"
                fields.append(MetaField(group: group, name: "Codec", path: nil, value: fourCC.trimmingCharacters(in: .whitespaces), original: ""))
            }
            if track.mediaType == .video, let size = try? await Media.displaySize(track) {
                fields.append(MetaField(group: group, name: "Size", path: nil, value: "\(Int(size.width)) × \(Int(size.height))", original: ""))
            }
            if let lang = try? await track.load(.languageCode) {
                fields.append(MetaField(group: group, name: "Language", path: nil, value: lang, original: ""))
            }
            for item in (try? await track.load(.metadata)) ?? [] {
                let value = (try? await item.load(.stringValue)) ?? nil
                fields.append(MetaField(group: group, name: Self.spaced(item.identifier?.rawValue.split(separator: "/").last.map(String.init) ?? "?"),
                                        path: nil, value: value ?? "(data)", original: ""))
            }
        }
        let languages = Locale.preferredLanguages
        if let chapters = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages) {
            for (n, group) in chapters.enumerated() {
                let title = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
                let name = ((try? await title?.load(.stringValue)) ?? nil) ?? "Chapter \(n + 1)"
                fields.append(MetaField(group: "Chapters", name: Timecode.format(group.timeRange.start.seconds), path: nil, value: name, original: ""))
            }
        }
    }

    private func loadPdf(_ url: URL) {
        guard let doc = PDFDocument(url: url) else { return }
        let attrs = doc.documentAttributes ?? [:]
        let keys: [(PDFDocumentAttribute, String)] = [
            (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"), (.keywordsAttribute, "Keywords"),
            (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"), (.creationDateAttribute, "Created"), (.modificationDateAttribute, "Modified"),
        ]
        fields.append(MetaField(group: "File", name: "Pages", path: nil, value: "\(doc.pageCount)", original: ""))
        for (key, name) in keys {
            var value = ""
            if let v = attrs[key] {
                if let d = v as? Date { value = d.formatted(date: .abbreviated, time: .shortened) }
                else if let a = v as? [String] { value = a.joined(separator: ", ") }
                else { value = "\(v)" }
            }
            let editable = key != .creationDateAttribute && key != .modificationDateAttribute
            fields.append(MetaField(group: "Document", name: name, path: editable ? key.rawValue : nil, value: value, original: value))
        }
    }

    // MARK: Saving

    private func save() {
        let fields = self.fields, kind = self.kind, source = context.file
        context.save { ctx in
            switch kind {
            case .image: return [try Self.saveImage(source, fields)]
            case .pdf: return [try Self.savePdf(source, fields)]
            case .media: return [try await Self.saveMedia(source, fields, ctx)]
            }
        }
    }

    static func saveImage(_ url: URL, _ fields: [MetaField]) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw ToolError("The image couldn't be read.")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        for f in fields {
            guard let path = f.path else { continue }
            if f.removed {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            } else if f.value != f.original {
                CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, f.value as CFString)
            }
        }
        let out = Output.file(for: url, suffix: "metadata")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            throw ToolError("macOS can't write this kind of image.")
        }
        // Remove the GPS / EXIF dictionaries too when every tag of them is gone (they're also stored outside XMP).
        var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        if fields.contains(where: { $0.removed && ($0.group == "Location") }) { options[kCGImageMetadataShouldExcludeGPS] = true }
        var error: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) {
            // Formats that can't be copied untouched are written again at top quality.
            try? FileManager.default.removeItem(at: out)
            guard let again = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw ToolError("The image couldn't be written.") }
            CGImageDestinationAddImageAndMetadata(again, try Images.load(url), metadata,
                                                  [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            guard CGImageDestinationFinalize(again) else { throw ToolError("The image couldn't be written.") }
        }
        return out
    }

    static func savePdf(_ url: URL, _ fields: [MetaField]) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ToolError("The PDF couldn't be opened.") }
        var attrs = doc.documentAttributes ?? [:]
        for f in fields {
            guard let path = f.path else { continue }
            let key = PDFDocumentAttribute(rawValue: path)
            if f.removed || f.value.isEmpty { attrs.removeValue(forKey: key) }
            else if key == .keywordsAttribute { attrs[key] = f.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else { attrs[key] = f.value }
        }
        if fields.filter({ $0.path != nil }).allSatisfy(\.removed) {
            attrs.removeValue(forKey: PDFDocumentAttribute.creationDateAttribute)
            attrs.removeValue(forKey: PDFDocumentAttribute.modificationDateAttribute)
        }
        doc.documentAttributes = attrs
        let out = Output.file(for: url, suffix: "metadata", ext: "pdf")
        guard doc.write(to: out) else { throw ToolError("The PDF couldn't be written.") }
        return out
    }

    @MainActor
    static func saveMedia(_ url: URL, _ fields: [MetaField], _ ctx: ToolContext) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let existing = (try? await asset.load(.metadata)) ?? []
        var items: [AVMetadataItem] = []
        var handled = Set<String>()
        for f in fields {
            guard let path = f.path else { continue }
            handled.insert(path)
            if f.removed || f.value.isEmpty { continue }
            if f.value == f.original, let item = existing.first(where: { $0.identifier?.rawValue == path }) {
                items.append(item)
                continue
            }
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: path)
            item.value = f.value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        // Keep what wasn't listed (binary items such as cover art) unless everything was removed.
        let everything = fields.filter { $0.path != nil }.allSatisfy(\.removed)
        if !everything { items += existing.filter { item in item.identifier.map { !handled.contains($0.rawValue) } ?? false } }
        let ext = url.pathExtension.lowercased()
        let type: AVFileType = ext == "mov" ? .mov : ext == "m4a" ? .m4a : .mp4
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ToolError("This file can't be copied.")
        }
        session.metadata = items
        let out = Output.file(for: url, suffix: "metadata")
        try await Media.export(session, to: out, type: type, context: ctx)
        return out
    }
}
