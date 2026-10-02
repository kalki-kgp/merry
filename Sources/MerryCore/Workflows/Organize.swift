import Foundation

/// "Organise this folder."
///
/// Local code enumerates every candidate grouping: by file type, by a project
/// name that recurs across filenames, or by month. Jev picks which of those
/// fits, then assigns each file to one of the resulting folders. Nothing is
/// invented by a model: every folder name comes from the files themselves or
/// from the fixed type table.
public let organizeWorkflow = Workflow(
    id: "organize_folder",
    description: "Tidy a folder by moving its files into subfolders, grouped by type, project or date.",
    routes: ["files"],
    plausible: { request, droppedPaths in
        if !droppedPaths.isEmpty { return true }
        return Rx("\\b(organi[sz]e|tidy|sort|clean ?up|group|arrange|declutter)\\b", "i").test(request)
    },
    run: { request, droppedPaths, ctx in
        guard let target = pickTargetFolder(droppedPaths, ctx) else {
            return WorkflowResult(success: false, headline: "Which folder should I organise?",
                                  handoffToPlanner: "no folder was identified from the request or the dropped files")
        }

        ctx.progress("Looking through the folder")
        guard let entries = try await listFolder(ctx, target) else {
            return WorkflowResult(success: false, headline: "I could not read \(target).", unresolved: "folder unreadable")
        }

        let files = entries.filter { $0.kind == "file" }
        if files.count < 2 {
            return WorkflowResult(success: true, headline: "Nothing to do: \(target) has \(files.count) \(plural(files.count, "file")) in it.",
                                  evidence: [.path("Folder", target)])
        }

        // --- Enumerate strategies locally, then let Jev pick one. ---------------
        let projects = candidateProjectGroups(files)
        let months = candidateDateGroups(files)
        let typesPresent = files.compactMap { typeGroupFor($0.ext) }.unique

        var strategies: [(String, String)] = []
        if typesPresent.count >= 2 {
            strategies.append(("type", "Group by kind of file: \(typesPresent.prefix(5).joined(separator: ", "))."))
        }
        if projects.count >= 2 {
            strategies.append(("project", "Group by project or subject, using names that recur in the filenames: \(projects.joined(separator: ", "))."))
        }
        if months.count >= 2 {
            strategies.append(("date", "Group by the month each file was last changed: \(months.prefix(4).joined(separator: ", "))."))
        }
        if strategies.isEmpty {
            return WorkflowResult(success: true, headline: "These \(files.count) files do not fall into obvious groups, so I left them alone.",
                                  evidence: [.path("Folder", target)])
        }

        ctx.progress("Working out the groups")
        var strategy = strategies[0].0
        let pick = await ctx.ask(
            "choose_grouping",
            ["userRequest": .string(request), "folder": .string(target), "fileNames": JSON(files.prefix(60).map(\.name))],
            [("strategy", .choice("Which way of grouping these files would the user most likely want?", strategies))]
        )
        if let chosen = pick?["strategy"]?.choice {
            strategy = chosen
            ctx.log(.info, "Jev chose grouping by \(strategy)", ["confidence": JSON(pick?["strategy"]?.confidence)])
        } else {
            // No Jev: prefer project grouping when the filenames suggest one, since
            // that is the more useful answer when it applies at all.
            let has: (String) -> Bool = { name in strategies.contains { $0.0 == name } }
            strategy = has("project") ? "project" : has("type") ? "type" : "date"
            ctx.log(.info, "Jev unavailable; grouping by \(strategy) using local rules")
        }

        // --- Assign files to the groups that strategy produced. -----------------
        let assignment = try await assignFiles(files, strategy, projects, ctx, request)
        let moves: [FileOp] = assignment.compactMap { file, group in
            group.map { FileOp(from: file.path, to: Path.join(target, $0, file.name), kind: "move") }
        }

        if moves.isEmpty {
            return WorkflowResult(success: true, headline: "Nothing needed moving.", evidence: [.path("Folder", target)])
        }

        // --- Preview, then act. -------------------------------------------------
        let groupNames = moves.map { op -> String in
            let parts = op.to.jsSplit("/")
            return parts.count >= 2 ? parts[parts.count - 2] : ""
        }.unique
        let approval = try await ctx.askUser(QuestionDraft(
            reason: .ambiguous,
            prompt: "Move \(moves.count) \(plural(moves.count, "file")) into \(groupNames.count) \(plural(groupNames.count, "folder"))?",
            allowFreeText: false,
            options: [QuestionOption(id: "approve", label: "Do it"), QuestionOption(id: "reject", label: "Cancel")],
            preview: PreviewPayload(title: "Organise \(target.jsSplit("/").last ?? "") by \(strategy)", fileOps: moves,
                                    note: "New folders: \(groupNames.joined(separator: ", "))")
        ))
        if approval.optionId != "approve" {
            return WorkflowResult(success: false, headline: "Cancelled. Nothing was moved.", unresolved: "user declined")
        }

        ctx.progress("Moving \(moves.count) files")
        var moved = 0
        var failures: [String] = []
        var createdFolders: [String] = []

        for group in groupNames {
            try await ctx.checkpoint()
            let folder = Path.join(target, group)
            let res = try await ctx.run("files_create_folder", ["path": .string(folder)])
            if res.ok { if !createdFolders.contains(folder) { createdFolders.append(folder) } }
            else { failures.append("could not create \(group): \(res.error ?? "")") }
        }

        for move in moves {
            try await ctx.checkpoint()
            let res = try await ctx.run("files_move", ["from": .string(move.from), "to": .string(move.to), "onConflict": "rename"])
            if res.ok { moved += 1 } else { failures.append("\(move.from.jsSplit("/").last ?? ""): \(res.error ?? "")") }
        }

        let evidence = [Evidence.path("Folder", target)] + createdFolders.map { Evidence.path($0.jsSplit("/").last ?? $0, $0) }
        return WorkflowResult(
            success: failures.isEmpty,
            headline: failures.isEmpty
                ? "Sorted \(moved) \(plural(moved, "file")) into \(groupNames.count) \(plural(groupNames.count, "folder"))."
                : "Moved \(moved) of \(moves.count) files; \(failures.count) did not move.",
            evidence: evidence,
            unresolved: failures.isEmpty ? nil : failures.prefix(3).joined(separator: "; ")
        )
    }
)

/// Picks the folder to work on from the drop, then from the request wording.
private func pickTargetFolder(_ droppedPaths: [String], _ ctx: WorkflowContext) -> String? {
    if droppedPaths.count == 1 { return droppedPaths[0] }
    if droppedPaths.count > 1 {
        // Several drops: their common parent is the folder being organised.
        let parts = droppedPaths[0].jsSplit("/")
        var common = ""
        if parts.count > 1 {
            for i in 1..<parts.count {
                let prefix = parts[0...i].joined(separator: "/")
                if droppedPaths.allSatisfy({ $0.hasPrefix(prefix + "/") || $0 == prefix }) { common = prefix }
            }
        }
        if !common.isEmpty { return common }
    }
    return ctx.authorizedRoots().first
}

/// Assigns each file to a group. Type and date grouping are pure functions of
/// the file, so no call is made at all; only project grouping is a judgment,
/// and that is the one Jev answers.
private func assignFiles(_ files: [FileEntry], _ strategy: String, _ projects: [String], _ ctx: WorkflowContext, _ request: String) async throws -> [(FileEntry, String?)] {
    if strategy == "type" { return files.map { ($0, typeGroupFor($0.ext)) } }
    if strategy == "date" { return files.map { ($0, dateGroupFor($0.modifiedAt)) } }

    // Project grouping: Jev chooses between the names local code derived.
    var criteria: [(String, String)] = [("unsorted", "Does not clearly belong to any of these projects.")]
    for p in projects { criteria.append((p, "Relates to \"\(p)\".")) }

    var out: [(FileEntry, String?)] = []
    let batchSize = 40
    var i = 0
    while i < files.count {
        try await ctx.checkpoint()
        let batch = Array(files[i..<min(i + batchSize, files.count)])
        let questions = batch.indices.map { ("f\($0)", JevQuestion.choice("Which project does file \($0) belong to?", criteria)) }
        let state: JSON = [
            "userRequest": .string(request),
            "files": .array(batch.enumerated().map { ["index": JSON($0.offset), "name": .string($0.element.name), "extension": .string($0.element.ext)] })
        ]
        let answers = await ctx.ask("assign_files", state, questions)
        for (idx, f) in batch.enumerated() {
            if let choice = answers?["f\(idx)"]?.choice, choice != "unsorted" {
                out.append((f, choice))
            } else {
                // Without Jev, fall back to a plain substring match on the filename.
                out.append((f, projects.first { f.name.lowercased().contains($0.lowercased()) }))
            }
        }
        i += batchSize
    }
    return out
}

/// Is this folder already tidy enough to leave alone?
func looksAlreadyTidy(_ files: [FileEntry], _ ctx: WorkflowContext) async -> Bool {
    let answers = await ctx.ask(
        "already_tidy",
        ["fileNames": JSON(files.prefix(40).map(\.name))],
        [("tidy", .noul("Is this folder already well organised, so that moving things would not help?"))]
    )
    return isYes(answers?["tidy"])
}
