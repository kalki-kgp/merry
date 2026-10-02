import Foundation

// Finding a file the user half-remembers.
//
// The old implementation walked directories and never matched on the words
// the user actually typed: it fetched every recent file of a type and sorted
// by date, which is not a search. This asks Spotlight's index instead: the
// same index the Finder uses, already built, covering filenames *and* file
// contents, and it answers across a whole home directory in about 200ms.
//
// It needs no authorization prompt because it cannot change anything and
// never returns file contents, only paths and their metadata, for locations
// the user can already see in their own Finder. Opening one of the results is
// a separate, explicit act.

/// Pieces of JavaScript's regular expression language that ICU spells
/// differently. JavaScript's `\b`, `\s` and `.` are narrower than ICU's, and
/// its `$` only matches at the very end, so patterns are written with these.
enum JSRx {
    /// `\b`: a boundary between ASCII word characters and anything else.
    static let b = "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
    /// `.` without the `s` flag.
    static let dot = "[^\\n\\r\\u2028\\u2029]"
    /// The members of `\s`, for use inside a character class.
    static let spaces = "\\t\\n\\x{0B}\\f\\r\\p{Z}\\x{FEFF}"
    /// `\s`
    static let s = "[\(spaces)]"
    /// `$` without the `m` flag.
    static let end = "\\z"

    /// `toLowerCase()`: unlike `lowercased()`, a sigma ending a word becomes "ς".
    static func lower(_ text: String) -> String { text.lowercased(with: nil) }

    /// `toFixed(1)` for a number that is not negative. The last place is chosen
    /// on the number's exact value and a tie goes up, where printf rounds a tie to even.
    static func toFixed1(_ x: Double) -> String {
        guard x.isFinite, x >= 0, x < 1e15 else { return x.toFixed(1) }
        var tenths = (x * 10).rounded(.down)
        // What is left of x * 10 beyond `tenths`, with no rounding in between.
        var rest = (-tenths).addingProduct(x, 10)
        if rest < 0 { tenths -= 1; rest = (-tenths).addingProduct(x, 10) }
        if rest >= 0.5 { tenths += 1 }
        let whole = Int(tenths)
        return "\(whole / 10).\(whole % 10)"
    }

    /// Lower-cases A to Z only. JavaScript's `i` flag never lets an ASCII
    /// letter in a pattern match a non-ASCII one (ICU's would match "K" against
    /// the Kelvin sign), so an `i` pattern is run lower-case over this.
    static func asciiLower(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u.value >= 65 && u.value <= 90 { out.append(Unicode.Scalar(u.value + 32)!) } else { out.append(u) }
        }
        return String(out)
    }
}

/// Places whose contents are noise in a search for the user's own documents.
private let noise = [
    "/Library/",
    "/node_modules/",
    "/.git/",
    "/.Trash/",
    "/Applications/",
    "/.cache/",
    "/Caches/",
    "/DerivedData/",
    "/.npm/",
    "/.cargo/"
]

public struct FoundFile: Equatable, Sendable {
    public var path: String
    public var name: String
    public var folder: String
    public var modifiedAt: Double
    public var size: Int
    public var score: Double
    public var why: String

    public init(path: String, name: String, folder: String, modifiedAt: Double, size: Int, score: Double, why: String) {
        self.path = path; self.name = name; self.folder = folder; self.modifiedAt = modifiedAt; self.size = size; self.score = score; self.why = why
    }

    public var json: JSON {
        ["path": .string(path), "name": .string(name), "folder": .string(folder), "modifiedAt": .number(modifiedAt),
         "size": JSON(size), "score": .number(score), "why": .string(why)]
    }
}

public let filesFind = ToolDefinition(
    name: "files_find",
    description: "Find files the user is describing from memory, by name and by what is inside them, anywhere in their home folder. Uses the macOS Spotlight index, so it is fast and covers file contents. Prefer this over files_search whenever you are looking for something rather than listing a known folder.",
    capability: "files.read",
    input: S.object([
        "terms": S.string().describe("The distinctive words to look for, e.g. \"ethernet frames\", not the whole sentence"),
        "extensions": S.array(S.string()).optional().describe("Restrict to these extensions, e.g. [\".pdf\"]"),
        "modifiedAfter": S.number().optional().describe("Unix ms; only files changed since then"),
        "minBytes": S.number().optional().describe("Only files at least this large, for \"big files\" requests"),
        "folder": S.string().optional().describe("Restrict to one folder. Omit to search the whole home folder."),
        "limit": S.number().int().min(1).max(50).default(12)
    ]),
    // Reading a path list changes nothing and reveals nothing the user cannot
    // already see in their own Finder, so this asks for no new authorization.
    scopes: { _ in [] },
    execute: { i, ctx in
        let home = Path.home
        let folder = i.optStr("folder").flatMap { $0.isEmpty ? nil : $0 }
        let root = folder.map(normalizePath) ?? home
        let results = await findFiles(FindOptions(
            terms: i.str("terms"),
            root: root,
            extensions: i.optStrings("extensions"),
            modifiedAfter: i.optNum("modifiedAfter").flatMap { $0 == 0 ? nil : $0 },
            minBytes: i.optNum("minBytes").flatMap { $0 == 0 ? nil : $0 },
            limit: i.int("limit")
        ))
        _ = ctx.observe(
            "files",
            "Searched for \"\(i.str("terms"))\" in \(root == home ? "your home folder" : Path.basename(root)): \(results.count) matches",
            ["terms": .string(i.str("terms")), "count": JSON(results.count)],
            60_000
        )
        return ToolOutcome(["matches": .array(results.map(\.json))])
    }
)

public func formatSize(_ bytes: Double) -> String {
    let gb = 1024.0 * 1024 * 1024, mb = 1024.0 * 1024
    if bytes >= gb {
        return "\(JSRx.toFixed1(bytes / gb)) GB"
    }
    if bytes >= mb { return "\(JSON.format(jsRound(bytes / mb))) MB" }
    return "\(JSON.format(max(1, jsRound(bytes / 1024)))) KB"
}

private func nameHits(_ path: String, _ words: [String]) -> Int {
    let name = searchableName(path)
    return words.filter { name.contains($0) }.count
}

public struct FindOptions: Sendable {
    public var terms: String
    /// Pre-parsed terms, when the caller has already read the sentence.
    public var words: [String]?
    public var root: String
    public var extensions: [String]?
    public var modifiedAfter: Double?
    /// Only files at least this many bytes: "the big ones", "what is eating space".
    public var minBytes: Double?
    public var limit: Int

    public init(terms: String, words: [String]? = nil, root: String, extensions: [String]? = nil, modifiedAfter: Double? = nil, minBytes: Double? = nil, limit: Int) {
        self.terms = terms; self.words = words; self.root = root; self.extensions = extensions
        self.modifiedAfter = modifiedAfter; self.minBytes = minBytes; self.limit = limit
    }
}

public func findFiles(_ opts: FindOptions, now: Double = nowMs()) async -> [FoundFile] {
    await findFiles(opts, now: now, index: mdfind)
}

/// `index` is Spotlight; tests hand in their own to reach both branches.
func findFiles(_ opts: FindOptions, now: Double, index: @Sendable ([String]) async -> [String]) async -> [FoundFile] {
    let root = (try? NodeFS.realpath(opts.root)) ?? opts.root
    if isForbidden(root) { return [] }
    guard let rootInfo = try? NodeFS.stat(root) else { return [] }
    let concepts = documentTerms(opts.terms)
    let words = opts.words ?? distinctiveWords(removeDocumentWords(opts.terms))
    let terms = (words + concepts).unique
    // Zero counts as not given, as it does in the reference's truthiness checks.
    let modifiedAfter = opts.modifiedAfter.flatMap { $0 == 0 || $0.isNaN ? nil : $0 }
    let query = buildQuery(terms, opts.extensions, modifiedAfter, concepts, opts.minBytes, now: now)
    let args = ["-onlyin", root, query ?? "kMDItemFSName == \"*\"c"]

    let exts = opts.extensions?.map { JSRx.lower($0.hasPrefix(".") ? $0 : ".\($0)") }
    let hasExts = !(exts ?? []).isEmpty
    let minBytes = opts.minBytes ?? 0
    func eligible(_ path: String) -> Bool {
        let rel = Path.relative(root, path)
        return rel != ".." && !rel.hasPrefix("../") && !Path.isAbsolute(rel)
            && !isForbidden(path) && !noise.contains { path.contains($0) }
            && (!hasExts || exts!.contains { JSRx.lower(path).hasSuffix($0) })
    }
    let indexed = rootInfo.isFile ? [] : await index(args).filter(eligible)
    let indexedPaths = Set(indexed)
    // No useful indexed hit: search filenames locally, pruning caches before they
    // consume the walk budget. A concept's content hits must not hide an unindexed ID.
    let needWalk = indexed.isEmpty || (!concepts.isEmpty && !indexed.contains { nameHits($0, concepts) > 0 })
    let fallback = rootInfo.isFile ? [root] : needWalk ? walk(root, 6, 4000) : []
    let naming = concepts.isEmpty ? terms : concepts
    let paths = (indexed + fallback).unique
        .filter(eligible)
        // The index returns matches in no useful order, so prefer the ones whose
        // names match before spending a stat on the rest.
        .jsSorted { a, b in Double(nameHits(b, naming) - nameHits(a, naming)) }
        // Size cannot be known before a stat, so a size question looks at far
        // more candidates; a stat is cheap next to missing the biggest file.
        .prefix(minBytes > 0 ? 5000 : 150)

    var scored: [FoundFile] = []
    for path in paths {
        // Indexed but since deleted, or a link into a protected place: skipped.
        guard let real = try? NodeFS.realpath(path), !isForbidden(real), let info = try? NodeFS.stat(path), !info.isDirectory else { continue }
        if let modifiedAfter, info.mtimeMs < modifiedAfter { continue }
        // mdfind applied these already; a fallback walk has not.
        if Double(info.size) < minBytes { continue }
        let lower = JSRx.lower(Path.basename(path))
        if hasExts, !exts!.contains(where: { lower.hasSuffix($0) }) { continue }
        if !indexedPaths.contains(path), !terms.isEmpty, !naming.contains(where: { searchableName(path).contains($0) }) { continue }
        let (score, why) = rank(path, terms, info.mtimeMs, concepts, minBytes > 0 ? Double(info.size) : 0, now: now)
        scored.append(FoundFile(path: path, name: Path.basename(path), folder: Path.dirname(path), modifiedAt: info.mtimeMs, size: info.size, score: score, why: why))
    }

    // A size question with nothing else named ("the biggest file in Downloads")
    // is answered by size alone.
    if minBytes > 0 && terms.isEmpty {
        scored = scored.jsSorted { a, b in Double(b.size - a.size) }
    } else {
        scored = scored.jsSorted { a, b in b.score - a.score != 0 ? b.score - a.score : b.modifiedAt - a.modifiedAt }
    }
    return Array(scored.prefix(opts.limit))
}

/// Ranking, in code rather than by a model.
///
/// A model scoring bare filenames is both slower and worse: "cls1.pdf" tells
/// it nothing. These signals are cheap, explainable, and the reason each hit
/// won is reported back so the user can see why.
func rank(_ path: String, _ words: [String], _ modifiedMs: Double, _ concepts: [String] = [], _ sizeBytes: Double = 0, now: Double) -> (score: Double, why: String) {
    let name = searchableName(path)
    let stem = Rx("\\.[^.]+\(JSRx.end)").replaceFirst(name, "")
    var reasons: [String] = []
    var score = 0.0

    let hit = words.filter { name.contains($0) }
    if !hit.isEmpty {
        score += concepts.contains { name.contains($0) } ? 65 : 40 * (Double(hit.count) / Double(words.count))
        let descriptors = words.filter { !concepts.contains($0) }
        if !concepts.isEmpty && !descriptors.isEmpty {
            score += 15 * Double(descriptors.filter { name.contains($0) }.count) / Double(descriptors.count)
        }
        reasons.append("Name match")
    }
    if !words.isEmpty && stem == words.joined(separator: " ") {
        score += 25
        reasons.append("the name is exactly that")
    }
    // Only claim a content match when there was actually something to match.
    if hit.isEmpty && !words.isEmpty { reasons.append("Indexed content match") }

    // Recency, decaying over a month. "The one I downloaded yesterday" is the
    // overwhelmingly common case, but it must not drown out a name match.
    let days = (now - modifiedMs) / 86_400_000
    if days < 1 {
        score += 22
        reasons.append("changed today")
    } else if days < 7 {
        score += 14
        reasons.append("changed \(JSON.format(jsRound(days)))d ago")
    } else if days < 31 {
        score += 6
    }

    // When the request was about size, size is the answer, so it dominates.
    if sizeBytes > 0 {
        score += min(60, (sizeBytes / (1024 * 1024 * 1024)) * 30)
        reasons.insert(formatSize(sizeBytes), at: 0)
    }

    // Where people keep things they are talking about.
    if Rx("/(Downloads|Desktop|Documents)/").test(path) {
        score += 12
        let parts = path.jsSplit("/")
        reasons.append("in \(parts.count >= 2 ? parts[parts.count - 2] : "undefined")")
    }
    if Rx("/(dev|Projects|Code|src)/").test(path) { score += 4 }

    return (score, reasons.prefix(3).joined(separator: " · "))
}

/// Builds an mdfind expression.
///
/// The terms are OR-ed, not AND-ed: "the cybersecurity notes I downloaded"
/// should still find CyberSecurity.pdf even though no file is called "notes".
/// Requiring every word found nothing at all, which is the worse failure;
/// ranking sorts out which of the loose matches actually wins.
func buildQuery(_ words: [String], _ extensions: [String]? = nil, _ modifiedAfter: Double? = nil, _ concepts: [String] = [], _ minBytes: Double? = nil, now: Double) -> String? {
    var clauses: [String] = []
    if !words.isEmpty {
        let named = concepts.isEmpty ? words : concepts
        let byName = named.map { "kMDItemFSName == \"*\(escapeTerm($0))*\"cd" }
        let byContent = named.map { "kMDItemTextContent == \"\(escapeTerm($0))\"cd" }
        clauses.append("(\((byName + byContent).joined(separator: " || ")))")
    }
    if let extensions, !extensions.isEmpty {
        let exts = extensions.map { "kMDItemFSName == \"*\(escapeTerm($0.hasPrefix(".") ? $0 : ".\($0)"))\"cd" }
        clauses.append("(\(exts.joined(separator: " || ")))")
    }
    if let modifiedAfter, modifiedAfter != 0 {
        // Filtering in the index is far cheaper than stat-ing everything it returns.
        let days = max(1, ((now - modifiedAfter) / 86_400_000).rounded(.up))
        clauses.append("kMDItemContentModificationDate >= $time.today(-\(JSON.format(days)))")
    }
    if let minBytes, minBytes != 0, !minBytes.isNaN { clauses.append("kMDItemFSSize >= \(JSON.format(jsRound(minBytes)))") }
    return clauses.isEmpty ? nil : clauses.joined(separator: " && ")
}

/// Words that name a kind of file, and the extensions they mean.
private let kinds: [(words: [String], exts: [String])] = [
    (["pdf"], [".pdf"]),
    (["screenshot", "screengrab"], [".png", ".jpg", ".jpeg"]),
    (["image", "images", "photo", "photos", "picture", "pictures", "pic", "pics"], [".png", ".jpg", ".jpeg", ".heic", ".gif", ".webp"]),
    (["video", "videos", "movie", "clip"], [".mp4", ".mov", ".m4v", ".avi", ".mkv"]),
    (["song", "songs", "music", "audio", "track"], [".mp3", ".m4a", ".wav", ".aac", ".flac"]),
    (["doc", "docs", "word"], [".docx", ".doc", ".pages"]),
    (["sheet", "spreadsheet", "excel", "csv"], [".xlsx", ".xls", ".csv", ".numbers"]),
    (["slides", "deck", "presentation", "powerpoint"], [".pptx", ".ppt", ".key"]),
    (["zip", "archive"], [".zip", ".tar", ".gz", ".dmg"])
]

private let day = 86_400_000.0
private let whens: [(re: Rx, ms: Double)] = [
    (Rx("\(JSRx.b)(today|this morning|just now|just)\(JSRx.b)"), day),
    (Rx("\(JSRx.b)yesterday\(JSRx.b)"), 2 * day),
    (Rx("\(JSRx.b)(this week|last week|few days|recent|recently|latest|last one)\(JSRx.b)"), 8 * day),
    (Rx("\(JSRx.b)(this month|last month)\(JSRx.b)"), 31 * day)
]

private let folders: [(re: Rx, dir: String)] = [
    (Rx("\(JSRx.b)(downloads?|downloaded)\(JSRx.b)"), "Downloads"),
    (Rx("\(JSRx.b)desktop\(JSRx.b)"), "Desktop"),
    (Rx("\(JSRx.b)documents?\(JSRx.b)"), "Documents"),
    (Rx("\(JSRx.b)(pictures?|photos library)\(JSRx.b)"), "Pictures")
]

public struct ParsedQuery: Equatable, Sendable {
    public var words: [String]
    public var extensions: [String]
    public var modifiedAfter: Double?
    public var folder: String?
    /// Nothing was named: the user wants whatever is newest.
    public var recencyOnly: Bool

    public init(words: [String], extensions: [String], modifiedAfter: Double?, folder: String?, recencyOnly: Bool) {
        self.words = words; self.extensions = extensions; self.modifiedAfter = modifiedAfter; self.folder = folder; self.recencyOnly = recencyOnly
    }
}

/// Reads the sentence the way a person means it, in code.
///
/// "the pdf I downloaded yesterday" is a type filter, a time filter and a
/// place, not three search words. Asking a model to work that out costs
/// hundreds of milliseconds and gets it no more right than these rules do.
public func parseQuery(_ text: String, now: Double = nowMs()) -> ParsedQuery {
    let lower = JSRx.lower(text)

    var extensions: [String] = []
    var kindWords = Set<String>()
    for kind in kinds {
        if kind.words.contains(where: { Rx("\(JSRx.b)\($0)\(JSRx.b)").test(lower) }) {
            extensions.append(contentsOf: kind.exts)
            kindWords.formUnion(kind.words)
        }
    }

    var modifiedAfter: Double?
    for when in whens where when.re.test(lower) {
        modifiedAfter = now - when.ms
        break
    }

    var folder = folders.first { $0.re.test(lower) }?.dir

    // Anything already used as a filter is not also a search term.
    var words = distinctiveWords(removeDocumentWords(text)).filter { w in
        !kindWords.contains(w) && !whens.contains { $0.re.test(w) } && !folders.contains { $0.re.test(w) }
    }
    // "my latest downloaded file" names no file and no kind: it is a request for
    // the newest thing somewhere obvious. Sweeping the whole home by date is
    // both slow and meaningless, so it becomes a recency query over Downloads.
    words.insert(contentsOf: documentTerms(text), at: 0)
    let recencyOnly = words.isEmpty && extensions.isEmpty
    if recencyOnly && folder == nil { folder = "Downloads" }
    if recencyOnly && (modifiedAfter == nil || modifiedAfter == 0) { modifiedAfter = now - 31 * day }

    return ParsedQuery(words: words, extensions: extensions, modifiedAfter: modifiedAfter, folder: folder, recencyOnly: recencyOnly)
}

/// Drops the words every request contains, keeping the ones that identify it.
private let stopwords: Set<String> = [
    "find", "the", "a", "an", "my", "me", "i", "file", "files", "that", "this", "it", "open", "show", "where", "is", "was", "get",
    "please", "can", "you", "for", "of", "in", "on", "from", "with", "about", "and", "or", "to", "last", "some", "thing", "saved",
    "downloaded", "looking", "look", "need", "want", "again", "one", "document", "folder", "pls", "plz", "search", "locate",
    "pc", "computer", "mac", "laptop", "device", "card", "copy", "could", "would", "hey", "merry", "out", "up", "have", "where", "stored", "dig",
    // Size is a filter and a ranking, never part of a filename.
    "big", "bigger", "biggest", "large", "larger", "largest", "huge", "heaviest", "massive", "space", "storage"
]

public func distinctiveWords(_ text: String) -> [String] {
    let cleaned = Rx("[^\\p{L}\\p{N}\\p{M}\(JSRx.spaces).\\-]").replaceAll(JSRx.lower(text).precomposedStringWithCompatibilityMapping, " ")
    return Array(
        Rx("\(JSRx.s)+").split(cleaned)
            .map { Rx("^[.\\-]+|[.\\-]+\(JSRx.end)").replaceAll($0, "") }
            .filter { $0.jsLength > 1 && !stopwords.contains($0) }
            .prefix(6)
    )
}

private func escapeTerm(_ term: String) -> String {
    Rx("([\"\\\\])").replaceAll(term, "\\$1")
}

/// A bounded directory walk, for whatever the index cannot see.
private func walk(_ root: String, _ maxDepth: Int, _ limit: Int) -> [String] {
    var found: [String] = []
    let priority = ["Downloads", "Documents", "Desktop", "Pictures"]
    func order(_ name: String) -> Int { priority.firstIndex(of: name) ?? 99 }
    func visit(_ dir: String, _ depth: Int) {
        if depth > maxDepth || found.count >= limit { return }
        // Unreadable directories are skipped, not fatal.
        guard let names = try? NodeFS.readdir(dir) else { return }
        for name in names.jsSorted({ a, b in Double(order(a) - order(b)) }) {
            if found.count >= limit { return }
            if name.hasPrefix(".") { continue }
            let full = Path.join(dir, name)
            if isForbidden(full) || noise.contains(where: { "\(full)/".contains($0) }) { continue }
            guard let info = try? NodeFS.lstat(full), !info.isSymbolicLink else { continue }
            if info.isDirectory { visit(full, depth + 1) } else { found.append(full) }
        }
    }
    visit(root, 1)
    return found
}

@Sendable private func mdfind(_ args: [String]) async -> [String] {
    // A failed index query is an empty result, not a crashed task.
    guard let r = try? await Exec.run("/usr/bin/mdfind", args, timeoutMs: 2500, maxBytes: 32 * 1024 * 1024) else { return [] }
    return r.stdout.jsSplit("\n").filter { !$0.isEmpty }
}

func searchableName(_ path: String) -> String {
    Rx("[_\\-]+").replaceAll(JSRx.lower(Path.basename(path).precomposedStringWithCompatibilityMapping), " ")
}
