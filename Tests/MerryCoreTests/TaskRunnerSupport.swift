import Foundation
@testable import MerryCore

/// A planner that says what it was told to say, one proposal per step, and
/// keeps what the loop told it.
final class StepPlanner: PlannerLike, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [PlannerProposal]
    private(set) var notes: [String] = []
    private(set) var results: [[ToolResultInput]] = []
    private(set) var proposals = 0
    private(set) var offered: [[String]] = []
    var onPropose: (@Sendable (Int) -> Void)?

    init(_ steps: [PlannerProposal]) { self.steps = steps }

    static func call(_ name: String, _ input: JSON, id: String = newId()) -> PlannerProposal {
        PlannerProposal(calls: [.init(id: id, name: name, input: input)], stopReason: "tool_use", usd: 0.01, inputTokens: 100, outputTokens: 10)
    }
    static func calls(_ list: [(String, JSON)]) -> PlannerProposal {
        PlannerProposal(calls: list.map { .init(id: newId(), name: $0.0, input: $0.1) }, stopReason: "tool_use", usd: 0.01, inputTokens: 100, outputTokens: 10)
    }
    static func say(_ text: String) -> PlannerProposal { PlannerProposal(text: text, stopReason: "end_turn", usd: 0.01, inputTokens: 100, outputTokens: 10) }
    static func finish(_ headline: String, success: Bool = true) -> PlannerProposal {
        call("finish", ["success": .bool(success), "headline": .string(headline)])
    }

    func seed(task: TaskState, droppedPaths: [String]) {}
    func addToolResults(_ list: [ToolResultInput]) { lock.lock(); results.append(list); lock.unlock() }
    func addNote(_ note: String) { lock.lock(); notes.append(note); lock.unlock() }
    func propose(tools: [JSON]) async throws -> PlannerProposal {
        let (index, next) = withLock { () -> (Int, PlannerProposal?) in
            proposals += 1
            offered.append(tools.map { $0.str("name") })
            return (proposals, steps.isEmpty ? nil : steps.removeFirst())
        }
        onPropose?(index)
        // A script that runs out keeps asking for the same harmless thing, so limits can be reached.
        return next ?? StepPlanner.call("report_progress", ["line": "Still going"])
    }
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var allResults: [ToolResultInput] { withLock { results.flatMap { $0 } } }
    var allNotes: [String] { withLock { notes } }
    var proposalCount: Int { withLock { proposals } }
}

/// A planner that must never be asked: a workflow is supposed to do the whole job.
final class ForbiddenPlanner: PlannerLike, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    var timesAsked: Int { lock.lock(); defer { lock.unlock() }; return asked }
    func seed(task: TaskState, droppedPaths: [String]) {}
    func addToolResults(_ results: [ToolResultInput]) {}
    func addNote(_ note: String) {}
    private func count() { lock.lock(); asked += 1; lock.unlock() }
    func propose(tools: [JSON]) async throws -> PlannerProposal {
        count()
        return StepPlanner.finish("the planner should not have been called", success: false)
    }
}

/// Runs one task through the real runner and real tools, answering questions from a script.
final class RunnerBench: @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private var answers: [@Sendable (UserQuestion) -> AnswerPayload?]
    private(set) var questions: [UserQuestion] = []
    private(set) var petStates: [PetState] = []
    private(set) var logs: [LogEntry] = []
    private(set) var claims: [String] = []
    private var answered = Set<String>()
    private var runner: TaskRunner?

    init(answers: [@Sendable (UserQuestion) -> AnswerPayload?] = []) throws {
        let made = Path.join(Path.tmp, "merry-runner-\(newId())")
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        root = (try? NodeFS.realpath(made)) ?? made
        self.answers = answers
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    static func option(_ id: String) -> @Sendable (UserQuestion) -> AnswerPayload? { { q in AnswerPayload(questionId: q.id, optionId: id) } }

    func write(_ relative: String, _ text: String = "x") {
        let path = "\(root)/\(relative)"
        try? FileManager.default.createDirectory(atPath: Path.dirname(path), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: "\(root)/\(relative)") }

    var askedQuestions: [UserQuestion] { lock.lock(); defer { lock.unlock() }; return questions }
    var seenLogs: [LogEntry] { lock.lock(); defer { lock.unlock() }; return logs }

    /// A task with the scratch folder already allowed, unless told otherwise.
    func task(_ request: String, allow: Bool = true, limits: TaskLimits = TaskLimits()) -> TaskState {
        var auth = Authorization(capabilities: ["user.interact", "files.read"])
        if allow { auth.readRoots = [root]; auth.writeRoots = [root] }
        return TaskState(request: request, authorization: auth, limits: limits)
    }

    func deps(planner: PlannerLike?, dropped: [String] = [], configure: (inout RunnerDeps) -> Void = { _ in }) -> RunnerDeps {
        var deps = RunnerDeps(os: UnavailableOsAdapter(), browser: NoBrowser(), registry: ToolRegistry(allTools()))
        deps.jevEnabled = false
        deps.environment = [:]
        deps.droppedPaths = dropped
        if let planner { deps.createPlanner = { planner } }
        configure(&deps)
        return deps
    }

    func make(_ task: TaskState, _ deps: RunnerDeps, onUpdate: (@Sendable (TaskState, TaskRunner) -> Void)? = nil) -> TaskRunner {
        let box = RunnerBox()
        let hooks = RunnerHooks(
            onUpdate: { [weak self] state in
                guard let self, let runner = box.runner else { return }
                onUpdate?(state, runner)
                guard let question = state.question else { return }
                let reply = self.take(question)
                // Answered from another task, as the interface would.
                if let reply { Task.detached { runner.answer(reply) } }
            },
            onPetState: { [weak self] state in self?.note { $0.petStates.append(state) } },
            onLog: { [weak self] entry in self?.note { $0.logs.append(entry) } },
            claimDesktop: { [weak self] _, reason in self?.note { $0.claims.append(reason) } }
        )
        let runner = TaskRunner(task: task, deps: deps, hooks: hooks)
        box.runner = runner
        self.runner = runner
        return runner
    }

    private func note(_ change: (RunnerBench) -> Void) { lock.lock(); change(self); lock.unlock() }

    private func take(_ question: UserQuestion) -> AnswerPayload? {
        lock.lock(); defer { lock.unlock() }
        guard answered.insert(question.id).inserted else { return nil }
        questions.append(question)
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst()(question)
    }
}

final class RunnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: TaskRunner?
    var runner: TaskRunner? {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); held = newValue; lock.unlock() }
    }
}
