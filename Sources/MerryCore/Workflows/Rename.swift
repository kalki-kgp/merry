import Foundation

// "Rename these files consistently."
//
// The naming schemes are fixed functions, so the rename itself is fully
// deterministic and previewable. Jev's only job is picking which scheme the
// user meant: exactly a choice between declared options.

struct NamingScheme: Sendable {
    var id: String
    var description: String
    var apply: @Sendable (_ stem: String, _ index: Int, _ file: FileEntry) -> String
}

private func slug(_ value: String, _ separator: String) -> String {
    Rx("[^a-z0-9]+", "i").split(Rx("([a-z0-9])([A-Z])").replaceAll(value, "$1 $2").lowercased()).filter { !$0.isEmpty }.joined(separator: separator)
}

let NAMING_SCHEMES: [NamingScheme] = [
    NamingScheme(id: "kebab", description: "Lower case with hyphens, e.g. \"quarterly-report-final.pdf\".", apply: { stem, _, _ in slug(stem, "-") }),
    NamingScheme(id: "snake", description: "Lower case with underscores, e.g. \"quarterly_report_final.pdf\".", apply: { stem, _, _ in slug(stem, "_") }),
    NamingScheme(id: "title", description: "Title Case With Spaces, e.g. \"Quarterly Report Final.pdf\".", apply: { stem, _, _ in
        slug(stem, " ").jsSplit(" ").map(\.capitalizedFirst).joined(separator: " ")
    }),
    NamingScheme(id: "date_prefix", description: "Prefixed with the date the file was last changed, e.g. \"2026-09-20-report.pdf\".", apply: { stem, _, file in
        "\(JSDate(file.modifiedAt).toISOString().jsSlice(0, 10))-\(slug(stem, "-"))"
    }),
    NamingScheme(id: "numbered", description: "Numbered in order, e.g. \"01-report.pdf\", \"02-notes.pdf\".", apply: { stem, index, _ in
        "\(String(index + 1).jsPadStart(2, "0"))-\(slug(stem, "-"))"
    })
]

func localNamingScheme(_ request: String) -> String {
    let r = request.lowercased()
    if Rx("\\bdate\\b").test(r) { return "date_prefix" }
    if Rx("\\bnumber|sequential|order\\b").test(r) { return "numbered" }
    if Rx("\\bunderscore|snake\\b").test(r) { return "snake" }
    if Rx("\\btitle case|capitali[sz]e\\b").test(r) { return "title" }
    return "kebab"
}

public let renameWorkflow = Workflow(
    id: "rename_batch",
    description: "Rename a group of files so they follow one consistent naming pattern.",
    routes: ["files"],
    plausible: { request, _ in Rx("\\b(rename|renaming|consistent|naming|name these|tidy up the names)\\b", "i").test(request) },
    run: { request, droppedPaths, ctx in
        let files = try await collectFiles(droppedPaths, ctx)
        if files.isEmpty {
            return WorkflowResult(success: false, headline: "Which files should I rename? Drop them on me, or name a folder.",
                                  handoffToPlanner: "no files were identified to rename")
        }

        ctx.progress("Choosing a naming pattern")
        let answers = await ctx.ask(
            "choose_scheme",
            ["userRequest": .string(request), "currentNames": JSON(files.prefix(40).map(\.name))],
            [("scheme", .choice("Which naming pattern does the user want these files renamed to?", NAMING_SCHEMES.map { ($0.id, $0.description) }))]
        )

        let schemeId = answers?["scheme"]?.choice ?? localNamingScheme(request)
        let known = NAMING_SCHEMES.first { $0.id == schemeId }
        let scheme = known ?? NAMING_SCHEMES[0]
        ctx.log(.info, "renaming with the \"\(schemeId)\" pattern")

        // Sorting by name first makes "numbered" stable and predictable.
        let ordered = files.enumerated().sorted { a, b in
            let order = a.element.name.compare(b.element.name, locale: Locale(identifier: "en"))
            return order != .orderedSame ? order == .orderedAscending : a.offset < b.offset
        }.map(\.element)
        let ops: [FileOp] = ordered.enumerated().compactMap { index, file in
            let ext = Path.extname(file.name)
            let stem = Path.basename(file.name, ext)
            let renamed = "\(scheme.apply(stem, index, file))\(ext.lowercased())"
            return renamed != file.name ? FileOp(from: file.path, to: Path.join(Path.dirname(file.path), renamed), kind: "rename") : nil
        }

        if ops.isEmpty {
            return WorkflowResult(success: true, headline: "These files already follow that pattern.",
                                  evidence: files.prefix(3).map { .path($0.name, $0.path) })
        }

        let approval = try await ctx.askUser(QuestionDraft(
            reason: .ambiguous,
            prompt: "Rename \(ops.count) \(plural(ops.count, "file"))?",
            allowFreeText: false,
            options: [QuestionOption(id: "approve", label: "Rename them"), QuestionOption(id: "reject", label: "Cancel")],
            preview: PreviewPayload(title: "Rename using the \"\(schemeId)\" pattern", fileOps: ops, note: known?.description)
        ))
        if approval.optionId != "approve" {
            return WorkflowResult(success: false, headline: "Cancelled. Nothing was renamed.", unresolved: "user declined")
        }

        ctx.progress("Renaming \(ops.count) files")
        var renamed = 0
        var failures: [String] = []
        for op in ops {
            try await ctx.checkpoint()
            let res = try await ctx.run("files_rename", ["from": .string(op.from), "to": .string(op.to), "onConflict": "rename"])
            if res.ok { renamed += 1 } else { failures.append("\(Path.basename(op.from)): \(res.error ?? "")") }
        }

        return WorkflowResult(
            success: failures.isEmpty,
            headline: failures.isEmpty
                ? "Renamed \(renamed) \(plural(renamed, "file")) to the \"\(schemeId)\" pattern."
                : "Renamed \(renamed) of \(ops.count); \(failures.count) failed.",
            evidence: [.path("Folder", Path.dirname(ops[0].from))],
            unresolved: failures.isEmpty ? nil : failures.prefix(3).joined(separator: "; ")
        )
    }
)

/// Dropped files are the selection; a dropped folder means its contents.
private func collectFiles(_ droppedPaths: [String], _ ctx: WorkflowContext) async throws -> [FileEntry] {
    var files: [FileEntry] = []
    let sources = droppedPaths.isEmpty ? Array(ctx.authorizedRoots().prefix(1)) : droppedPaths
    for path in sources {
        let inspected = try await ctx.run("files_inspect", ["path": .string(path)])
        guard inspected.ok, let json = inspected.result else { continue }
        let entry = FileEntry(json: json)
        if entry.kind == "file" { files.append(entry); continue }
        if entry.kind == "directory", let listed = try await listFolder(ctx, path) {
            files.append(contentsOf: listed.filter { $0.kind == "file" })
        }
    }
    return files
}
