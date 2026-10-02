import Foundation
@testable import MerryCore

/// A browser whose page is a script: each evaluated expression is answered by
/// a closure, and everything asked of it is recorded.
final class FakeBrowser: BrowserSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var _uploads: [(ref: String, path: String, timeoutMs: Int)] = []
    private var _downloads: [(ref: String, saveTo: String?, timeoutMs: Int)] = []
    private var _navigations: [(url: String, waitUntil: String, timeoutMs: Int)] = []
    private var _url: String

    let answer: @Sendable (String) throws -> JSON
    var landing: BrowserNavigation?
    var downloadResult = BrowserDownload(path: "/nowhere/file.bin", suggestedFilename: "file.bin")

    init(url: String = "https://example.com/start", answer: @escaping @Sendable (String) throws -> JSON = { _ in .null }) {
        _url = url
        self.answer = answer
    }

    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var scripts: [String] { locked { _scripts } }
    var uploads: [(ref: String, path: String, timeoutMs: Int)] { locked { _uploads } }
    var downloads: [(ref: String, saveTo: String?, timeoutMs: Int)] { locked { _downloads } }
    var navigations: [(url: String, waitUntil: String, timeoutMs: Int)] { locked { _navigations } }

    var isOpen: Bool { true }
    func close() async {}
    func navigate(_ url: String, waitUntil: String, timeoutMs: Int) async throws -> BrowserNavigation {
        let landed = landing ?? BrowserNavigation(url: url, status: 200, title: "Page")
        locked { _navigations.append((url, waitUntil, timeoutMs)); _url = landed.url }
        return landed
    }
    func currentURL() async throws -> String { locked { _url } }
    func title() async throws -> String { "Page" }
    func evaluate(_ script: String) async throws -> JSON {
        locked { _scripts.append(script) }
        return try answer(script)
    }
    func waitForLoad(timeoutMs: Int) async {}
    func setInputFiles(ref: String, path: String, timeoutMs: Int) async throws { locked { _uploads.append((ref, path, timeoutMs)) } }
    func download(clickingRef ref: String, saveTo: String?, timeoutMs: Int) async throws -> BrowserDownload {
        locked { _downloads.append((ref, saveTo, timeoutMs)) }
        return downloadResult
    }
}

final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var values: [T] { all }
}

/// True for the script that counts the elements carrying a reference.
func isCount(_ script: String) -> Bool { script.hasSuffix(".length") }

func context(
    _ browser: BrowserSession,
    progress: Recorder<String> = Recorder(),
    observations: Recorder<Observation> = Recorder(),
    ask: @escaping @Sendable (QuestionDraft) async throws -> UserAnswer = { _ in UserAnswer() }
) -> ToolContext {
    ToolContext(
        task: { TaskState(request: "test") },
        os: UnavailableOsAdapter(),
        browser: browser,
        progress: { progress.add($0) },
        observe: { kind, summary, data, stale in
            let o = Observation(id: newId(), kind: kind, summary: summary, data: data, observedAt: nowMs(), staleAfterMs: stale)
            observations.add(o)
            return o
        },
        ask: ask
    )
}

func run(_ tool: ToolDefinition, _ input: JSON, _ ctx: ToolContext) async throws -> ToolOutcome {
    let i = try tool.input.parse(input)
    try await tool.precondition?(i, ctx)
    return try await tool.execute(i, ctx)
}

func browserFailure(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch { return messageOf(error) }
}

func temporaryFolder() -> String {
    let path = Path.join(Path.tmp, "merry-browser-tools-\(newId())")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    // The temp folder is reached through a symlink; scopes compare real text.
    return path
}

func writeText(_ path: String, _ text: String) {
    try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

func removeTree(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

func isFolder(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}
