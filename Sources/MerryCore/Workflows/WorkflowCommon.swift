import Foundation

/// Extension families used to propose type-based groups without a model.
public let TYPE_FAMILIES: [(group: String, exts: [String], description: String)] = [
    ("Documents", [".pdf", ".doc", ".docx", ".txt", ".rtf", ".pages", ".md"], "Text documents, PDFs and word processor files."),
    ("Images", [".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".svg", ".tiff"], "Photos, screenshots and other images."),
    ("Spreadsheets", [".xlsx", ".xls", ".csv", ".numbers", ".tsv"], "Spreadsheets and tabular data."),
    ("Presentations", [".ppt", ".pptx", ".key"], "Slide decks and presentations."),
    ("Archives", [".zip", ".tar", ".gz", ".rar", ".7z", ".dmg"], "Compressed archives and disk images."),
    ("Audio", [".mp3", ".wav", ".m4a", ".aac", ".flac"], "Music, recordings and other audio."),
    ("Video", [".mp4", ".mov", ".avi", ".mkv", ".webm"], "Video files and screen recordings."),
    ("Installers", [".pkg", ".app", ".deb", ".exe", ".msi"], "Application installers and packages."),
    ("Code", [".js", ".ts", ".py", ".rb", ".go", ".rs", ".json", ".html", ".css", ".sh"], "Source code and configuration files.")
]

public func typeGroupFor(_ ext: String) -> String? {
    let lower = ext.lowercased()
    return TYPE_FAMILIES.first { $0.exts.contains(lower) }?.group
}

/// Words too generic to make a useful project folder name.
private let stopwords: Set<String> = [
    "the", "and", "for", "with", "from", "copy", "final", "draft", "new", "old", "untitled",
    "document", "file", "image", "photo", "download", "downloads", "version", "temp", "test",
    "screen", "shot", "screenshot", "img", "dsc", "pdf", "doc", "docx", "png", "jpg"
]

/// Derives candidate project names from filenames, with no model involved: a
/// token that appears across several files is usually a real project or client.
public func candidateProjectGroups(_ files: [FileEntry], minFiles: Int = 2, max: Int = 6) -> [String] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for f in files {
        let stem = Path.basename(f.name, Path.extname(f.name)).lowercased()
        let tokens = Rx("[^a-z0-9]+", "i").split(stem).filter { !$0.isEmpty }
        for token in tokens.unique {
            if token.jsLength < 3 || token.jsLength > 24 { continue }
            if stopwords.contains(token) { continue }
            if Rx("^\\d+$").test(token) { continue }
            if counts[token] == nil { order.append(token) }
            counts[token, default: 0] += 1
        }
    }
    // A stable sort by count, so ties stay in the order they were first seen.
    let ranked = order.enumerated().filter { counts[$0.element]! >= minFiles }
        .sorted { a, b in counts[a.element]! != counts[b.element]! ? counts[a.element]! > counts[b.element]! : a.offset < b.offset }
    return ranked.prefix(max).map { $0.element.capitalizedFirst }
}

/// Month folders like "2026-09", derived from modification dates.
public func candidateDateGroups(_ files: [FileEntry]) -> [String] {
    Array(files.map { dateGroupFor($0.modifiedAt) }.unique.sorted().reversed().prefix(8))
}

public func dateGroupFor(_ modifiedAt: Double) -> String {
    JSDate(modifiedAt).toISOString().jsSlice(0, 7)
}

extension FileEntry {
    /// An entry as a file tool returned it.
    init(json: JSON) {
        self.init(path: json.str("path"), name: json.str("name"), kind: json.str("kind"), size: json.int("size"),
                  modifiedAt: json.num("modifiedAt"), createdAt: json.num("createdAt"), ext: json.str("ext"))
    }
}

/// Lists a folder through the tool layer, so authorization still applies.
func listFolder(_ ctx: WorkflowContext, _ path: String) async throws -> [FileEntry]? {
    let res = try await ctx.run("files_list", ["path": .string(path), "includeHidden": false])
    if !res.ok {
        ctx.log(.warn, "could not list \(path): \(res.error ?? "")")
        return nil
    }
    return res.result?.list("entries").map(FileEntry.init(json:))
}

/// Reads a noul answer as a yes/no.
func isYes(_ answer: JevAnswer?, threshold: Double = 0.5) -> Bool {
    guard let noul = answer?.noul else { return false }
    return noul > threshold
}
