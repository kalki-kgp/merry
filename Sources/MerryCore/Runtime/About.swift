import Foundation

// Answering "what are you?" without a model call.
//
// This used to go to the planner: several seconds and a round trip to have
// Merry describe itself. The answer is a fact about this build (which tools
// are compiled in, which permissions this Mac has granted), so it is composed
// from those facts directly. That also makes it impossible for the answer to
// drift from what Merry can really do, which a model-written answer cannot
// promise.

private let GREETING = "(?:(?:hi|hey|hello|yo|sup|heya)\\b[\\s,!.]*)*"
private let QUESTION = "(?:(?:what|wat|who)\\s+(?:can|do|are|r)\\s+(?:u|you|merry)(?:\\s+do)?|help|capabilities)"
/// The way people actually finish the question: "what can you do bro?", "…for me lol".
private let TAIL = "(?:\\s+for\\s+me)?(?:[\\s,]+(?:bro|bruh|man|dude|buddy|mate|merry|lol|lmao|haha|pls|please|exactly|again))*"
/// Anchored at both ends on purpose. "help" alone is a question about Merry;
/// "help me rename these screenshots" is a job, and so is "what can you do
/// about the mess in my Downloads". Matching loosely would swallow both.
private let ABOUT = Rx.ecma("^\(GREETING)\(QUESTION)\(TAIL)\\s*[?!.]*$", "i")

public func isAboutMerry(_ request: String) -> Bool {
    ABOUT.test(request.ecmaTrimmed)
}

/// "Which model are you?", "what ai r u", "are you chatgpt". Short questions
/// only, and never one asking for advice ("what model should I use for …").
private let MODEL_QUESTION = Rx.ecma("\\b(?:(?:which|what)\\s+(?:ai\\s+)?(?:model|llm|ai|brain)s?\\b.*\\b(?:you|u|merry)\\b|(?:are|r)\\s+(?:you|u)\\s+(?:chat ?gpt|gpt|claude|gemini|an? ai|ai)\\b)", "i")

public func isAboutModel(_ request: String) -> Bool {
    let text = request.ecmaTrimmed
    return text.ecmaWordCount <= 8 && MODEL_QUESTION.test(text) && !Rx.ecma("\\b(recommend|should i|best|for my)\\b", "i").test(text)
}

/// "claude-opus-5" → "Claude Opus 5"; Claude Code aliases ("sonnet") → "Sonnet".
private func modelName(_ id: String) -> String {
    let words = Rx.ecma("^claude-").replaceFirst(id, "").jsSplit("-")
    let digits = Rx.ecma("^\\d+$")
    let name = words.filter { !digits.test($0) }.map(\.ecmaUpperFirst).joined(separator: " ")
    let version = words.filter { digits.test($0) }.joined(separator: ".")
    return "\(id.hasPrefix("claude-") ? "Claude " : "")\(name)\(version.isEmpty ? "" : " \(version)")"
}

/// What does the thinking: the Anthropic API, or a coding app on this Mac.
public enum ThinkingRoute: Equatable, Sendable {
    case api
    case app(CodingApp)
}

public struct SelfDescription: Equatable, Sendable {
    public var headline: String
    public var evidence: [Evidence]
    public init(headline: String, evidence: [Evidence]) { self.headline = headline; self.evidence = evidence }
}

/// Which models answer, stated from configuration rather than guessed by a model.
public func describeModels(_ route: ThinkingRoute?, _ model: ModelConfig, jev: Bool) -> SelfDescription {
    let headline: String
    switch route {
    case .app(.claudeCode):
        headline = "I think with Claude, through the Claude Code on this Mac, using \(modelName(model.claudeCode)) for answers and tasks."
    case .app(.codex):
        headline = "I think through the Codex on this Mac, with \(model.codex.isEmpty ? "the model it is set up to use" : model.codex)."
    case .app(.opencode):
        headline = "I think through the OpenCode on this Mac, with \(model.opencode.isEmpty ? "the model it is set up to use" : model.opencode)."
    case .api:
        headline = "I think with \(modelName(model.planner)), through the Anthropic API, thinking briefly for quick answers, and harder for anything I do on your Mac."
    case nil:
        headline = "No thinking model is connected yet. Add an Anthropic key under /keys, or let me use Claude Code under /tune."
    }
    let evidence: [Evidence] = [
        .text(
            "Reading your request",
            jev
                ? "Jev, a small fast model from TypeSafe AI, sorts each request in about half a second: what kind of job it is, and which tools it needs."
                : "Local rules sort each request; Jev is switched off."
        ),
        .text("No model at all", "Timers, notes, reminders, sums and questions like this one run on local code, instantly.")
    ]
    return SelfDescription(headline: headline, evidence: evidence)
}

public func describeSelf(_ os: OsAdapter, canPlan: Bool, workflowsEnabled: Bool, workspace: Bool = false) -> SelfDescription {
    let canSeeApps = os.supports(.windowInspect)
    let canCapture = os.supports(.windowCapture)

    var evidence: [Evidence] = [
        .text(
            "Files and folders",
            "Look through folders, find things by name, kind or date, sort them into groups, and rename in bulk. " +
                "You see a preview before anything moves, and you can undo moves afterwards."
        ),
        .text(
            "Your day",
            "Add reminders and calendar events, tell you what is on or when you are free, write notes, draft " +
                "emails for you to send, run your Shortcuts, and switch dark mode or the volume. New events, " +
                "reminders and notes can be undone."
        ),
        .text(
            "Memory",
            "Tell me \"remember that …\" and I will, and I pick up choices you repeat, like which calendar standups " +
                "go on. I only bring something up when it helps with what you asked. Ask what I remember, or say " +
                "\"forget …\", any time."
        ),
        .text(
            "Your Mac",
            canSeeApps
                ? "Read what is in a window and press its buttons or fill its fields through accessibility, rather " +
                    "than clicking at coordinates and hoping. I never move your mouse or type for you."
                : "Blocked right now. macOS has not granted me Accessibility, so I cannot see any window or press " +
                    "anything. Open /tune and let me in, and this turns on."
        ),
        .text(
            "The web",
            "Open pages, fill forms and download things in my own separate browser, so nothing touches the one " +
                "you are signed into."
        ),
        .text(
            "How I work",
            "I look before I act, do the work through real operations rather than by driving your mouse, check " +
                "that what I claimed actually happened, and stop to ask when a choice is really yours. " +
                (canCapture ? "" : "I cannot take pictures of windows: Screen Recording is not granted. ")
        ),
        .text(
            "Try me with",
            workflowsEnabled
                ? "\"remind me to call mom tomorrow at 7\", \"when am I free tomorrow\", \"tidy up my Downloads\", " +
                    "\"find the invoice I saved yesterday\". Those run on local code and Jev in about a second, with no " +
                    "planning model at all."
                : "\"remind me to call mom tomorrow at 7\", \"when am I free tomorrow\", \"tidy up my Downloads\", " +
                    "\"find the invoice I saved yesterday\"."
        )
    ]

    if workspace {
        evidence.insert(.text("Your workspace", "Keep notes, tasks, reminders, project links, daily trackers and saved work sessions with me. I can turn into a timer, snooze reminders, and catch up when your Mac wakes or Merry reopens. Say “note: …”, “remind me …”, “start a 25 minute timer”, or open /workspace. Notes and timers work without a model."), at: 0)
    }

    if !canPlan {
        evidence.append(.text(
            "Not set up yet",
            "I have no way to think about anything open-ended. Give me a key under /keys, or let me use the " +
                "Claude Code on this Mac under /tune."
        ))
    }

    return SelfDescription(
        headline: canSeeApps
            ? "I'm Merry. I work on your Mac: your files, your apps, and the web, and I show you what I actually did."
            : "I'm Merry. I work on your files and the web today, and on your apps as soon as you let me see them.",
        evidence: evidence
    )
}
