import Foundation

// Jev, TypeSafe AI's System One model, used for narrow structured judgments.
//
// Jev is not a text model. You hand it state plus a set of declared typed
// questions, and it answers all of them in one round trip with probabilities.
// That shape dictates how it is used here:
//
//   - It picks between alternatives we declared. It cannot invent a folder
//     name, so naming groups stays with the planning model and Jev only
//     assigns files to groups that already exist.
//   - It never authorizes anything and never decides a task succeeded. Those
//     are deterministic checks elsewhere, and a probability is not a
//     permission.
//   - Where local code can decide correctly, local code decides. Jev is
//     consulted only for the genuinely ambiguous middle.
//
// One safety property is enforced rather than hoped for: `assessProgress` lets
// Jev make the loop *more* cautious but never less. See `atLeastAsCautious`.

// MARK: - Questions and answers

/// One declared question. Built with `choice`, `noul` or `score`, which
/// serialise the way the TypeSafe SDK's builders of the same names do.
public enum JevQuestion: Sendable, Equatable {
    case choiceOf(instructions: JSON, criteria: JSONObject)
    case noulOf(instructions: JSON, criteria: JSON?)
    case scoreOf(instructions: JSON, criteria: [JSON])

    /// A question that selects between named alternatives: labels mapped to descriptions.
    public static func choice(_ question: String, _ criteria: KeyValuePairs<String, String>) -> JevQuestion {
        choice(question, criteria.map { ($0.key, $0.value) })
    }

    public static func choice(_ question: String, _ criteria: [(String, String)]) -> JevQuestion {
        .choiceOf(instructions: .string(question), criteria: jsObject(criteria.map { ($0.0, JSON.string($0.1)) }))
    }

    /// A yes/no question, with optional descriptions of the "true" and "false" outcomes.
    public static func noul(_ question: String? = nil, _ criteria: KeyValuePairs<String, String>? = nil) -> JevQuestion {
        .noulOf(instructions: JSON(question), criteria: criteria.map { pairs in .object(jsObject(pairs.map { ($0.key, JSON.string($0.value)) })) })
    }

    public static func noul(_ question: String?, _ criteria: [(String, String)]) -> JevQuestion {
        .noulOf(instructions: JSON(question), criteria: .object(jsObject(criteria.map { ($0.0, JSON.string($0.1)) })))
    }

    /// A score question: at least two descriptions indexed by score from zero; `nil` leaves a score undescribed.
    public static func score(_ question: String, _ criteria: [String?]) -> JevQuestion {
        .scoreOf(instructions: .string(question), criteria: criteria.map { JSON($0) })
    }

    /// What goes on the wire for this question.
    public var json: JSON {
        switch self {
        case .choiceOf(let instructions, let criteria):
            return ["type": "choice", "instructions": instructions, "criteria": .object(criteria)]
        case .noulOf(let instructions, let criteria):
            return JSON.obj(["type": "noul", "instructions": instructions, "criteria": criteria])
        case .scoreOf(let instructions, let criteria):
            return ["type": "score", "instructions": instructions, "criteria": .array(criteria)]
        }
    }

    /// An object with its keys in the order a JavaScript object keeps them:
    /// whole-number keys first, ascending, then the rest as they were added.
    static func jsObject(_ pairs: [(String, JSON)]) -> JSONObject {
        let all = JSONObject(pairs)
        func index(_ key: String) -> UInt32? {
            guard let n = UInt32(key), n < UInt32.max, String(n) == key else { return nil }
            return n
        }
        let numeric = all.keys.compactMap { key in index(key).map { (key, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        if numeric.isEmpty { return all }
        return JSONObject((numeric + all.keys.filter { index($0) == nil }).map { ($0, all[$0]!) })
    }
}

/// One answer. A reply that does not have the shape its type promises is kept
/// as `unknown`, and the accessors read whatever fields it does have: nothing
/// that came over a network is trusted to be well formed.
public enum JevAnswer: Sendable, Equatable {
    case choice(choice: String, confidence: Double, probabilities: [String: Double])
    case noul(noul: Double)
    case score(score: Double, confidence: Double)
    case unknown(JSON)

    public init(_ json: JSON) {
        let type = json["type"]?.stringValue
        if type == "choice", let choice = json["choice"]?.stringValue, let confidence = json["confidence"]?.doubleValue {
            var probabilities: [String: Double] = [:]
            for (label, p) in json["probabilities"]?.objectValue?.pairs ?? [] { if let p = p.doubleValue { probabilities[label] = p } }
            self = .choice(choice: choice, confidence: confidence, probabilities: probabilities)
        } else if type == "noul", let noul = json["noul"]?.doubleValue {
            self = .noul(noul: noul)
        } else if type == "score", let score = json["score"]?.doubleValue, let confidence = json["confidence"]?.doubleValue {
            self = .score(score: score, confidence: confidence)
        } else {
            self = .unknown(json)
        }
    }

    /// "choice", "noul" or "score", as the reply declared it.
    public var type: String? {
        switch self {
        case .choice: return "choice"
        case .noul: return "noul"
        case .score: return "score"
        case .unknown(let json): return json["type"]?.stringValue
        }
    }

    /// The selected label.
    public var choice: String? {
        switch self {
        case .choice(let choice, _, _): return choice
        case .unknown(let json): return json["choice"]?.stringValue
        default: return nil
        }
    }

    public var confidence: Double? {
        switch self {
        case .choice(_, let confidence, _), .score(_, let confidence): return confidence
        case .unknown(let json): return json["confidence"]?.doubleValue
        default: return nil
        }
    }

    /// Probability of a yes, from zero to one.
    public var noul: Double? {
        switch self {
        case .noul(let noul): return noul
        case .unknown(let json): return json["noul"]?.doubleValue
        default: return nil
        }
    }

    public var score: Double? {
        switch self {
        case .score(let score, _): return score
        case .unknown(let json): return json["score"]?.doubleValue
        default: return nil
        }
    }
}

/// Sends one request. The default goes to the network; tests supply their own.
public typealias JevTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

// MARK: - Records

public struct JevCallRecord: Sendable, Equatable {
    public var decision: String
    public var usedModel: Bool
    public var latencyMs: Double
    public var usd: Double
    public var inputTokens: Int
    public var outcome: String
    public var confidence: Double

    public init(decision: String, usedModel: Bool, latencyMs: Double, usd: Double, inputTokens: Int, outcome: String, confidence: Double) {
        self.decision = decision; self.usedModel = usedModel; self.latencyMs = latencyMs; self.usd = usd
        self.inputTokens = inputTokens; self.outcome = outcome; self.confidence = confidence
    }

    public var json: JSON {
        ["decision": .string(decision), "usedModel": .bool(usedModel), "latencyMs": .number(latencyMs), "usd": .number(usd),
         "inputTokens": .number(Double(inputTokens)), "outcome": .string(outcome), "confidence": .number(confidence)]
    }
}

public struct JevMetrics: Sendable, Equatable {
    public var calls: [JevCallRecord] = []
    public var totalUsd = 0.0
    public var totalLatencyMs = 0.0
    /// Times a Jev answer changed what local rules would have done on their own.
    public var overrides = 0

    public init() {}

    public var json: JSON {
        ["calls": .array(calls.map(\.json)), "totalUsd": .number(totalUsd), "totalLatencyMs": .number(totalLatencyMs), "overrides": .number(Double(overrides))]
    }
}

public enum JevRoute: String, Sendable, CaseIterable { case files, desktop, browser, mixed, unclear }

public struct RouteDecision: Sendable, Equatable {
    public var route: JevRoute
    public var confidence: Double
    public var reason: String
    public var needsClarification: Bool

    public init(route: JevRoute, confidence: Double, reason: String, needsClarification: Bool) {
        self.route = route; self.confidence = confidence; self.reason = reason; self.needsClarification = needsClarification
    }
}

public enum ProgressAction: String, Sendable, CaseIterable {
    case `continue`, replan, reobserve, ask, abort
}

public struct ProgressVerdict: Sendable, Equatable {
    public var action: ProgressAction
    public var reason: String
    /// True when local rules alone produced this verdict.
    public var deterministic: Bool

    public init(action: ProgressAction, reason: String, deterministic: Bool) {
        self.action = action; self.reason = reason; self.deterministic = deterministic
    }
}

/// Whether a reading came from local rules or from Jev.
public enum JevSource: String, Sendable { case local, jev }

public enum Family: String, Sendable, CaseIterable {
    case files, desktop, browser, calendar, reminders, notes, mail, shortcuts, system
}

public let FAMILY_KEYS: [Family] = Family.allCases

public struct PlanSetup: Sendable, Equatable {
    public struct Context: Sendable, Equatable {
        public var selection: Bool
        public var tab: Bool
        public var finder: Bool
        public var clipboard: Bool
        public init(selection: Bool, tab: Bool, finder: Bool, clipboard: Bool) {
            self.selection = selection; self.tab = tab; self.finder = finder; self.clipboard = clipboard
        }
    }

    /// Where a person would start on the web: their feed, a search, a named page.
    public enum Start: String, Sendable { case feed, search, direct, none }

    public var families: [Family]
    public var context: Context
    /// The job is small enough for the quick model.
    public var quick: Bool
    /// Personal browsing happens in the user's own browser, where they are signed in.
    public var ownBrowser: Bool
    public var start: Start
    public var source: JevSource

    public init(families: [Family], context: Context, quick: Bool, ownBrowser: Bool, start: Start, source: JevSource) {
        self.families = families; self.context = context; self.quick = quick; self.ownBrowser = ownBrowser; self.start = start; self.source = source
    }
}

/// A file to be sorted into a group.
public struct JevFile: Sendable, Equatable {
    public var name: String
    public var ext: String
    public var modifiedAt: Double
    public init(name: String, ext: String, modifiedAt: Double) { self.name = name; self.ext = ext; self.modifiedAt = modifiedAt }
}

public struct JevGroup: Sendable, Equatable {
    public var name: String
    public var description: String
    public init(name: String, description: String) { self.name = name; self.description = description }
}

public struct JevAssignment: Sendable, Equatable {
    /// File name to group name.
    public var assignments: [String: String]
    public var unsorted: [String]
}

// MARK: - Constants

/// Jev pricing: $0.042 per million input tokens, output unmetered.
private let JEV_INPUT_PER_MTOK = 0.042

private func jevCost(_ inputTokens: Double) -> Double {
    (inputTokens * JEV_INPUT_PER_MTOK) / 1_000_000
}

/// How long Jev is left alone after a call fails. Every Jev decision has a
/// local fallback, so while the service is struggling the right move is to
/// stop asking it: a failed call costs the full timeout, and a task makes
/// several of them in a row before the planner even starts.
private let JEV_COOLDOWN_MS = 60_000.0

/// Ordered least to most cautious. Used to stop Jev relaxing a local verdict.
private let CAUTION_ORDER: [ProgressAction] = [.continue, .reobserve, .replan, .ask, .abort]

func atLeastAsCautious(_ local: ProgressAction, _ proposed: ProgressAction?) -> ProgressAction {
    guard let proposed, let p = CAUTION_ORDER.firstIndex(of: proposed), let l = CAUTION_ORDER.firstIndex(of: local) else { return local }
    return p > l ? proposed : local
}

private struct JevFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Client

public final class Jev: @unchecked Sendable {
    /// What the SDK's client held: where to send, and as whom.
    private struct Connection {
        var apiKey: String
        var baseURL: String
        var model: String
        var send: JevTransport
    }

    /// What a successful reply carried.
    private struct Reply {
        /// Nil when the reply had no `answers` object.
        var answers: [String: JevAnswer]?
        var inputTokens: Double
    }

    /// When each transport may be tried again. Keyed by transport so tests with their own do not trip each other.
    private static let downLock = NSLock()
    private nonisolated(unsafe) static var downUntil: [String: Double] = [:]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 1.5
        return URLSession(configuration: configuration)
    }()

    private let lock = NSLock()
    private var record = JevMetrics()
    private let connected: Connection?
    private let transportKey: String
    private let clock: @Sendable () -> Double
    /// Jev answers in about half a second. A slow call means something is
    /// wrong, and the loop is better off on local rules than waiting.
    var timeoutMs = 1500.0

    public var metrics: JevMetrics {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    /// The connection, or nil while Jev is cooling down after a failure.
    private var client: Connection? {
        Jev.downLock.lock(); defer { Jev.downLock.unlock() }
        return (Jev.downUntil[transportKey] ?? 0) > clock() ? nil : connected
    }

    /// - Parameters:
    ///   - apiKey: The TypeSafe key; without one, `TYPESAFE_API_KEY` is read, and with neither Jev is unavailable.
    ///   - transport: Transport override. Used to exercise Jev's behaviour without a network.
    ///   - transportKey: Instances given the same key share one cooldown, as instances on the network do.
    ///     A transport without a key cools down on its own.
    ///   - environment: Where `TYPESAFE_API_KEY` and `TYPESAFE_BASE_URL` are read from; the process environment by default.
    ///   - now: The clock, in milliseconds.
    public init(
        apiKey: String?,
        enabled: Bool,
        model: String = "jev-latest",
        transport: JevTransport? = nil,
        transportKey: String? = nil,
        environment: [String: String]? = nil,
        now: (@Sendable () -> Double)? = nil
    ) {
        self.transportKey = transportKey ?? (transport == nil ? "network" : "transport-\(newId())")
        self.clock = now ?? { nowMs() }
        guard enabled else { connected = nil; return }
        let env = environment ?? ProcessInfo.processInfo.environment
        func read(_ name: String) -> String? {
            guard let value = env[name]?.ecmaTrimmed, !value.isEmpty else { return nil }
            return value
        }
        // No key is not an error: falling back to local rules is correct, and
        // must not take the task down.
        guard let key = (apiKey.flatMap { $0.isEmpty ? nil : $0 }) ?? read("TYPESAFE_API_KEY") else { connected = nil; return }
        let base = Rx("/+$").replaceFirst(read("TYPESAFE_BASE_URL") ?? "https://api.typesafe.ai", "")
        connected = Connection(apiKey: key, baseURL: base, model: model, send: transport ?? { request in
            let (data, response) = try await Jev.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw JevFailure("Connection error.") }
            return (data, http)
        })
    }

    public var available: Bool { client != nil }

    // MARK: Wire

    /// `POST /v1/systemone`: one attempt, no retries, the whole round trip
    /// inside the timeout. Any failure to get a 2xx reply starts the cooldown.
    private func systemOne(_ client: Connection, state: JSON, questions: JSONObject) async throws -> JSON? {
        do {
            if questions.isEmpty { throw JevFailure("At least one question is required.") }
            for (name, question) in questions.pairs where question["type"]?.stringValue == "score" {
                let count = question["criteria"]?.arrayValue?.count ?? 0
                if count < 2 { throw JevFailure("Score question \"\(name)\" has \(count) criteria; at least two scores are required.") }
            }
            guard let url = URL(string: "\(client.baseURL)/v1/systemone") else { throw JevFailure("Connection error: invalid URL") }
            let body: JSON = ["state": state, "questions": .object(questions), "model": .string(client.model)]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutMs / 1000
            request.setValue("Bearer \(client.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("merry/\(Merry.version)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.stringify().utf8)

            let (data, response) = try await Jev.withTimeout(timeoutMs) { [request] in try await client.send(request) }
            guard (200..<300).contains(response.statusCode) else { throw JevFailure("\(response.statusCode) status code") }
            let text = String(decoding: data, as: UTF8.self)
            if text.isEmpty { return nil }
            return (try? JSON.parse(text)) ?? .string(text)
        } catch {
            coolDown()
            throw error
        }
    }

    private func coolDown() {
        Jev.downLock.lock(); defer { Jev.downLock.unlock() }
        Jev.downUntil[transportKey] = clock() + JEV_COOLDOWN_MS
    }

    /// The first of the reply and the timeout. The transport is cancelled when
    /// time runs out, and is not waited for if it ignores that.
    private static func withTimeout(_ ms: Double, _ send: @escaping @Sendable () async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var claimed = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if claimed { return false }
                claimed = true
                return true
            }
        }
        let gate = Gate()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do {
                    let reply = try await send()
                    if gate.claim() { continuation.resume(returning: reply) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(ms, 0) * 1_000_000))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: JevFailure("Request timed out after \(JSON.number(ms).stringify())ms."))
                }
            }
        }
    }

    /// Never trust the shape of a reply that came over a network: anything
    /// without usage is a failed call, and answers that are not an object are
    /// no answers.
    private func unpack(_ body: JSON?) throws -> Reply {
        guard let body, let usage = body["usage"], usage.objectValue != nil else { throw JevFailure("Unexpected response shape.") }
        let tokens = usage["input_tokens"]?.doubleValue ?? 0
        var answers: [String: JevAnswer]?
        if let object = body["answers"]?.objectValue {
            answers = [:]
            for (name, answer) in object.pairs { answers![name] = JevAnswer(answer) }
        }
        return Reply(answers: answers, inputTokens: tokens.isFinite ? tokens : 0)
    }

    private static func object(_ questions: [(String, JevQuestion)]) -> JSONObject {
        JevQuestion.jsObject(questions.map { ($0.0, $0.1.json) })
    }

    // MARK: Asking

    /// Pose arbitrary declared questions about some state.
    ///
    /// This is the general entry point workflows use. It returns `nil` rather
    /// than throwing when Jev is unavailable or errors, because every caller must
    /// have a path that works without it.
    public func ask(_ label: String, state: JSON, questions: [(String, JevQuestion)]) async -> [String: JevAnswer]? {
        let asked = Jev.object(questions)
        guard let client, !asked.isEmpty else { return nil }
        let started = clock()
        do {
            let reply = try unpack(try await systemOne(client, state: state, questions: asked))
            note(label, true, clock() - started, jevCost(reply.inputTokens), reply.inputTokens, "\(asked.count) answers", 1)
            return reply.answers
        } catch {
            note(label, true, clock() - started, 0, 0, "failed", 0)
            return nil
        }
    }

    /// Whether the browser Merry opened should be closed now the task is done.
    ///
    /// Both answers are defined here, in code; Jev only picks between them, and
    /// a missing or unsure answer leaves the window open: the outcome that
    /// cannot lose anything.
    public func shouldCloseBrowser(_ request: String) async -> Bool {
        let answers = await ask(
            "close_browser",
            state: ["userRequest": .string(request)],
            questions: [
                ("close", .noul(
                    "The assistant opened a browser to do this and has now finished. Was the browser only a means to " +
                        "an end, so it should be closed and tidied away?",
                    [
                        "true": "The user wanted an answer or an action, not a browser window to look at.",
                        "false": "The user wanted something left open on screen for them to use or read."
                    ]
                ))
            ]
        )
        guard let answers else { return true } // No Jev: the plain default is to tidy up.
        return (answers["close"]?.noul ?? 0) > 0.6
    }

    // MARK: Routing

    /// Which family of tools this request needs, used to scope the tool surface
    /// offered to the planner. Local keyword rules answer the easy cases; Jev is
    /// asked only when they are unsure.
    public func routeRequest(_ request: String, hasDroppedPaths: Bool) async -> RouteDecision {
        let local = routeLocally(request, hasDroppedPaths: hasDroppedPaths)
        guard let client, local.confidence < 0.85 else {
            note("route", false, 0, 0, 0, local.route.rawValue, local.confidence)
            return local
        }

        let started = clock()
        do {
            let reply = try unpack(try await systemOne(
                client,
                state: ["request": .string(request), "filesDroppedOntoAssistant": .bool(hasDroppedPaths)],
                questions: Jev.object([
                    ("route", .choice("Which kind of work does this request need?", [
                        "files": "Organising, finding, renaming or reading files already on this computer.",
                        "desktop": "Driving a native Mac application's windows, menus and controls.",
                        "browser": "Visiting a website, filling in a web form, or downloading something.",
                        "mixed": "Genuinely needs more than one of the above to complete.",
                        "unclear": "There is not enough information to tell what is being asked."
                    ])),
                    ("needsClarification", .noul("Is this request too vague to act on without asking the user what they mean?", [
                        "true": "A reasonable assistant would have to ask a question before starting.",
                        "false": "There is a clear, sensible first step."
                    ]))
                ])
            ))

            let latency = clock() - started
            guard let answer = reply.answers?["route"], let route = answer.choice.flatMap(JevRoute.init(rawValue:)),
                  let confidence = answer.confidence, let clarify = reply.answers?["needsClarification"] else {
                throw JevFailure("Unexpected response shape.")
            }
            let decision = RouteDecision(
                route: route,
                confidence: confidence,
                reason: "Jev chose \(route.rawValue) (\((confidence * 100).toFixed(0))% confident)",
                // Above 0.5 is a yes for a noul probability.
                needsClarification: (clarify.noul ?? 0) > 0.5
            )
            if decision.route != local.route { override() }
            note("route", true, latency, jevCost(reply.inputTokens), reply.inputTokens, decision.route.rawValue, decision.confidence)
            return decision
        } catch {
            // Jev being unavailable must never fail a task.
            note("route", true, clock() - started, 0, 0, "\(local.route.rawValue) (fallback)", local.confidence)
            return local
        }
    }

    /// Keyword routing. Confident enough often enough to skip the network call.
    func routeLocally(_ request: String, hasDroppedPaths: Bool) -> RouteDecision {
        let r = request.lowercased()
        // Naming a site, or a domain, is as plain a web signal as saying "website".
        // This list will never be complete; that is exactly why an unsure answer
        // goes to Jev rather than to a bigger list.
        let site =
            Route.site.test(r) ||
            // Any domain-shaped token, minus the ones that are really filenames.
            // Listing top-level domains is a losing game: bunkr.cr is as real as
            // youtube.com, so the rule is "looks like a host, is not a file".
            (Route.host.test(r) && !Route.filename.test(r))
        let browser = site || Route.browser.test(r)
        let files = hasLocalSearchIntent(r) || Route.files.test(r)
        let desktop = Route.desktop.test(r)
        let signals = [browser, files, desktop].filter { $0 }.count

        if signals == 0 {
            return RouteDecision(
                route: hasDroppedPaths ? .files : .unclear,
                confidence: hasDroppedPaths ? 0.9 : 0.3,
                reason: hasDroppedPaths ? "files were dropped on the pet" : "no strong signal in the wording",
                // "Tidy this up" is only vague in the abstract. Dropping files on the
                // pet says which "this" is meant, so there is nothing to ask about.
                needsClarification: !hasDroppedPaths && request.ecmaWordCount < 4
            )
        }
        if signals > 1 { return RouteDecision(route: .mixed, confidence: 0.6, reason: "several signals present", needsClarification: false) }
        if browser { return RouteDecision(route: .browser, confidence: 0.85, reason: "mentions the web", needsClarification: false) }
        if desktop { return RouteDecision(route: .desktop, confidence: 0.8, reason: "mentions an app or window", needsClarification: false) }
        return RouteDecision(
            route: .files,
            confidence: hasDroppedPaths ? 0.95 : 0.85,
            reason: hasDroppedPaths ? "files were dropped on the pet" : "mentions files or folders",
            needsClarification: false
        )
    }

    private enum Route {
        static let site = Rx.ecma("\\b(youtube|netflix|gmail|google|twitter|x\\.com|reddit|amazon|instagram|facebook|spotify|wikipedia|github|linkedin|maps|chatgpt)\\b")
        static let host = Rx.ecma("\\b[a-z0-9][a-z0-9-]{1,}\\.[a-z]{2,6}\\b")
        static let filename = Rx.ecma("\\.(pdf|png|jpe?g|gif|mp4|mov|mp3|docx?|xlsx?|pptx?|txt|csv|zip|dmg|heic|webp|md|json|ts|js|py)\\b")
        static let browser = Rx.ecma("\\b(website|url|http|browser|online|web form|log ?in to|download from|fill in the form|watch|stream|search the web|google it)\\b")
        static let files = Rx.ecma("\\b(file|files|folder|desktop|downloads|downloaded|organi[sz]e|rename|sort|move|pdf|screenshot|document|invoice|spreadsheet)\\b")
        static let desktop = Rx.ecma("\\b(app|application|window|finder|preview|notes|mail|keynote|pages|numbers|this window)\\b")
    }

    // MARK: Getting the planner ready

    /// Everything the planning model's first step would otherwise spend a round
    /// trip on, decided in one Jev call:
    ///
    ///   - which tool families the request needs, so the planner is shown a
    ///     short menu instead of every tool (a shorter prompt is a faster step);
    ///   - which parts of "this" to fetch up front (selection, browser tab,
    ///     Finder selection, clipboard), so the planner starts with them rather
    ///     than asking for them;
    ///   - whether the job is small enough for the quick model.
    ///
    /// None of it grants anything. Narrowing the menu only hides tools, and the
    /// runner widens it again, and moves to the full model, the moment the
    /// work stops going well. Without Jev the same answers come from keywords.
    public func planSetup(_ request: String, route: String, hasDroppedPaths: Bool) async -> PlanSetup {
        let client = self.client
        let started = clock()
        func family(_ question: String) -> JevQuestion { .noul(question, ["true": "Yes, this is needed.", "false": "No."]) }
        let local = localPlanSetup(request, route: route, hasDroppedPaths: hasDroppedPaths)
        guard let client else {
            note("plan_setup", false, 0, 0, 0, describeSetup(local), 1)
            return local
        }
        let reply = try? unpack(try await systemOne(
            client,
            state: ["request": .string(request), "filesDroppedOntoAssistant": .bool(hasDroppedPaths), "today": .string(JSDate(started).toDateString())],
            questions: Jev.object([
                ("files", family("Does this involve files or folders on the computer?")),
                ("desktop", family("Does this need clicking and typing inside an app's window, for an app with no other way in?")),
                ("browser", family("Does this need a web browser to visit a site, search the web, fill a form or download something?")),
                ("calendar", family("Does this involve the calendar: events, meetings, schedule, free time?")),
                ("reminders", family("Does this involve reminders or a to-do list?")),
                ("notes", family("Does this involve the Notes app: writing, finding or reading a note?")),
                ("mail", family("Does this involve writing an email?")),
                ("shortcuts", family("Does this ask to run one of the user's Shortcuts?")),
                ("system", family("Does this involve a system setting (dark mode, volume) or opening or quitting an app?")),
                ("selection", family("Does \"this\", \"it\" or \"that\" refer to text the user has selected?")),
                ("tab", family("Does the request refer to the web page or site the user has open?")),
                ("finder", family("Does it refer to files the user has selected in Finder?")),
                ("clipboard", family("Does the user mention something they copied, or the clipboard?")),
                ("ownBrowser", family("Is this personal browsing best done in the user's own signed-in browser (watching, listening, their feed, their accounts, their inbox) rather than an unattended job like downloading or filling in a form?")),
                ("start", .choice("Where would a person start this on the web?", [
                    "feed": "Their personalised home feed or recommendations, because they want something good rather than one specific thing.",
                    "search": "A search, because they named a specific thing, topic or question.",
                    "direct": "A specific page or site they named.",
                    "none": "This is not a web task."
                ])),
                ("effort", .choice("How much work is this?", [
                    "quick": "One small job in one place: add an event, answer from one page, change a setting.",
                    "involved": "Several steps across apps or sites, working something out, or writing something substantial."
                ]))
            ])
        ))
        guard let reply, let answers = reply.answers else {
            note("plan_setup", true, clock() - started, 0, 0, "\(describeSetup(local)) (fallback)", 0)
            return local
        }
        func yes(_ name: String, _ fallback: Bool) -> Bool {
            if let p = answers[name]?.noul { return p > 0.5 }
            return fallback
        }
        let families = FAMILY_KEYS.filter { yes($0.rawValue, local.families.contains($0)) }
        let setup = PlanSetup(
            // A family local keywords are sure of stays even if Jev disagrees:
            // hiding a tool the request plainly names can only cost a replan.
            families: (families + local.families).unique,
            context: PlanSetup.Context(
                selection: yes("selection", local.context.selection),
                tab: yes("tab", local.context.tab),
                finder: yes("finder", local.context.finder),
                // The clipboard can hold anything, passwords included: only read it
                // when the words actually point at it.
                clipboard: local.context.clipboard && yes("clipboard", true)
            ),
            quick: answers["effort"]?.choice == "quick",
            ownBrowser: yes("ownBrowser", local.ownBrowser),
            start: answers["start"]?.choice.flatMap(PlanSetup.Start.init(rawValue:)) ?? local.start,
            source: .jev
        )
        note("plan_setup", true, clock() - started, jevCost(reply.inputTokens), reply.inputTokens, describeSetup(setup), 1)
        return setup
    }

    // MARK: Progress

    /// Local rules only. Same history in, same verdict out, every time: a
    /// failure budget that a probability could talk its way past would not be a
    /// budget. `assessProgress` layers Jev on top of this without replacing it.
    public func assessProgressLocally(_ task: TaskState) -> ProgressVerdict {
        let actions = task.actions
        if actions.isEmpty { return ProgressVerdict(action: .continue, reason: "no actions yet", deterministic: true) }

        var consecutiveFailures = 0
        for action in actions.reversed() {
            if action.outcome == .failure { consecutiveFailures += 1 } else { break }
        }
        if consecutiveFailures >= task.limits.maxConsecutiveFailures {
            return ProgressVerdict(action: .ask, reason: "\(consecutiveFailures) actions failed in a row", deterministic: true)
        }

        let recent = actions.suffix(4)
        if recent.count == 4 && recent.allSatisfy({ $0.outcome == .failure }) {
            return ProgressVerdict(action: .replan, reason: "the last four actions all failed", deterministic: true)
        }

        let lastTwo = Array(actions.suffix(2))
        if lastTwo.count == 2 && lastTwo.allSatisfy({ $0.outcome == .failure }) &&
            lastTwo[0].tool == lastTwo[1].tool && lastTwo[0].error == lastTwo[1].error {
            let stale = Rx.ecma("re-?inspect|no longer|changed|stale", "i").test(lastTwo[1].error ?? "")
            return ProgressVerdict(
                action: stale ? .reobserve : .replan,
                reason: "\(lastTwo[1].tool) failed twice with the same error",
                deterministic: true
            )
        }

        if actions.count >= 6 {
            let fingerprints = actions.suffix(6).map { "\($0.tool):\($0.input.stringify())" }
            if Set(fingerprints).count == 1 {
                return ProgressVerdict(action: .replan, reason: "the same call has repeated six times", deterministic: true)
            }
        }

        return ProgressVerdict(action: .continue, reason: "progressing", deterministic: true)
    }

    /// The verdict the loop uses. Local rules decide first. Jev is consulted only
    /// for the ambiguous middle (no rule fired, but the recent history is untidy),
    /// and its answer is clamped so it can only increase caution.
    public func assessProgress(_ task: TaskState) async -> ProgressVerdict {
        let local = assessProgressLocally(task)
        guard let client, local.action == .continue, looksUntidy(task) else { return local }

        let started = clock()
        do {
            let reply = try unpack(try await systemOne(
                client,
                state: [
                    "goal": .string(task.request),
                    "recentSteps": .array(task.actions.suffix(8).map { a in
                        ["tool": .string(a.tool), "outcome": .string(a.outcome.rawValue), "error": JSON(a.error), "verified": JSON(a.verification?.verified)]
                    })
                ],
                questions: Jev.object([
                    ("nextMove", .choice("What should the assistant do next?", [
                        "continue": "The work is progressing; carry on with the current plan.",
                        "reobserve": "What it is acting on has probably changed; look again before acting.",
                        "replan": "The current approach is not working; a different approach is needed.",
                        "ask": "It is stuck in a way the user needs to resolve."
                    ])),
                    ("stuck", .noul("Is this task repeating itself without getting closer to the goal?"))
                ])
            ))

            let latency = clock() - started
            guard let nextMove = reply.answers?["nextMove"] else { return local }
            let proposed = nextMove.choice ?? "undefined"
            let confidence = nextMove.confidence ?? .nan
            // Jev may tighten the verdict, never loosen it.
            let action = atLeastAsCautious(local.action, ProgressAction(rawValue: proposed))
            if action != local.action { override() }

            note("progress", true, latency, jevCost(reply.inputTokens), reply.inputTokens, action.rawValue, confidence)

            guard action != local.action, let stuck = reply.answers?["stuck"] else { return local }
            return ProgressVerdict(
                action: action,
                reason: "Jev: \(proposed) (\((confidence * 100).toFixed(0))% confident, stuck \(((stuck.noul ?? .nan) * 100).toFixed(0))%)",
                deterministic: false
            )
        } catch {
            return local
        }
    }

    /// Cheap precondition: only spend a Jev call when the history looks messy.
    private func looksUntidy(_ task: TaskState) -> Bool {
        let recent = task.actions.suffix(6)
        if recent.count < 4 { return false }
        return recent.contains { $0.outcome == .failure || $0.outcome == .uncertain }
    }

    // MARK: File grouping

    /// Assigns files to groups that already exist.
    ///
    /// Jev chooses between declared labels, so it cannot name the groups; the
    /// planning model proposes those, and Jev does the bulk assignment in one
    /// round trip instead of one model call per file. The result is a proposal
    /// that still goes to the user as a preview before anything moves.
    public func assignFilesToGroups(_ files: [JevFile], _ groups: [JevGroup]) async -> JevAssignment? {
        guard client != nil, !files.isEmpty, !groups.isEmpty else { return nil }

        let criteria = [("unsorted", "Does not belong in any of the other groups.")] + groups.map { ($0.name, $0.description) }

        var assignments: [String: String] = [:]
        var named = Set<String>()
        var unsorted: [String] = []
        let started = clock()
        var inputTokens = 0.0

        // Jev answers many questions in one call, so files are batched rather than
        // asked one at a time.
        let BATCH = 40
        do {
            for start in stride(from: 0, to: files.count, by: BATCH) {
                let batch = Array(files[start..<min(start + BATCH, files.count)])
                guard let client else { throw JevFailure("Jev is cooling down.") }
                let reply = try unpack(try await systemOne(
                    client,
                    state: [
                        "task": "Assign each listed file to the group it belongs in.",
                        "files": .array(try batch.enumerated().map { idx, f in
                            guard f.modifiedAt.isFinite, abs(f.modifiedAt) <= 8.64e15 else { throw JevFailure("Invalid time value") }
                            return ["index": .number(Double(idx)), "name": .string(f.name), "extension": .string(f.ext),
                                    "modified": .string(JSDate(f.modifiedAt.rounded(.towardZero)).toISOString().jsSlice(0, 10))]
                        })
                    ],
                    questions: Jev.object(batch.indices.map { idx in ("f\(idx)", .choice("Which group does file \(idx) belong in?", criteria)) })
                ))

                inputTokens += reply.inputTokens
                guard let answers = reply.answers else { throw JevFailure("Unexpected response shape.") }
                for (idx, f) in batch.enumerated() {
                    guard let answer = answers["f\(idx)"], answer.type == "choice", answer.choice != "unsorted" else {
                        unsorted.append(f.name)
                        continue
                    }
                    // A choice answer that names nothing counts as assigned, to nowhere.
                    named.insert(f.name)
                    assignments[f.name] = answer.choice
                }
            }

            note("assign_files", true, clock() - started, jevCost(inputTokens), inputTokens, "\(named.count) assigned, \(unsorted.count) unsorted", 1)
            return JevAssignment(assignments: assignments, unsorted: unsorted)
        } catch {
            note("assign_files", true, clock() - started, jevCost(inputTokens), inputTokens, "failed", 0)
            return nil
        }
    }

    // MARK: Accounting

    private func note(_ decision: String, _ usedModel: Bool, _ latencyMs: Double, _ usd: Double, _ inputTokens: Double, _ outcome: String, _ confidence: Double) {
        lock.lock(); defer { lock.unlock() }
        let tokens = inputTokens.isFinite && abs(inputTokens) < 9e18 ? Int(inputTokens) : 0
        record.calls.append(JevCallRecord(decision: decision, usedModel: usedModel, latencyMs: latencyMs, usd: usd, inputTokens: tokens, outcome: outcome, confidence: confidence))
        record.totalUsd += usd
        record.totalLatencyMs += latencyMs
    }

    private func override() {
        lock.lock(); defer { lock.unlock() }
        record.overrides += 1
    }

    /// Forgets every cooldown. For tests.
    static func resetCooldowns() {
        downLock.lock(); defer { downLock.unlock() }
        downUntil.removeAll()
    }
}

// MARK: - The keyword reading

private let FAMILY_WORDS: [Family: Rx] = [
    .files: Rx.ecma("\\b(files?|folders?|downloads?|desktop|documents?|pdfs?|screenshots?|images?|photos?|rename|organi[sz]e|tidy)\\b", "i"),
    .desktop: Rx.ecma("\\b(click|window|menu|button|type into|in the app)\\b", "i"),
    .browser: Rx.ecma("\\b(website|site|web|online|google|search for|look up|download from|https?:\\/\\/|\\w+\\.(com|org|io|net|dev|ai|in|co))\\b", "i"),
    .calendar: Rx.ecma("\\b(calendar|meeting|event|schedule|appointment|agenda|free (?:at|hour|time|slot|between)|busy|call with|availability)\\b", "i"),
    .reminders: Rx.ecma("\\b(remind|reminders?|to-?do|todo)\\b", "i"),
    .notes: Rx.ecma("\\b(notes?|jot)\\b", "i"),
    .mail: Rx.ecma("\\b(e-?mail|mail|reply to|draft)\\b", "i"),
    .shortcuts: Rx.ecma("\\bshortcuts?\\b", "i"),
    .system: Rx.ecma("\\b(dark mode|light mode|volume|mute|unmute|quit|launch|open (?:the )?app)\\b", "i")
]

private enum SetupWords {
    static let deictic = Rx.ecma("\\b(this|that|it|these|those|here)\\b", "i")
    static let page = Rx.ecma("\\b(page|tab|site|article|link|video|post|thread)\\b", "i")
    static let open = Rx.ecma("\\b(have open|had open|got open|currently|current|viewing|reading|watching|looking at|i'?m on|on screen)\\b", "i")
    static let selected = Rx.ecma("\\b(files?|folders?|selected)\\b", "i")
    static let clipboard = Rx.ecma("\\b(clipboard|copied|paste)\\b", "i")
    static let sequence = Rx.ecma("\\b(and then|then|after that|every|each|all of)\\b", "i")
    static let personal = Rx.ecma("\\b(watch|play|listen|my (?:feed|home ?feed|inbox|account|playlist|subscriptions|timeline|profile)|youtube|netflix|spotify|twitter|x\\.com|instagram|reddit|gmail|linkedin|in (?:my )?(?:browser|chrome|safari))\\b", "i")
    static let unattended = Rx.ecma("\\b(download|fill (?:in|out)|sign ?up|scrape)\\b", "i")
    static let webby = Rx.ecma("\\b(youtube|netflix|spotify|website|site|web|online|watch|video)\\b", "i")
    static let address = Rx.ecma("\\bhttps?:\\/\\/|\\b[a-z0-9-]+\\.(?:com|org|io|net|dev|ai|in|co)\\b", "i")
    static let openEnded = Rx.ecma("\\b(something|anything|good|recommend)\\b", "i")
    static let browsing = Rx.ecma("\\b(something|anything|a good|good|recommend|random|to watch|to listen|while)\\b", "i")
}

/// The keyword reading of the same questions, used without Jev and as a floor with it.
public func localPlanSetup(_ request: String, route: String, hasDroppedPaths: Bool) -> PlanSetup {
    var families = FAMILY_KEYS.filter { FAMILY_WORDS[$0]!.test(request) }
    if hasDroppedPaths && !families.contains(.files) { families.append(.files) }
    if families.isEmpty {
        // Nothing named: fall back to what the route implies.
        if route == "browser" { families.append(.browser) }
        else if route == "desktop" { families += [.desktop, .system] }
        else if route == "files" { families.append(.files) }
    }
    let deictic = SetupWords.deictic.test(request)
    return PlanSetup(
        families: families,
        context: PlanSetup.Context(
            selection: deictic && !hasDroppedPaths,
            tab: SetupWords.page.test(request) && (deictic || SetupWords.open.test(request)),
            finder: deictic && SetupWords.selected.test(request) && !hasDroppedPaths,
            clipboard: SetupWords.clipboard.test(request)
        ),
        quick: request.ecmaWordCount <= 14 && !SetupWords.sequence.test(request),
        ownBrowser: SetupWords.personal.test(request) && !SetupWords.unattended.test(request),
        start: !families.contains(.browser) && !SetupWords.webby.test(request)
            ? .none
            : SetupWords.address.test(request) && !SetupWords.openEnded.test(request)
                ? .direct
                : SetupWords.browsing.test(request)
                    ? .feed
                    : .search,
        source: .local
    )
}

func describeSetup(_ s: PlanSetup) -> String {
    let ctx = [("selection", s.context.selection), ("tab", s.context.tab), ("finder", s.context.finder), ("clipboard", s.context.clipboard)].filter(\.1).map(\.0)
    let web = s.start != .none ? ", web: \(s.ownBrowser ? "your browser" : "Merry's browser") from \(s.start.rawValue)" : ""
    let families = s.families.map(\.rawValue).joined(separator: "+")
    return "\(families.isEmpty ? "everything" : families)\(ctx.isEmpty ? "" : ", fetch \(ctx.joined(separator: "+"))")\(web), \(s.quick ? "quick" : "full") model"
}

/// Summary line for the task history, so Jev's cost and effect stay visible.
public func summarizeJev(_ m: JevMetrics) -> String {
    let modelCalls = m.calls.filter(\.usedModel).count
    return "\(m.calls.count) decisions (\(modelCalls) via Jev, \(m.overrides) changed the local verdict), " +
        "\(JSON.number(m.totalLatencyMs).stringify())ms, $\(m.totalUsd.toFixed(5))"
}

// MARK: - JavaScript's regular expressions

extension Rx {
    private static let ecmaLock = NSLock()
    private nonisolated(unsafe) static var ecmaCache: [String: Rx] = [:]

    /// A pattern written for JavaScript, compiled to mean here what it means there.
    ///
    /// The two engines disagree in ways that only show on unusual input, which
    /// is exactly the input a person eventually types: JavaScript's `\b`, `\w`
    /// and `\d` are ASCII-only where ICU's follow Unicode; `\s` covers a
    /// slightly different set; `.` stops at fewer line breaks; and `$` matches
    /// only at the very end, where ICU's also matches before a final newline.
    static func ecma(_ pattern: String, _ flags: String = "") -> Rx {
        let key = "\(flags)/\(pattern)"
        ecmaLock.lock()
        if let cached = ecmaCache[key] { ecmaLock.unlock(); return cached }
        ecmaLock.unlock()
        let rx = Rx(ecmaSource(pattern, flags), flags)
        ecmaLock.lock()
        ecmaCache[key] = rx
        ecmaLock.unlock()
        return rx
    }

    static func ecmaSource(_ pattern: String, _ flags: String) -> String {
        let word = "A-Za-z0-9_"
        let space = "\\t\\n\\x0B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
        let breaks = "\\n\\r\\u2028\\u2029"
        let isWord = "(?-i:[\(word)])"
        let chars = Array(pattern)
        var out = ""
        var inClass = false
        var classStart = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                i += 2
                switch next {
                case "b": out += inClass ? "\\x08" : "(?:(?<=\(isWord))(?!\(isWord))|(?<!\(isWord))(?=\(isWord)))"
                case "B":
                    precondition(!inClass, "\\B inside a class: \(pattern)")
                    out += "(?:(?<=\(isWord))(?=\(isWord))|(?<!\(isWord))(?!\(isWord)))"
                case "w": out += inClass ? word : isWord
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "s": out += inClass ? space : "[\(space)]"
                case "W", "D", "S":
                    precondition(!inClass, "negated escape inside a class: \(pattern)")
                    out += next == "W" ? "(?-i:[^\(word)])" : next == "D" ? "[^0-9]" : "[^\(space)]"
                default: out += "\\" + String(next)
                }
                classStart = false
                continue
            }
            i += 1
            if inClass {
                if c == "^" && classStart && chars[i - 2] == "[" { out += "^"; continue }
                switch c {
                case "]": inClass = false; out += "]"
                // ICU reads these as set syntax; JavaScript reads them as themselves.
                case "[": out += "\\["
                case "&": out += "\\&"
                case "-" where classStart || (i < chars.count && chars[i] == "]"): out += "\\-"
                default: out.append(c)
                }
                classStart = false
                continue
            }
            switch c {
            case "[": inClass = true; classStart = true; out += "["
            case "." where !flags.contains("s"): out += "[^\(breaks)]"
            case "$": out += flags.contains("m") ? "(?=[\(breaks)]|\\z)" : "\\z"
            default: out.append(c)
            }
        }
        return out
    }

    /// The usual `escapeRegExp`: `text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')`.
    static func ecmaEscape(_ text: String) -> String {
        var out = ""
        for c in text {
            if ".*+?^${}()|[]\\".contains(c) { out += "\\" }
            out.append(c)
        }
        return out
    }
}

extension String {
    /// `string.trim()`, over exactly the characters JavaScript calls white space.
    var ecmaTrimmed: String { Rx.ecma("^\\s+|\\s+$").replaceAll(self, "") }

    /// `string.trim().split(/\s+/).length`.
    var ecmaWordCount: Int { Rx.ecma("\\s+").split(ecmaTrimmed).count }
}
