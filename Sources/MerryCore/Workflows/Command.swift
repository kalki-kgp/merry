import Foundation

// "Make a folder called automaton in dev and open it in Zed."
//
// Read entirely in code. This is the shape where a planning model is worst
// value for money: the sentence is simple, the actions are few, and the user
// is standing there waiting; several seconds of planning to run one mkdir is
// absurd. Local patterns produce the steps; the macOS index resolves which
// folder and which application was meant; Jev is asked only when more than
// one real candidate exists, choosing between things this code found.

enum CommandStep: Equatable {
    case mkdir(path: String, label: String)
    case open(path: String, app: String?, label: String)
    case shell(program: String, args: [String], label: String)

    var label: String {
        switch self {
        case .mkdir(_, let label), .open(_, _, let label), .shell(_, _, let label): return label
        }
    }
}

struct CommandPlan: Equatable {
    var steps: [CommandStep] = []
    /// A folder named in the sentence that could not be resolved locally.
    var unresolvedFolder: String?
    /// An application named in the sentence that could not be resolved.
    var unresolvedApp: String?
}

private let makeFolder = Rx("\\b(?:create|make|add|new)\\s+(?:a\\s+)?(?:new\\s+)?(?:folder|directory|dir)\\s+(?:called|named|with the name)?\\s*[\"'`]?([\\w .\\-]+?)[\"'`]?(?:\\s+(?:in|inside|under|within|at)\\s+(?:the\\s+)?[\"'`]?([\\w /.\\-~]+?)[\"'`]?(?:\\s+folder)?)?\\s*(?:,|\\.|$|and\\b)", "i")
private let openIn = Rx("\\bopen\\s+(?:it|that|this|them|[\"'`]?([\\w /.\\-~]+?)[\"'`]?)\\s+(?:in|with|using)\\s+(?:the\\s+)?[\"'`]?([\\w .\\-]+?)[\"'`]?(?:\\s+(?:editor|app|application))?\\s*(?:,|\\.|$|and\\b)", "i")
private let literal = Rx("^\\s*(?:run|execute|exec)\\s+[\"'`]?(.+?)[\"'`]?\\s*$", "i")

public let commandWorkflow = Workflow(
    id: "run_command",
    description: "Create folders, open things in a chosen application, or run one simple safe command.",
    routes: ["files", "desktop", "mixed", "unclear"],
    plausible: { request, _ in makeFolder.test(request) || openIn.test(request) || literal.test(request) },
    run: { request, droppedPaths, ctx in
        let plan = await buildCommandPlan(request, droppedPaths, ctx)

        if plan.steps.isEmpty {
            return WorkflowResult(success: false, headline: "I could not work out what to run.",
                                  handoffToPlanner: plan.unresolvedFolder.map { "could not find a folder called \"\($0)\"" } ?? "no command could be parsed from the request")
        }

        var evidence: [Evidence] = []
        var done: [String] = []
        for step in plan.steps {
            try await ctx.checkpoint()
            ctx.progress(step.label)

            let res: WorkflowRun
            switch step {
            case .mkdir(let path, _): res = try await ctx.run("files_create_folder", ["path": .string(path)])
            case .open(let path, let app, _): res = try await ctx.run("app_open", .obj(["path": .string(path), "app": app.map(JSON.string)]))
            case .shell(let program, let args, _): res = try await ctx.run("shell_run", ["program": .string(program), "args": JSON(args)])
            }

            if !res.ok {
                return WorkflowResult(success: false, headline: "\(step.label) failed: \(res.error ?? "unknown error")", evidence: evidence,
                                      unresolved: done.isEmpty ? nil : "already done: \(done.joined(separator: ", "))")
            }
            done.append(step.label)
            if case .mkdir(let path, _) = step { evidence.append(.path(Path.basename(path), path)) }
            if case .shell(let program, _, _) = step {
                let out = (res.result?.optStr("stdout") ?? "").jsTrimmed
                if !out.isEmpty { evidence.append(.text("\(program) said", out.jsSlice(0, 600))) }
            }
        }
        return WorkflowResult(success: true, headline: done.joined(separator: ", then ") + ".", evidence: evidence)
    }
)

typealias FolderResolver = (String, WorkflowContext) async -> String?
typealias AppResolver = (String, WorkflowContext) async -> String?

/// Turns the sentence into steps.
func buildCommandPlan(_ request: String, _ droppedPaths: [String], _ ctx: WorkflowContext,
                      folder: FolderResolver = resolveFolder, app: AppResolver = resolveApp) async -> CommandPlan {
    var plan = CommandPlan()
    let home = Path.home

    if let m = literal.exec(request) {
        let parts = splitArgs(m[1] ?? "")
        if let program = parts.first {
            do {
                let vetted = try vetCommand(program, Array(parts.dropFirst()))
                plan.steps.append(.shell(program: vetted.program, args: vetted.args, label: "ran \(vetted.program) \(vetted.args.joined(separator: " "))".jsTrimmed))
            } catch {
                ctx.log(.warn, "refused: \(messageOf(error))")
            }
            return plan
        }
    }

    var created: String?
    if let make = makeFolder.exec(request) {
        let name = (make[1] ?? "").jsTrimmed
        let location = make[2]?.jsTrimmed
        let parent: String?
        if let location, !location.isEmpty { parent = await folder(location, ctx) } else { parent = home }
        if let location, !location.isEmpty, parent == nil {
            plan.unresolvedFolder = location
            return plan
        }
        let made = Path.join(parent ?? home, name)
        created = made
        plan.steps.append(.mkdir(path: made, label: "made \(name) in \(short(parent ?? home))"))
    }

    if let open = openIn.exec(request) {
        let what = open[1]?.jsTrimmed
        let appName = (open[2] ?? "").jsTrimmed
        // "open it in Zed" means the folder just created, or what was dropped.
        let target: String?
        if let what, !what.isEmpty, !Rx("^(it|that|this|them)$", "i").test(what) {
            if let found = await folder(what, ctx) { target = found } else { target = Path.isAbsolute(what) ? what : nil }
        } else {
            target = created ?? droppedPaths.first
        }
        guard let target else {
            plan.unresolvedFolder = what ?? "the thing to open"
            return plan
        }
        guard let resolved = await app(appName, ctx) else {
            plan.unresolvedApp = appName
            return plan
        }
        plan.steps.append(.open(path: target, app: resolved, label: "opened \(Path.basename(target)) in \(resolved)"))
    }
    return plan
}

/// Finds the folder the user meant.
///
/// Tries the obvious literal places first, because "dev" almost always means
/// ~/dev and a hit there costs nothing. Only when several real candidates
/// exist does Jev pick between them, and it picks from paths this code found,
/// never a path it invented.
func resolveFolder(_ name: String, _ ctx: WorkflowContext) async -> String? {
    let home = Path.home
    let cleaned = Rx("/$").replaceFirst(Rx("^~/").replaceFirst(name, ""), "").jsTrimmed
    if Path.isAbsolute(name), isDirectory(name) { return name }
    if cleaned.hasPrefix("~") {
        let expanded = Path.join(home, String(cleaned.dropFirst()))
        if isDirectory(expanded) { return expanded }
    }

    let direct = Path.join(home, cleaned)
    if isDirectory(direct) { return direct }
    for common in ["Documents", "Desktop", "Downloads", "Developer", "Projects"] {
        let candidate = Path.join(home, common, cleaned)
        if isDirectory(candidate) { return candidate }
    }

    let found = await findDirectories(cleaned)
    if found.isEmpty { return nil }
    if found.count == 1 { return found[0] }

    let criteria = found.prefix(5).enumerated().map { (String($0.offset), short($0.element)) }
    let answers = await ctx.ask("which_folder", ["folderName": .string(cleaned), "candidates": JSON(Array(found.prefix(5)))],
                                [("folder", .choice("Which of these is the \"\(cleaned)\" folder the user means?", criteria))])
    if let picked = answers?["folder"]?.choice.flatMap(Int.init), found.indices.contains(picked) { return found[picked] }
    // No Jev, or an unusable answer: the shallowest path is the best guess.
    return found.ecmaSorted { $0.jsSplit("/").count < $1.jsSplit("/").count }.first
}

/// Matches an application name against what is actually installed.
func resolveApp(_ name: String, _ ctx: WorkflowContext) async -> String? {
    let apps = await installedApps()
    let wanted = Rx("\\s+(editor|app|application)$").replaceFirst(name.lowercased(), "")
    if let exact = apps.first(where: { $0.lowercased() == wanted }) { return exact }
    let starts = apps.filter { $0.lowercased().hasPrefix(wanted) }
    if starts.count == 1 { return starts[0] }
    let contains = apps.filter { $0.lowercased().contains(wanted) }
    if contains.count == 1 { return contains[0] }
    let candidates = Array((starts + contains).unique.prefix(5))
    if candidates.isEmpty { return nil }

    let criteria = candidates.enumerated().map { (String($0.offset), $0.element) }
    let answers = await ctx.ask("which_app", ["appName": .string(name), "candidates": JSON(candidates)],
                                [("app", .choice("Which installed application does \"\(name)\" mean?", criteria))])
    if let picked = answers?["app"]?.choice.flatMap(Int.init), candidates.indices.contains(picked) { return candidates[picked] }
    return candidates[0]
}

private func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

private func findDirectories(_ name: String) async -> [String] {
    let paths = await mdfind(["-onlyin", Path.home, "kMDItemContentType == \"public.folder\" && kMDItemFSName == \"\(name.replacingOccurrences(of: "\"", with: ""))\"cd"])
    return Array(paths.filter { !$0.contains("/Library/") && !$0.contains("/node_modules/") && !$0.contains("/.") }.prefix(8))
}

private final class AppCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]?
    var value: [String]? {
        get { lock.lock(); defer { lock.unlock() }; return names }
        set { lock.lock(); names = newValue; lock.unlock() }
    }
}

private let appCache = AppCache()

private func installedApps() async -> [String] {
    if let cached = appCache.value { return cached }
    let paths = await mdfind(["kMDItemContentType == \"com.apple.application-bundle\""])
    let names = paths.map { Rx("\\.app$").replaceFirst(Path.basename($0), "") }.unique
    appCache.value = names
    return names
}

private func mdfind(_ args: [String]) async -> [String] {
    guard let r = try? await Exec.run("/usr/bin/mdfind", args, timeoutMs: 8000, maxBytes: 16 * 1024 * 1024) else { return [] }
    return r.stdout.jsSplit("\n").filter { !$0.isEmpty }
}

/// Splits a dictated command into argv, honouring quotes but expanding nothing.
func splitArgs(_ line: String) -> [String] {
    Rx("\"([^\"]*)\"|'([^']*)'|(\\S+)").all(line).map { $0[1] ?? $0[2] ?? $0[3] ?? "" }
}

private func short(_ path: String) -> String {
    let home = Path.home
    guard let range = path.range(of: home) else { return path }
    return path.replacingCharacters(in: range, with: "~")
}
