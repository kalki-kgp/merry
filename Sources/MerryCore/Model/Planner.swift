import Foundation

/// What the planning model wants done at one step. Local code decides whether
/// any of it happens.
public struct PlannerProposal: Sendable {
    public struct Call: Sendable {
        public var id: String
        public var name: String
        public var input: JSON
        public init(id: String, name: String, input: JSON) { self.id = id; self.name = name; self.input = input }
    }

    public var calls: [Call]
    /// Any prose the model produced alongside the calls.
    public var text: String
    public var stopReason: String?
    /// Set when the model declined the request: its safety category, or "unspecified".
    public var refusal: String?
    public var usd: Double
    public var inputTokens: Int
    public var outputTokens: Int

    public init(calls: [Call] = [], text: String = "", stopReason: String? = nil, refusal: String? = nil, usd: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.calls = calls; self.text = text; self.stopReason = stopReason; self.refusal = refusal
        self.usd = usd; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct ToolResultInput: Sendable {
    public var callId: String
    public var content: String
    public var isError: Bool
    public init(callId: String, content: String, isError: Bool) { self.callId = callId; self.content = content; self.isError = isError }
}

public enum PlannerTier: String, Sendable { case quick, full }

/// The contract the loop depends on. Keeping the loop against this protocol
/// rather than a concrete class is what makes the model provider replaceable:
/// the Anthropic API, a coding app's CLI, or a scripted planner in tests all
/// slot in without touching the loop.
public protocol PlannerLike: AnyObject, Sendable {
    func seed(task: TaskState, droppedPaths: [String])
    func addToolResults(_ results: [ToolResultInput])
    func addNote(_ note: String)
    /// `tools` is the tool-use schema from `ToolRegistry.toModelSchema`.
    func propose(tools: [JSON]) async throws -> PlannerProposal
    /// Chooses a faster model for small jobs, or goes back to the full one. A
    /// planner without tiers ignores it.
    func setTier(_ tier: PlannerTier)
    /// True when the quick tier is a smaller model rather than the same model
    /// thinking less. The loop then hands a job the quick model started to the
    /// full one, since a small model should answer, not act.
    var quickSwapsModel: Bool { get }
    /// Releases anything the planner holds open, such as a CLI process.
    func dispose()
}

extension PlannerLike {
    public func setTier(_ tier: PlannerTier) {}
    public var quickSwapsModel: Bool { false }
    public func dispose() {}
}

public func addCost(_ cost: CostRecord, _ p: PlannerProposal) -> CostRecord {
    CostRecord(inputTokens: cost.inputTokens + p.inputTokens, outputTokens: cost.outputTokens + p.outputTokens, usd: cost.usd + p.usd, calls: cost.calls + 1)
}
