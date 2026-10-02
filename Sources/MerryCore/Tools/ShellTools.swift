import Foundation

// Running things on the command line.
//
// The dangerous way to build this is to let a model write a shell string and
// hand it to `sh -c`. Then one confused sentence, or one instruction hidden
// in a web page, is arbitrary code execution. That does not happen here:
//
//  - There is no shell. Commands run through `Exec.run` with an argument
//    array, so pipes, redirects, `;`, backticks and `$(...)` are inert text,
//    not syntax.
//  - Only the programs on `allowed` can run, and the list holds nothing that
//    deletes, escalates, or fetches-and-executes. `rm`, `sudo`, `curl` and
//    friends are absent by design, not filtered out afterwards.
//  - Every path argument, and the folder the command runs in, must resolve
//    inside the user's home folder, never into a protected location, and
//    inside what the task has been allowed to read or write.
//  - Programs that run code (node, python3, npm) can do anything the user
//    can, so no folder grant covers them: the user is shown the exact command
//    and asked every single time.

private struct Allowed {
    /// Arguments that make this program change something on disk.
    var mutates: Bool
    /// Runs arbitrary code, so it is confirmed with the user every time.
    var runsCode = false
    /// Refuse these arguments outright, whatever else the command says.
    var refuse: Rx?
    /// When set, the first non-flag argument must be one of these subcommands.
    var subcommands: Set<String>?
}

/// Git subcommands that neither rewrite history, reach into config, nor run external programs.
private let gitSubcommands: Set<String> = [
    "init", "status", "log", "diff", "show", "add", "commit", "branch", "switch", "stash", "tag",
    "mv", "blame", "shortlog", "rev-parse", "remote", "clone", "fetch", "pull", "ls-files", "grep"
]

// The patterns are the reference's, in JavaScript's meaning: `.` stops at a
// line break and `$` matches only at the very end of the argument.
private let allowed: [String: Allowed] = [
    "mkdir": Allowed(mutates: true),
    "touch": Allowed(mutates: true),
    "cp": Allowed(mutates: true, refuse: Rx("^-\(JSRx.dot)*f")),
    "mv": Allowed(mutates: true, refuse: Rx("^-\(JSRx.dot)*f")),
    "ls": Allowed(mutates: false),
    "pwd": Allowed(mutates: false),
    "cat": Allowed(mutates: false),
    "head": Allowed(mutates: false),
    "tail": Allowed(mutates: false),
    "wc": Allowed(mutates: false),
    "du": Allowed(mutates: false),
    "file": Allowed(mutates: false),
    "which": Allowed(mutates: false),
    // Opening a script, an installer or an app bundle is running it; see the launch check in vetCommand.
    "open": Allowed(mutates: false, refuse: Rx("^--args\(JSRx.end)")),
    "git": Allowed(
        mutates: true,
        // `-c`/`--config-env` set config for one run (aliases, core.sshCommand,
        // core.fsmonitor all execute programs); upload/receive-pack and ext::
        // URLs name a program for git to run.
        refuse: Rx("^(-c|--config-env\(JSRx.dot)*|--exec-path\(JSRx.dot)*|--upload-pack\(JSRx.dot)*|--receive-pack\(JSRx.dot)*|-u|--exec\(JSRx.dot)*|--template\(JSRx.dot)*|ext::\(JSRx.dot)*|fd::\(JSRx.dot)*)\(JSRx.end)"),
        subcommands: gitSubcommands
    ),
    "npm": Allowed(mutates: true, runsCode: true, refuse: Rx("^(publish|unpublish|login|logout|adduser|token|owner|access|deprecate|dist-tag)\(JSRx.end)")),
    "node": Allowed(mutates: true, runsCode: true),
    "python3": Allowed(mutates: true, runsCode: true),
    "echo": Allowed(mutates: false),
    "date": Allowed(mutates: false),
    "whoami": Allowed(mutates: false)
]

/// Opening these is launching them. Case-insensitive: run over `JSRx.asciiLower`.
private let launches = Rx("\\.(app|command|tool|sh|zsh|bash|csh|pkg|mpkg|terminal|workflow|scpt|scptd|applescript|jar|webloc|inetloc|fileloc)/?\(JSRx.end)")
/// `/^[a-z][a-z0-9+.-]*:/i` and `/^https?:\/\//i`, over `JSRx.asciiLower`.
private let hasScheme = Rx("^[a-z][a-z0-9+.\\-]*:")
private let isWeb = Rx("^https?://")

public struct RefusedCommand: Error, LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public struct ParsedCommand: Equatable, Sendable {
    public var program: String
    public var args: [String]
    public var mutates: Bool
    public var runsCode: Bool
    public var cwd: String
    /// Absolute paths the arguments name, in order.
    public var paths: [String]

    public init(program: String, args: [String], mutates: Bool, runsCode: Bool, cwd: String, paths: [String]) {
        self.program = program; self.args = args; self.mutates = mutates; self.runsCode = runsCode; self.cwd = cwd; self.paths = paths
    }
}

private func looksLikePath(_ arg: String) -> Bool {
    arg.contains("/") || Path.isAbsolute(arg) || arg.hasPrefix("~")
}

private func insideHome(_ full: String, _ shown: String) throws {
    if isForbidden(full) { throw RefusedCommand("\(shown) is in a protected location.") }
    if !isWithin(Path.home, full) {
        throw RefusedCommand("\(shown) is outside your home folder, so I will not touch it.")
    }
}

/// True when a path is an app, a script, an installer, or any file marked executable.
public func wouldLaunch(_ path: String) -> Bool {
    if launches.test(JSRx.asciiLower(path)) { return true }
    guard let st = try? NodeFS.stat(path) else { return false }
    return st.isFile && (st.mode & 0o111) != 0
}

/// Checks one command against the rules above.
///
/// Public because this is the security boundary, and a boundary that is not
/// directly tested is not a boundary.
public func vetCommand(_ program: String, _ args: [String], _ cwd: String? = nil) throws -> ParsedCommand {
    var vetted = try vetCommandBaseline(program, args, cwd)
    try harden(&vetted)
    return vetted
}

/// Rules the reference's check does not have. Its patterns look at each
/// argument on its own and only in the spelling it expects, which leaves ways
/// round it: a flag and its value written as one argument, a global option
/// whose value is mistaken for the subcommand, a line break hiding the end of
/// an argument. Each rule here only ever refuses more.
private func harden(_ vetted: inout ParsedCommand) throws {
    let name = vetted.program
    let dir = vetted.cwd
    func refuse(_ arg: String) -> RefusedCommand { RefusedCommand("I will not run \(name) with \"\(arg)\".") }

    for arg in vetted.args {
        // No argument a person would write holds a line break or a control
        // character, and the patterns above stop reading at one. (A NUL is
        // refused when the command is about to run, with its own message.)
        if arg.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 0) || $0.value == 0x7F || $0.value == 0x2028 || $0.value == 0x2029 }) {
            throw refuse(arg.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(String.init).joined())
        }
    }

    // A path joined onto its flag (`--output=/etc/x`, `-C/etc`) is still a
    // path, and is held to the same places as one written on its own.
    for arg in vetted.args where arg.hasPrefix("-") {
        let value: String
        if let eq = arg.firstIndex(of: "=") { value = String(arg[arg.index(after: eq)...]) }
        else if !arg.hasPrefix("--"), arg.count > 2 { value = String(arg.dropFirst(2)) }
        else { continue }
        guard looksLikePath(value) else { continue }
        let full = normalizePath(Path.isAbsolute(value) || value.hasPrefix("~") ? value : Path.resolve(dir, value))
        try insideHome(full, value)
        if !vetted.paths.contains(full) { vetted.paths.append(full) }
    }

    guard name == "git" else { return }
    // The subcommand is the first argument, after at most `-C <folder>`. Any
    // other global option could carry a value that passes for a subcommand
    // while the real one hides behind it.
    var index = 0
    while index < vetted.args.count, vetted.args[index] == "-C" {
        guard index + 1 < vetted.args.count else { throw refuse("-C") }
        let folder = vetted.args[index + 1]
        let full = normalizePath(Path.isAbsolute(folder) || folder.hasPrefix("~") ? folder : Path.resolve(dir, folder))
        try insideHome(full, folder)
        if !vetted.paths.contains(full) { vetted.paths.append(full) }
        index += 2
    }
    guard index < vetted.args.count else { return }
    let sub = vetted.args[index]
    guard gitSubcommands.contains(sub) else { throw RefusedCommand("I will not run git \(sub).") }

    for arg in vetted.args[(index + 1)...] {
        let lower = JSRx.asciiLower(arg)
        // Config for one run, joined to its flag: aliases, pagers and
        // core.sshCommand all name programs for git to run.
        if lower.hasPrefix("-c") && arg.contains("=") && !arg.hasPrefix("--") { throw refuse(arg) }
        // Transports that run a program, however they are capitalised.
        if lower.hasPrefix("ext::") || lower.hasPrefix("fd::") { throw refuse(arg) }
        // `-u<program>` is --upload-pack for the commands that talk to a remote.
        if ["clone", "fetch", "pull"].contains(sub), arg.hasPrefix("-u"), !arg.hasPrefix("--") { throw refuse(arg) }
        // grep can hand its matches to a program.
        if sub == "grep", (arg.hasPrefix("-O") || lower.hasPrefix("--open-files-in-pager")) { throw refuse(arg) }
    }
}

/// The reference's check, kept as it was so it can be compared with the
/// reference case by case. `vetCommand` is what everything else calls.
func vetCommandBaseline(_ program: String, _ args: [String], _ cwd: String? = nil) throws -> ParsedCommand {
    let name = Path.basename(program)
    guard let rule = allowed[name] else {
        throw RefusedCommand(
            "I can only run a short list of safe programs, and \"\(name)\" is not one of them. "
                + "Run it yourself if you meant it."
        )
    }
    let home = Path.home
    let dir: String
    if let cwd, !cwd.isEmpty { dir = normalizePath(cwd) } else { dir = home }
    try insideHome(dir, dir)

    if let subcommands = rule.subcommands {
        if let sub = args.first(where: { !$0.hasPrefix("-") }), !sub.isEmpty, !subcommands.contains(sub) {
            throw RefusedCommand("I will not run \(name) \(sub).")
        }
    }

    func absolute(_ arg: String) -> String {
        normalizePath(Path.isAbsolute(arg) || arg.hasPrefix("~") ? arg : Path.resolve(dir, arg))
    }

    var paths: [String] = []
    for arg in args {
        if let refuse = rule.refuse, refuse.test(arg) {
            throw RefusedCommand("I will not run \(name) with \"\(arg)\".")
        }
        if name == "open" {
            let lower = JSRx.asciiLower(arg)
            if hasScheme.test(lower) && !isWeb.test(lower) {
                throw RefusedCommand("I only open files, folders and web pages, not \"\(arg)\".")
            }
            if isWeb.test(lower) { continue }
        }
        // An argument that looks like a path has to point somewhere allowed, even
        // when it is relative: `../../..` climbs out of the home folder too.
        if looksLikePath(arg) {
            let full = absolute(arg)
            try insideHome(full, arg)
            paths.append(full)
        }
    }
    if name == "open" {
        for arg in args {
            if arg.hasPrefix("-") { continue }
            let full = looksLikePath(arg) ? absolute(arg) : Path.resolve(dir, arg)
            if wouldLaunch(full) {
                throw RefusedCommand("Opening \(Path.basename(arg)) would run it, so I will not. Open it yourself if you trust it.")
            }
        }
    }
    return ParsedCommand(program: name, args: args, mutates: rule.mutates, runsCode: rule.runsCode, cwd: dir, paths: paths)
}

/// What the task must be allowed before a command runs. Reading needs read
/// access to everything it names; changing needs write access to what it
/// changes. Bare names resolve in the working folder, so that folder counts too.
public func commandScopes(_ vetted: ParsedCommand) -> [ScopeRequest] {
    let scopes: [ScopeRequest] = [vetted.mutates && vetted.paths.isEmpty ? .write(path: vetted.cwd) : .read(path: vetted.cwd)]
    if vetted.runsCode { return [.write(path: vetted.cwd)] }
    if !vetted.mutates { return scopes + vetted.paths.map { .read(path: $0) } }
    if vetted.program == "cp" {
        // A copy reads its sources and writes only where it lands.
        let last = vetted.paths.count - 1
        return scopes + vetted.paths.enumerated().map { $0.offset == last ? .write(path: $0.element) : .read(path: $0.element) }
    }
    return scopes + vetted.paths.map { .write(path: $0) }
}

private func vetInput(_ i: JSON) throws -> ParsedCommand {
    try vetCommand(i.str("program"), i.strings("args"), i.optStr("cwd"))
}

public let shellRun = ToolDefinition(
    name: "shell_run",
    description: "Run one command from a short allowlist of programs (mkdir, cp, mv, ls, cat, git, open and a few others; node, python3 and npm only with the user confirming each run). There is no shell: arguments are passed literally, so pipes, redirects and substitutions do not work. Anything destructive is refused.",
    capability: "shell.run",
    input: S.object([
        "program": S.string().describe("The program, e.g. \"mkdir\""),
        "args": S.array(S.string()).default([]).describe("Arguments, one per array entry, never a single joined string"),
        "cwd": S.string().optional().describe("Directory to run in; defaults to your home folder")
    ]),
    // A refused command asks for nothing and confirms nothing here: `execute`
    // vets it again before anything runs, and fails with the reason.
    scopes: { i in (try? vetInput(i)).map(commandScopes) ?? [] },
    confirm: { i in
        guard let vetted = try? vetInput(i), vetted.runsCode else { return nil }
        return "run `\(([vetted.program] + vetted.args).joined(separator: " "))` in \(vetted.cwd), which can change anything your account can"
    },
    execute: { i, ctx in
        let vetted = try vetInput(i)
        try withoutNulls(vetted.args, vetted.cwd)
        ctx.progress("Running \(vetted.program) \(vetted.args.joined(separator: " "))")
        let (stdout, stderr, code) = await run(vetted.program, vetted.args, vetted.cwd)
        _ = ctx.observe(
            "files",
            "\(vetted.program) \(vetted.args.joined(separator: " ")) → exit \(code)",
            ["program": .string(vetted.program), "code": JSON(code)],
            30_000
        )
        if code != 0 { throw MerryError(stderr.jsTrimmed.isEmpty ? "\(vetted.program) exited with \(code)" : stderr.jsTrimmed) }
        return ToolOutcome(["stdout": .string(stdout.jsSlice(0, 8000)), "stderr": .string(stderr.jsSlice(0, 2000)), "code": JSON(code)])
    },
    verify: { i, _, _ in
        // Nothing generic to check: each caller verifies its own effect.
        VerificationResult(verified: true, method: "exit-code", detail: "\(Path.basename(i.str("program"))) exited cleanly")
    }
)

public let appOpen = ToolDefinition(
    name: "app_open",
    description: "Open a file or folder in a specific application, the way double-clicking it would. Use the application name as it appears in the Applications folder, e.g. \"Zed\", \"Visual Studio Code\", \"Finder\".",
    capability: "shell.run",
    input: S.object([
        "path": S.string().describe("The file or folder to open"),
        "app": S.string().optional().describe("Application name; omit to use the system default")
    ]),
    scopes: { i in [.read(path: normalizePath(i.str("path")))] },
    execute: { i, ctx in
        let path = normalizePath(i.str("path"))
        if isForbidden(path) { throw MerryError("\(path) is in a protected location.") }
        if wouldLaunch(path) { throw MerryError("Opening \(Path.basename(path)) would run it, so I will not. Open it yourself if you trust it.") }
        let app = i.optStr("app")
        let named = app.flatMap { $0.isEmpty ? nil : $0 }
        let args = named.map { ["-a", $0, path] } ?? [path]
        try withoutNulls(args, Path.home)
        ctx.progress(named.map { "Opening \(Path.basename(path)) in \($0)" } ?? "Opening \(Path.basename(path))")
        let (_, stderr, code) = await run("open", args, Path.home)
        if code != 0 { throw MerryError(stderr.jsTrimmed.isEmpty ? "could not open \(Path.basename(path))" : stderr.jsTrimmed) }
        return ToolOutcome(["opened": .string(path), "app": .string(app ?? "default")])
    }
)

public let shellTools: [ToolDefinition] = [shellRun, appOpen]

/// An argument is handed to the program as a C string, which stops at the
/// first NUL: the program would see something shorter than what was vetted
/// (`-u` out of an argument that was not `-u`). `execFile` refuses to start
/// such a command, and so does this.
private func withoutNulls(_ args: [String], _ cwd: String) throws {
    for (index, arg) in args.enumerated() where arg.utf8.contains(0) {
        throw MerryError("The argument 'args[\(index)]' must be a string without null bytes. Received '\(arg.replacingOccurrences(of: "\0", with: "\\x00"))'")
    }
    if cwd.utf8.contains(0) {
        throw MerryError("The property 'options.cwd' must be a string without null bytes. Received '\(cwd.replacingOccurrences(of: "\0", with: "\\x00"))'")
    }
}

/// Runs a vetted program with its arguments as an array. There is no shell.
private func run(_ program: String, _ args: [String], _ cwd: String) async -> (stdout: String, stderr: String, code: Int) {
    // A program that cannot be found or started is a failed run, as it is for `execFile`.
    guard let path = Exec.which(program),
          let r = try? await Exec.run(path, args, cwd: cwd, env: Exec.environment(), timeoutMs: 60_000, maxBytes: 8 * 1024 * 1024)
    else { return ("", "", 1) }
    let code = r.timedOut || r.truncated ? 1 : Int(r.code)
    return (r.stdout, r.stderr, code)
}
