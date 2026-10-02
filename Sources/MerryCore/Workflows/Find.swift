import Foundation

/// "Find the PDF I downloaded yesterday."
///
/// The sentence is read in code, the macOS index answers in about 200ms, and
/// ranking happens locally. Nothing is asked: the best match comes back with
/// the runners-up beside it, so picking a different one is a click rather
/// than a conversation.
public let findWorkflow = Workflow(
    id: "find_files",
    description: "Find a file the user is describing from memory and show them where it is.",
    routes: ["files"],
    plausible: { request, _ in
        // "search for flights" is a find verb aimed at the web, not at the disk.
        if Rx("\\b(safari|chrome|firefox|arc|browser|web|online|google|website|site|url|email|inbox|message|slack)\\b", "i").test(request) {
            return false
        }
        return Rx("\\b(find|locate|where is|where are|where’s|where's|look for|search for|open the|show me|dig up|latest|most recent)\\b", "i").test(request)
    },
    run: { request, _, ctx in
        let parsed = parseQuery(request)
        // What kind of thing, how big, how recent, where: read once, by Jev when
        // local rules were not certain. This is what makes "any movies to watch?"
        // and "find big files" work: neither says "mp4" or gives a byte count.
        let read = ctx.understanding()
        let extensions = parsed.extensions.isEmpty ? extensionsFor(read.kind) : parsed.extensions
        // "the biggest file" is a ranking, not a threshold: every size counts,
        // and it is not a question about what is recent.
        let superlative = Rx("\\b(biggest|largest|heaviest)\\b", "i").test(request)
        let minBytes: Double? = superlative ? 1 : bytesFor(read.size).map(Double.init)
        let since: Double? = superlative && parsed.recencyOnly ? nil : (parsed.modifiedAfter ?? sinceFor(read.when))
        let named = parsed.folder ?? folderFor(read.place)
        // Precedence: a folder the user actually put in front of me, then one they
        // named in the sentence, then their whole home. Searching everything is
        // the right default (the index makes it cheap), but never when they have
        // already said where to look.
        let scoped = ctx.authorizedRoots()
        let home = Path.home
        let root = scoped.first ?? (named.map { Path.join(home, $0) } ?? home)

        ctx.progress("Searching…")

        let res = try await ctx.run("files_find", .obj([
            "terms": .string(parsed.words.joined(separator: " ")),
            "folder": .string(root),
            "extensions": extensions.isEmpty ? nil : JSON(extensions),
            "modifiedAfter": since.flatMap { $0 != 0 ? JSON($0) : nil },
            "minBytes": minBytes.flatMap { $0 != 0 ? JSON($0) : nil },
            "limit": 8
        ]))
        if !res.ok {
            return WorkflowResult(success: false, headline: "The search failed.", handoffToPlanner: res.error ?? "the search failed")
        }

        var matches = res.result?.list("matches") ?? []
        if superlative { matches = matches.enumerated().sorted { a, b in a.element.num("size") != b.element.num("size") ? a.element.num("size") > b.element.num("size") : a.offset < b.offset }.map(\.element) }
        let lead = superlative ? matches.first.map { "Biggest: \($0.str("name")) (\(formatFoundSize($0.num("size"))))" } : nil
        if matches.isEmpty {
            // Widening to the whole home is free, so try that before giving up.
            var widened: [JSON] = []
            if !(root == home || !scoped.isEmpty) {
                let wider = try await ctx.run("files_find", .obj([
                    "terms": .string(parsed.words.joined(separator: " ")),
                    "extensions": extensions.isEmpty ? nil : JSON(extensions),
                    "minBytes": minBytes.flatMap { $0 != 0 ? JSON($0) : nil },
                    "limit": 8
                ]))
                if wider.ok { widened = wider.result?.list("matches") ?? [] }
            }
            if widened.isEmpty {
                return WorkflowResult(success: false, headline: "Could not find a match. Try a filename or folder.",
                                      unresolved: "searched \(root == home ? "your home folder" : root)")
            }
            return present(widened, ctx, lead)
        }
        return present(matches, ctx, lead)
    }
)

/// The best match, with the alternatives underneath it.
///
/// Deliberately not a question. The user asked for a file, not for a quiz, and
/// every row here is one click from opening.
private func present(_ matches: [JSON], _ ctx: WorkflowContext, _ lead: String?) -> WorkflowResult {
    let best = matches[0]
    ctx.log(.info, "found \(matches.count) matches, best \(best.str("path"))", ["score": best["score"] ?? .null])
    return WorkflowResult(
        success: true,
        headline: lead ?? "\(min(matches.count, 5)) match\(matches.count == 1 ? "" : "es")",
        evidence: matches.prefix(5).map { .path($0.str("name"), $0.str("path")) }
    )
}

/// 1.2 GB, 340 MB, 12 KB.
private func formatFoundSize(_ bytes: Double) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    var n = bytes
    var i = 0
    while n >= 1024 && i < units.count - 1 { n /= 1024; i += 1 }
    return "\(n >= 10 || i == 0 ? JSON.format((n + 0.5).rounded(.down)) : n.toFixed(1)) \(units[i])"
}
