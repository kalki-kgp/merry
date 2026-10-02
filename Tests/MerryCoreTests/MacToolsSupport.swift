import Foundation
@testable import MerryCore

// Kept apart from the tests: this toolchain cannot import Foundation and Testing in one file.

/// Answers bridge calls from canned results and writes down every call.
final class FakeMacBridge: MacBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var jxaReplies: [String: [JSON]]
    private var execReplies: [String: [JSON]]
    private var recorded: [JSON] = []
    private var folders: [String] = []

    init(jxa: JSON, exec: JSON) {
        jxaReplies = Dictionary(uniqueKeysWithValues: (jxa.objectValue?.pairs ?? []).map { ($0.key, $0.value.arrayValue ?? []) })
        execReplies = Dictionary(uniqueKeysWithValues: (exec.objectValue?.pairs ?? []).map { ($0.key, $0.value.arrayValue ?? []) })
    }

    var calls: [JSON] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// Scratch folders the shortcut tool handed to `shortcuts`.
    var leftoverFolders: [String] { lock.lock(); defer { lock.unlock() }; return folders.filter { FileManager.default.fileExists(atPath: $0) } }

    /// Writes a call down and hands back the next canned reply for it, if there is one.
    private func record(_ call: JSON, script: String? = nil, program: String? = nil, folder: String?) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
        if let folder { folders.append(folder) }
        if let script, let queue = jxaReplies[script], !queue.isEmpty { return jxaReplies[script]!.removeFirst() }
        if let program, let queue = execReplies[program], !queue.isEmpty { return execReplies[program]!.removeFirst() }
        return nil
    }

    func jxa(_ body: String, _ input: JSON, timeoutMs: Int) async throws -> JSON {
        let script = SCRIPTS.name(of: body) ?? "(unknown script)"
        let call: JSON = ["type": "jxa", "script": .string(script), "input": .string(input.stringify()), "timeoutMs": JSON(timeoutMs)]
        guard let reply = record(call, script: script, folder: nil) else { throw ScriptError("no canned result for \(script)") }
        if let error = reply.optStr("error") { throw ScriptError(error) }
        return reply["ok"] ?? .null
    }

    func exec(_ program: String, _ args: [String], timeoutMs: Int) async -> (stdout: String, stderr: String, code: Int) {
        let scratch = Rx("^.*/merry-shortcut-[^/]+/")
        var call: JSON = ["type": "exec", "program": .string(program), "args": JSON(args.map { scratch.replaceFirst($0, "<tmp>/") }), "timeoutMs": JSON(timeoutMs)]
        if let at = args.firstIndex(of: "--input-path") {
            call["inFile"] = JSON(try? String(contentsOfFile: args[at + 1], encoding: .utf8))
        }
        let folder = args.firstIndex(of: "--output-path").map { Path.dirname(args[$0 + 1]) }
        guard let reply = record(call, program: program, folder: folder) else { return ("", "no canned result for \(program)", 1) }
        if let text = reply.optStr("writeOutput"), let at = args.firstIndex(of: "--output-path") {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: args[at + 1]))
        }
        return (reply.str("stdout"), reply.str("stderr"), reply.optInt("code") ?? 0)
    }
}

/// What a tool told the person, in order, and a clock that moves only when a tool waits.
final class MacRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [JSON] = []
    private var answers: [JSON]
    private var clock = 1_790_000_000_000.0

    init(answers: [JSON]) { self.answers = answers }

    var events: [JSON] { lock.lock(); defer { lock.unlock() }; return list }
    var now: Double { lock.lock(); defer { lock.unlock() }; return clock }
    func add(_ event: JSON) { lock.lock(); list.append(event); lock.unlock() }
    func slept(_ ms: Int) { lock.lock(); clock += Double(ms); list.append(["t": "sleep", "ms": JSON(ms)]); lock.unlock() }
    func nextAnswer() -> String? {
        lock.lock(); defer { lock.unlock() }
        return answers.isEmpty ? nil : answers.removeFirst().stringValue
    }
}

func macScopeJSON(_ scope: ScopeRequest) -> JSON {
    switch scope {
    case .read(let path): return ["kind": "read", "path": .string(path)]
    case .write(let path): return ["kind": "write", "path": .string(path)]
    case .app(let name): return ["kind": "app", "name": .string(name)]
    case .origin(let url): return ["kind": "origin", "url": .string(url)]
    case .capability(let name): return ["kind": "capability", "name": .string(name)]
    }
}

func macOutcomeJSON(_ outcome: ToolOutcome) -> JSON {
    [
        "result": outcome.result,
        "undo": .array(outcome.undo.map { ["kind": .string($0.kind.rawValue), "payload": ["from": .string($0.payload.from), "to": .string($0.payload.to)]] }),
        "evidence": .array(outcome.evidence.map { ["kind": .string($0.kind.rawValue), "label": .string($0.label), "value": .string($0.value)] }),
        "uncertain": .bool(outcome.uncertain)
    ]
}

func macVerificationJSON(_ v: VerificationResult) -> JSON {
    ["verified": .bool(v.verified), "method": .string(v.method), "detail": .string(v.detail)]
}
