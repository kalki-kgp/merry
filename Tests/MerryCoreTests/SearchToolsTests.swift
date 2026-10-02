import Testing
@testable import MerryCore

@Test func requestsAreReadTheSameWay() {
    let fixture = Fixture.load("search-cases")
    let now = fixture.num("now")
    for row in fixture.list("queries") {
        let parsed = parseQuery(row.str("text"), now: now)
        let got: JSON = [
            "words": JSON(parsed.words), "extensions": JSON(parsed.extensions), "modifiedAfter": JSON(parsed.modifiedAfter),
            "folder": JSON(parsed.folder), "recencyOnly": .bool(parsed.recencyOnly)
        ]
        let difference = got.firstDifference(from: row["parsed"] ?? .null)
        #expect(difference == nil, "parseQuery \(row.str("text")): \(difference ?? "")")
    }
    for row in fixture.list("words") {
        #expect(distinctiveWords(row.str("text")) == row.strings("words"), "distinctiveWords \(row.str("text"))")
    }
    for row in fixture.list("sizes") {
        #expect(formatSize(row.num("bytes")) == row.str("text"), "formatSize \(row.num("bytes"))")
    }
}

private func write(_ path: String, _ text: String = "x", modified: Double? = nil) throws {
    try FileManager.default.createDirectory(atPath: Path.dirname(path), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    if let modified { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified / 1000)], ofItemAtPath: path) }
}

@Test func findFilesFallsBackToABoundedWalk() async throws {
    let made = Path.join(Path.tmp, "merry-find-\(newId())")
    try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
    let root = try NodeFS.realpath(made)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let now = 1_790_000_000_000.0, day = 86_400_000.0
    try write("\(root)/Documents/ethernet-frames.pdf", String(repeating: "a", count: 3000), modified: now - 2 * day)
    try write("\(root)/Documents/Ethernet Frames notes.txt", modified: now - 40 * day)
    try write("\(root)/Downloads/holiday.png", modified: now - day / 2)
    try write("\(root)/node_modules/pkg/ethernet.js", modified: now)
    try write("\(root)/.hidden/ethernet.txt", modified: now)
    try write("\(root)/a/b/c/d/e/f/g/ethernet-deep.txt", modified: now)
    try FileManager.default.createSymbolicLink(atPath: "\(root)/ethernet-link.txt", withDestinationPath: "\(root)/Downloads/holiday.png")

    // Nothing from the index: names are searched by walking, without noise, hidden folders, links or anything too deep.
    let none: @Sendable ([String]) async -> [String] = { _ in [] }
    let found = await findFiles(FindOptions(terms: "ethernet frames", root: root, limit: 12), now: now, index: none)
    #expect(found.map(\.name) == ["ethernet-frames.pdf", "Ethernet Frames notes.txt"])
    #expect(found[0].why == "Name match · the name is exactly that · changed 2d ago")
    #expect(found[0].score == 40 + 25 + 14 + 12)
    #expect(found[0].folder == "\(root)/Documents" && found[0].size == 3000 && found[0].modifiedAt == now - 2 * day)
    #expect(found[1].why == "Name match · in Documents")

    // Filters the index would have applied are applied to walked files too.
    #expect(await findFiles(FindOptions(terms: "ethernet", root: root, extensions: ["txt"], limit: 12), now: now, index: none).map(\.name) == ["Ethernet Frames notes.txt"])
    #expect(await findFiles(FindOptions(terms: "ethernet", root: root, modifiedAfter: now - 10 * day, limit: 12), now: now, index: none).map(\.name) == ["ethernet-frames.pdf"])
    #expect(await findFiles(FindOptions(terms: "ethernet", root: root, limit: 1), now: now, index: none).count == 1)
    // A size question with nothing named is answered by size.
    let big = await findFiles(FindOptions(terms: "", root: root, minBytes: 2000, limit: 12), now: now, index: none)
    #expect(big.map(\.name) == ["ethernet-frames.pdf"] && big[0].why.hasPrefix("3 KB"))
    // Nothing named at all: everything walked, newest first within equal scores.
    #expect(await findFiles(FindOptions(terms: "", root: root, limit: 12), now: now, index: none).first?.name == "holiday.png")

    // Indexed hits are used as given, minus what lies outside the root or in noise, and no walk is needed.
    let index: @Sendable ([String]) async -> [String] = { args in
        #expect(args.prefix(2) == ["-onlyin", root])
        #expect(args[2] == "(kMDItemFSName == \"*holiday*\"cd || kMDItemTextContent == \"holiday\"cd)")
        return ["\(root)/Downloads/holiday.png", "\(root)/node_modules/pkg/ethernet.js", "/etc/hosts", "\(root)/gone.png", "\(root)/Documents"]
    }
    let indexed = await findFiles(FindOptions(terms: "holiday", root: root, limit: 12), now: now, index: index)
    #expect(indexed.map(\.name) == ["holiday.png"])
    #expect(indexed[0].why == "Name match · the name is exactly that · changed today")

    // A content-only hit is reported as one.
    let content: @Sendable ([String]) async -> [String] = { _ in ["\(root)/Documents/Ethernet Frames notes.txt"] }
    #expect(await findFiles(FindOptions(terms: "switching", root: root, limit: 12), now: now, index: content).first?.why == "Indexed content match · in Documents")

    // Protected and missing roots give nothing.
    #expect(await findFiles(FindOptions(terms: "x", root: "/System/Library", limit: 5), now: now, index: none).isEmpty)
    #expect(await findFiles(FindOptions(terms: "x", root: "\(root)/missing", limit: 5), now: now, index: none).isEmpty)

    // The query the index is asked.
    #expect(buildQuery([], now: now) == nil)
    #expect(buildQuery(["a\"b", "c"], [".pdf", "png"], now - 3.5 * day, [], 1500.5, now: now)
        == "(kMDItemFSName == \"*a\\\"b*\"cd || kMDItemFSName == \"*c*\"cd || kMDItemTextContent == \"a\\\"b\"cd || kMDItemTextContent == \"c\"cd) && (kMDItemFSName == \"*.pdf\"cd || kMDItemFSName == \"*.png\"cd) && kMDItemContentModificationDate >= $time.today(-4) && kMDItemFSSize >= 1501")

    // The tool itself, through Spotlight or, as in a temp folder, the walk.
    let seen = Seen()
    let task = TaskState(request: "find")
    let ctx = ToolContext(task: { task }, os: UnavailableOsAdapter(), browser: NoBrowser(), observe: { kind, summary, data, stale in
        seen.add(summary)
        return Observation(id: "o", kind: kind, summary: summary, data: data, observedAt: 0, staleAfterMs: stale)
    })
    let input = try filesFind.input.parse(["terms": "ethernet frames", "folder": .string(root)])
    #expect(filesFind.scopes(input).isEmpty)
    let outcome = try await filesFind.execute(input, ctx)
    let names = outcome.result.list("matches").map { $0.str("name") }
    #expect(names.contains("ethernet-frames.pdf") && !names.contains("ethernet.js"))
    #expect(seen.all == ["Searched for \"ethernet frames\" in \(Path.basename(root)): \(names.count) matches"])
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
