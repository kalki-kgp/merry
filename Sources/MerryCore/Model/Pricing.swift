import Foundation

/// Per-million-token rates, used to enforce the per-task spending limit.
/// These are Anthropic first-party API rates; a model we do not know about is
/// costed pessimistically so an unknown model can never slip past the limit.
public struct Rate: Equatable, Sendable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public init(inputPerMTok: Double, outputPerMTok: Double) { self.inputPerMTok = inputPerMTok; self.outputPerMTok = outputPerMTok }
}

private let RATES: [String: Rate] = [
    "claude-sonnet-5-5": Rate(inputPerMTok: 2, outputPerMTok: 10),
    "claude-opus-5-5": Rate(inputPerMTok: 4, outputPerMTok: 20),
    "claude-opus-5": Rate(inputPerMTok: 5, outputPerMTok: 25),
    "claude-opus-4-8": Rate(inputPerMTok: 5, outputPerMTok: 25),
    "claude-sonnet-5": Rate(inputPerMTok: 2, outputPerMTok: 10),
    "claude-haiku-4-5": Rate(inputPerMTok: 1, outputPerMTok: 5),
    "claude-fable-5-1": Rate(inputPerMTok: 10, outputPerMTok: 50)
]

private let UNKNOWN_MODEL_RATE = Rate(inputPerMTok: 15, outputPerMTok: 75)

/// Prompt-cache multipliers on the input rate: reads are a tenth, 5-minute writes a quarter more.
private let CACHE_READ = 0.1
private let CACHE_WRITE = 1.25

public func rateFor(_ model: String) -> Rate {
    RATES[model] ?? UNKNOWN_MODEL_RATE
}

public func costOf(_ model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) -> Double {
    let rate = rateFor(model)
    let input = Double(inputTokens) + Double(cacheReadTokens) * CACHE_READ + Double(cacheWriteTokens) * CACHE_WRITE
    return (input * rate.inputPerMTok + Double(outputTokens) * rate.outputPerMTok) / 1_000_000
}

/// The same cost, with the token counts given positionally as the planner passes them.
public func costOf(_ model: String, _ inputTokens: Int, _ outputTokens: Int, readTokens: Int = 0, writeTokens: Int = 0) -> Double {
    costOf(model, inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: readTokens, cacheWriteTokens: writeTokens)
}
