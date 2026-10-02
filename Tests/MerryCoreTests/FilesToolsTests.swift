import Testing
@testable import MerryCore

/// A scratch folder under the temp directory, removed when the test ends.
final class FileScratch {
    let root: String
    init(_ label: String) throws {
        let made = Path.join(Path.tmp, "merry-\(label)-\(newId())")
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        root = try NodeFS.realpath(made)
    }
    deinit { try? FileManager.default.removeItem(atPath: root) }

    func write(_ relative: String, _ text: String = "x", modified: Double? = nil) throws {
        let path = "\(root)/\(relative)"
        try FileManager.default.createDirectory(atPath: Path.dirname(path), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        if let modified { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified / 1000)], ofItemAtPath: path) }
    }
    func read(_ relative: String) -> String? { FileManager.default.contents(atPath: "\(root)/\(relative)").map { String(decoding: $0, as: UTF8.self) } }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: "\(root)/\(relative)") }
}

final class FileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [(kind: String, summary: String, data: JSON)] = []
    private var logged: [String] = []
    private var lines: [String] = []
    func context(_ auth: Authorization = Authorization()) -> ToolContext {
        let task = TaskState(request: "test", authorization: auth)
        return ToolContext(
            task: { task }, os: UnavailableOsAdapter(), browser: NoBrowser(),
            log: { _, message, _ in self.lock.lock(); self.logged.append(message); self.lock.unlock() },
            progress: { line in self.lock.lock(); self.lines.append(line); self.lock.unlock() },
            observe: { kind, summary, data, stale in
                self.lock.lock(); self.observed.append((kind, summary, data)); self.lock.unlock()
                return Observation(id: "o", kind: kind, summary: summary, data: data, observedAt: 0, staleAfterMs: stale)
            }
        )
    }
    var summaries: [String] { lock.lock(); defer { lock.unlock() }; return observed.map(\.summary) }
    var logs: [String] { lock.lock(); defer { lock.unlock() }; return logged }
    var progress: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

private func failure(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return messageOf(error) }
}

@Test func theFileToolsAreInTheOriginalsOrder() {
    #expect(fileTools.map(\.name) == ["files_find", "files_list", "files_inspect", "files_search", "files_read", "files_create_folder", "files_move", "files_rename", "files_copy"])
    #expect(documentTools.map(\.name) == ["files_read_document", "files_prepare_copies", "files_search_document_contents"])
    #expect(shellTools.map(\.name) == ["shell_run", "app_open"])
}

@Test func listingAndInspecting() async throws {
    let s = try FileScratch("list")
    let rec = FileRecorder(), ctx = rec.context()
    try s.write("a.TXT", "hello", modified: 1_700_000_000_123)
    try s.write(".secret")
    try s.write("sub/inner.txt")
    try FileManager.default.createSymbolicLink(atPath: "\(s.root)/link", withDestinationPath: "\(s.root)/a.TXT")

    let input = try filesList.input.parse(["path": .string(s.root)])
    #expect(filesList.scopes(input).isEmpty)
    try await filesList.precondition?(input, ctx)
    let listed = try await filesList.execute(input, ctx).result
    #expect(listed.str("path") == s.root && listed.int("totalCount") == 3 && listed.flag("truncated") == false)
    let entries = Dictionary(uniqueKeysWithValues: listed.list("entries").map { ($0.str("name"), $0) })
    #expect(Set(entries.keys) == ["a.TXT", "sub", "link"])
    #expect(entries["a.TXT"]?.str("kind") == "file" && entries["a.TXT"]?.str("ext") == ".txt" && entries["a.TXT"]?.int("size") == 5)
    #expect(entries["a.TXT"]?.num("modifiedAt") == 1_700_000_000_123 && entries["a.TXT"]?.str("path") == "\(s.root)/a.TXT")
    #expect(entries["sub"]?.str("kind") == "directory" && entries["sub"]?.str("ext") == "")
    #expect(entries["link"]?.str("kind") == "symlink")
    #expect(rec.summaries == ["3 items in \(Path.basename(s.root))"])

    let hidden = try await filesList.execute(try filesList.input.parse(["path": .string(s.root), "includeHidden": true]), ctx).result
    #expect(hidden.int("totalCount") == 4)

    // The listing stops at 500 entries and says so.
    for n in 0..<505 { try s.write("many/f\(n).txt") }
    let many = try await filesList.execute(try filesList.input.parse(["path": .string("\(s.root)/many")]), ctx).result
    #expect(many.list("entries").count == 500 && many.flag("truncated") && many.int("totalCount") == 505)

    // Preconditions name what is wrong.
    #expect(await failure { try await filesList.precondition?(try filesList.input.parse(["path": .string("\(s.root)/nope")]), ctx) } == "\(s.root)/nope does not exist")
    #expect(await failure { try await filesList.precondition?(try filesList.input.parse(["path": .string("\(s.root)/a.TXT")]), ctx) } == "\(s.root)/a.TXT is not a folder")
    #expect(await failure { try await filesList.precondition?(try filesList.input.parse(["path": "/System/Library"]), ctx) } == "/System/Library is in a protected system location.")
    // A NUL would cut the path short of the one that was checked.
    #expect(await failure { _ = try await filesList.execute(try filesList.input.parse(["path": .string("\(s.root)\u{0}/x")]), ctx) } != nil)

    let inspected = try await filesInspect.execute(try filesInspect.input.parse(["path": .string("\(s.root)/a.TXT")]), ctx).result
    #expect(inspected.firstDifference(from: entries["a.TXT"]!) == nil)
    #expect(await failure { _ = try await filesInspect.execute(try filesInspect.input.parse(["path": .string("\(s.root)/nope")]), ctx) } == "ENOENT: no such file or directory, lstat '\(s.root)/nope'")
}

@Test func searchingHonoursDepthAndLimits() async throws {
    let s = try FileScratch("search")
    let rec = FileRecorder(), ctx = rec.context()
    try s.write("Invoice-1.pdf", modified: 1000_000)
    try s.write("notes.txt", modified: 2000_000)
    try s.write("one/invoice-2.PDF", modified: 3000_000)
    try s.write("one/two/INVOICE-3.pdf", modified: 4000_000)
    try s.write("one/two/three/invoice-4.pdf", modified: 5000_000)
    try s.write(".hidden/invoice-5.pdf")
    try s.write("one/.invoice-6.pdf")

    func search(_ extra: JSONObject) async throws -> JSON {
        var input: JSONObject = JSONObject([("root", .string(s.root))])
        for (k, v) in extra.pairs { input[k] = v }
        return try await filesSearch.execute(try filesSearch.input.parse(.object(input)), ctx).result
    }
    func names(_ r: JSON) -> [String] { r.list("matches").map { $0.str("name") } }

    // Default depth 3, newest first, hidden files and folders skipped.
    var r = try await search(JSONObject([("namePattern", "*invoice*")]))
    #expect(names(r) == ["INVOICE-3.pdf", "invoice-2.PDF", "Invoice-1.pdf"] && r.flag("hitLimit") == false)
    #expect(rec.summaries.last == "Found 3 matches under \(Path.basename(s.root))")
    r = try await search(JSONObject([("namePattern", "*invoice*"), ("maxDepth", 1)]))
    #expect(names(r) == ["Invoice-1.pdf"])
    r = try await search(JSONObject([("namePattern", "*invoice*"), ("maxDepth", 4)]))
    #expect(names(r).count == 4)
    r = try await search(JSONObject([("maxDepth", 6), ("limit", 2)]))
    #expect(names(r).count == 2 && r.flag("hitLimit"))
    // Globs match the whole name, and so, as in the reference, does a plain word.
    r = try await search(JSONObject([("namePattern", "invoice")]))
    #expect(names(r).isEmpty)
    r = try await search(JSONObject([("namePattern", "NOTES.TXT")]))
    #expect(names(r) == ["notes.txt"])
    r = try await search(JSONObject([("namePattern", "*.pdf")]))
    #expect(names(r).count == 3)
    r = try await search(JSONObject([("namePattern", "invoice-?.pdf")]))
    #expect(names(r).count == 3)
    r = try await search(JSONObject([("namePattern", "invoice-?")]))
    #expect(names(r).isEmpty)
    r = try await search(JSONObject([("namePattern", "i(nvoice")]))
    #expect(names(r).isEmpty)
    r = try await search(JSONObject([("extensions", ["txt", ".PDF"]), ("modifiedAfter", 1500_000), ("modifiedBefore", 3500_000)]))
    #expect(names(r) == ["invoice-2.PDF", "notes.txt"])
    #expect(await failure { _ = try await filesSearch.execute(try filesSearch.input.parse(["root": "/usr/bin"]), ctx) } == "/usr/bin is in a protected system location.")
}

@Test func readingWithLimits() async throws {
    let s = try FileScratch("read")
    let ctx = FileRecorder().context()
    try s.write("a.txt", "héllo wörld")
    let whole = try filesRead.input.parse(["path": .string("\(s.root)/a.txt")])
    #expect(filesRead.scopes(whole) == [.read(path: "\(s.root)/a.txt")])
    var r = try await filesRead.execute(whole, ctx).result
    #expect(r.str("untrustedContent") == "héllo wörld" && r.int("bytes") == 13 && r.flag("truncated") == false)
    r = try await filesRead.execute(try filesRead.input.parse(["path": .string("\(s.root)/a.txt"), "maxBytes": 5]), ctx).result
    #expect(r.str("untrustedContent") == "hél" + "l" && r.int("bytes") == 5 && r.flag("truncated"))
    // The default limit is 256 KB.
    try s.write("big.txt", String(repeating: "a", count: 300_000))
    r = try await filesRead.execute(try filesRead.input.parse(["path": .string("\(s.root)/big.txt")]), ctx).result
    #expect(r.int("bytes") == 262_144 && r.str("untrustedContent").count == 262_144 && r.flag("truncated"))
    #expect(await failure { _ = try await filesRead.execute(try filesRead.input.parse(["path": .string(s.root)]), ctx) } == "\(s.root) is a folder; use files_list")
    #expect(await failure { _ = try await filesRead.execute(try filesRead.input.parse(["path": .string("\(s.root)/nope")]), ctx) } == "ENOENT: no such file or directory, stat '\(s.root)/nope'")
    #expect((try? filesRead.input.parse(["path": .string("\(s.root)/a.txt"), "maxBytes": 300_000])) == nil)
}

@Test func creatingFolders() async throws {
    let s = try FileScratch("mkdir")
    let rec = FileRecorder(), ctx = rec.context()
    let path = "\(s.root)/new/deeper"
    let input = try filesCreateFolder.input.parse(["path": .string(path)])
    #expect(filesCreateFolder.scopes(input) == [.write(path: path)])
    let made = try await filesCreateFolder.execute(input, ctx)
    #expect(made.result.flag("created") && made.result.str("path") == path)
    #expect(made.undo == [UndoEntry(kind: .folderCreate, from: path, to: path)])
    #expect(made.evidence == [.path("deeper", path)])
    #expect(rec.logs == ["created folder \(path)"])
    #expect(try await filesCreateFolder.verify?(input, made, ctx) == VerificationResult(verified: true, method: "stat", detail: "\(path) exists"))

    // Already there: nothing to undo.
    let again = try await filesCreateFolder.execute(input, ctx)
    #expect(again.result.flag("created") == false && again.undo.isEmpty)
    try s.write("file.txt")
    #expect(await failure { _ = try await filesCreateFolder.execute(try filesCreateFolder.input.parse(["path": .string("\(s.root)/file.txt")]), ctx) } == "\(s.root)/file.txt already exists and is not a folder")
    try FileManager.default.removeItem(atPath: path)
    #expect(try await filesCreateFolder.verify?(input, made, ctx) == VerificationResult(verified: false, method: "stat", detail: "\(path) is still missing after mkdir"))
}

@Test func movingRecordsUndoAndNeverOverwrites() async throws {
    let s = try FileScratch("move")
    let rec = FileRecorder(), ctx = rec.context()
    try s.write("a.txt", "moved")
    try FileManager.default.createDirectory(atPath: "\(s.root)/dest", withIntermediateDirectories: true)
    let from = "\(s.root)/a.txt", to = "\(s.root)/dest/a.txt"

    let input = try filesMove.input.parse(["from": .string(from), "to": .string(to)])
    #expect(filesMove.scopes(input) == [.write(path: from), .write(path: to)])
    try await filesMove.precondition?(input, ctx)
    let moved = try await filesMove.execute(input, ctx)
    #expect(moved.result.firstDifference(from: ["from": .string(from), "to": .string(to), "moved": true]) == nil)
    #expect(moved.undo == [UndoEntry(kind: .fileMove, from: from, to: to)])
    #expect(moved.evidence == [.path("a.txt", to)])
    #expect(rec.logs == ["moved a.txt -> \(to)"])
    #expect(!s.exists("a.txt") && s.read("dest/a.txt") == "moved")
    #expect(try await filesMove.verify?(input, moved, ctx) == VerificationResult(verified: true, method: "stat both paths", detail: "a.txt is now at \(to)"))

    // A name collision becomes "name (2).ext", then "(3)", and the file already there is untouched.
    for expected in ["a (2).txt", "a (3).txt"] {
        try s.write("a.txt", "newcomer \(expected)")
        let out = try await filesMove.execute(input, ctx)
        #expect(out.result.str("to") == "\(s.root)/dest/\(expected)")
        #expect(out.undo == [UndoEntry(kind: .fileMove, from: from, to: "\(s.root)/dest/\(expected)")])
        #expect(s.read("dest/a.txt") == "moved" && s.read("dest/\(expected)") == "newcomer \(expected)")
    }
    try s.write("dest/archive.tar.gz", "old")
    try s.write("archive.tar.gz", "new")
    let tar = try await filesMove.execute(try filesMove.input.parse(["from": .string("\(s.root)/archive.tar.gz"), "to": .string("\(s.root)/dest/archive.tar.gz")]), ctx)
    #expect(tar.result.str("to") == "\(s.root)/dest/archive.tar (2).gz" && s.read("dest/archive.tar.gz") == "old")

    // onConflict "fail" refuses and changes nothing.
    try s.write("a.txt", "stays")
    let strict = try filesMove.input.parse(["from": .string(from), "to": .string(to), "onConflict": "fail"])
    #expect(await failure { _ = try await filesMove.execute(strict, ctx) } == "\(to) already exists")
    #expect(s.read("a.txt") == "stays" && s.read("dest/a.txt") == "moved")

    // A missing source, or a missing destination folder, is caught before anything runs.
    #expect(await failure { try await filesMove.precondition?(try filesMove.input.parse(["from": .string("\(s.root)/ghost.txt"), "to": .string(to)]), ctx) } == "\(s.root)/ghost.txt does not exist")
    #expect(await failure { try await filesMove.precondition?(try filesMove.input.parse(["from": .string(from), "to": .string("\(s.root)/nowhere/a.txt")]), ctx) } == "destination folder \(s.root)/nowhere does not exist; create it first")

    // Verification reports failure when the destination is missing, or the source is still there.
    try FileManager.default.removeItem(atPath: to)
    #expect(try await filesMove.verify?(input, moved, ctx) == VerificationResult(
        verified: false, method: "stat both paths",
        detail: "expected \(to) to exist and \(from) to be gone (exists: false, source still there: true)"))

    // Same path: nothing happens, and that verifies.
    let same = try filesMove.input.parse(["from": .string(from), "to": .string(from)])
    let noop = try await filesMove.execute(same, ctx)
    #expect(noop.result.flag("moved") == false && noop.result.str("reason") == "source and destination are the same" && noop.undo.isEmpty)
    #expect(try await filesMove.verify?(same, noop, ctx) == VerificationResult(verified: true, method: "no-op", detail: "nothing to move"))

    // Rename is the same operation, recorded as a rename. Folders move too.
    try s.write("folder/inside.txt", "in")
    let renamed = try await filesRename.execute(try filesRename.input.parse(["from": .string("\(s.root)/folder"), "to": .string("\(s.root)/renamed")]), ctx)
    #expect(renamed.undo == [UndoEntry(kind: .fileRename, from: "\(s.root)/folder", to: "\(s.root)/renamed")])
    #expect(s.read("renamed/inside.txt") == "in" && !s.exists("folder"))
}

@Test func copying() async throws {
    let s = try FileScratch("copy")
    let ctx = FileRecorder().context()
    try s.write("a.txt", "original")
    try s.write("tree/x/y.txt", "deep")
    let from = "\(s.root)/a.txt", to = "\(s.root)/new/place/a.txt"
    let input = try filesCopy.input.parse(["from": .string(from), "to": .string(to)])
    #expect(filesCopy.scopes(input) == [.read(path: from), .write(path: to)])
    try await filesCopy.precondition?(input, ctx)
    // Missing parent folders are created; the original stays; nothing is undoable.
    let copied = try await filesCopy.execute(input, ctx)
    #expect(copied.result.firstDifference(from: ["from": .string(from), "to": .string(to)]) == nil && copied.undo.isEmpty)
    #expect(s.read("a.txt") == "original" && s.read("new/place/a.txt") == "original")
    #expect(try await filesCopy.verify?(input, copied, ctx) == VerificationResult(verified: true, method: "stat", detail: "\(to) exists"))

    try s.write("a.txt", "second")
    let second = try await filesCopy.execute(input, ctx)
    #expect(second.result.str("to") == "\(s.root)/new/place/a (2).txt" && s.read("new/place/a.txt") == "original" && s.read("new/place/a (2).txt") == "second")
    #expect(await failure { _ = try await filesCopy.execute(try filesCopy.input.parse(["from": .string(from), "to": .string(to), "onConflict": "fail"]), ctx) } == "\(to) already exists")

    let tree = try await filesCopy.execute(try filesCopy.input.parse(["from": .string("\(s.root)/tree"), "to": .string("\(s.root)/tree-copy")]), ctx)
    #expect(s.read("tree-copy/x/y.txt") == "deep" && s.read("tree/x/y.txt") == "deep")
    try FileManager.default.removeItem(atPath: "\(s.root)/tree-copy")
    #expect(try await filesCopy.verify?(input, tree, ctx) == VerificationResult(verified: false, method: "stat", detail: "\(s.root)/tree-copy was not created"))
    #expect(await failure { try await filesCopy.precondition?(try filesCopy.input.parse(["from": .string("\(s.root)/ghost"), "to": .string(to)]), ctx) } == "\(s.root)/ghost does not exist")
}
