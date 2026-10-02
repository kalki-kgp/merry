import Foundation

/// Talks to Mac apps through their scripting dictionaries (JXA) and a few
/// command-line tools (`shortcuts`, `pbpaste`).
///
/// This is the fastest and most reliable way Merry can act on an app: creating
/// a reminder through Reminders' own scripting interface takes a fraction of a
/// second and either works or says why, where clicking through its window is
/// slow and breaks whenever the layout changes. The desktop tools remain for
/// apps that have no dictionary.
///
/// Every script receives its input as one JSON argument and never through
/// string interpolation, so nothing in a request can become script source.
public protocol MacBridge: Sendable {
    /// Runs a JXA function body with `input` in scope and returns what it returned.
    func jxa(_ body: String, _ input: JSON, timeoutMs: Int) async throws -> JSON
    func exec(_ program: String, _ args: [String], timeoutMs: Int) async -> (stdout: String, stderr: String, code: Int)
}

extension MacBridge {
    public func jxa(_ body: String, _ input: JSON = [:]) async throws -> JSON { try await jxa(body, input, timeoutMs: 20_000) }
    public func exec(_ program: String, _ args: [String]) async -> (stdout: String, stderr: String, code: Int) {
        await exec(program, args, timeoutMs: 60_000)
    }
}

public struct ScriptError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Turns osascript's error text into something a person can act on.
public func explainScriptError(_ stderr: String, app: String? = nil) -> String {
    let who = app ?? Rx("Application\\(\"?([^\")]+)").exec(stderr)?[1] ?? "that app"
    if Rx("-1743|not authori[sz]ed to send apple events", "i").test(stderr) {
        return "Merry isn't allowed to control \(who) yet. Allow it in System Settings → Privacy & Security → Automation."
    }
    if Rx("-1719|assistive access|not allowed assistive", "i").test(stderr) {
        return "Merry needs Accessibility permission for that. Allow it in System Settings → Privacy & Security → Accessibility."
    }
    if Rx("JavaScript through AppleScript is turned off|Allow JavaScript from Apple Events|JavaScript from Apple Events", "i").test(stderr) {
        return Rx("safari", "i").test(stderr)
            ? "Safari needs one setting first: Safari → Settings → Advanced → \"Show features for web developers\", then Develop → \"Allow JavaScript from Apple Events\"."
            : "Your browser needs one setting first: in its menu bar, View → Developer → \"Allow JavaScript from Apple Events\". Merry only reads the page; it never clicks or types in it."
    }
    if Rx("-600|isn.t running|application isn.t running", "i").test(stderr) { return "\(who) isn't running." }
    if Rx("can.t get|doesn.t understand|-1728", "i").test(stderr) { return "\(who) couldn't find what was asked for." }
    let line = Rx("\\s*\\(-?\\d+\\)\\s*$").replaceFirst(Rx("^.*execution error:\\s*", "s").replaceFirst(stderr, ""), "").jsTrimmed
    return line.isEmpty ? "the script failed without saying why" : line
}

/// The real bridge: `osascript` for scripts, the program itself for everything else.
public struct OsascriptBridge: MacBridge {
    public init() {}

    private func run(_ program: String, _ args: [String], timeoutMs: Int) async -> (stdout: String, stderr: String, code: Int) {
        guard let path = Exec.which(program) else { return ("", "\(program): command not found", 127) }
        do {
            let r = try await Exec.run(path, args, env: Exec.environment(), timeoutMs: timeoutMs, maxBytes: 16 * 1024 * 1024)
            return (r.stdout, r.stderr, r.timedOut ? 1 : Int(r.code))
        } catch {
            return ("", messageOf(error), 1)
        }
    }

    public func jxa(_ body: String, _ input: JSON, timeoutMs: Int) async throws -> JSON {
        let script = "function run(argv) { const input = JSON.parse(argv[0]); return JSON.stringify((function () { \(body) })() ?? null) }"
        let result = await run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script, input.stringify()], timeoutMs: timeoutMs)
        if result.code != 0 { throw ScriptError(explainScriptError(result.stderr)) }
        let text = result.stdout.jsTrimmed
        return text.isEmpty ? .null : try JSON.parse(text)
    }

    public func exec(_ program: String, _ args: [String], timeoutMs: Int) async -> (stdout: String, stderr: String, code: Int) {
        await run(program, args, timeoutMs: timeoutMs)
    }
}

private let bridgeLock = NSLock()
nonisolated(unsafe) private var currentBridge: MacBridge = OsascriptBridge()

public func macBridge() -> MacBridge {
    bridgeLock.lock(); defer { bridgeLock.unlock() }
    return currentBridge
}

/// Swaps the bridge. Tests use this so the suite never drives real apps.
public func setMacBridge(_ next: MacBridge) {
    bridgeLock.lock(); defer { bridgeLock.unlock() }
    currentBridge = next
}
