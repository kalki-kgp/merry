import Foundation

// What Merry remembers, and, more importantly, when it brings it up.
//
// The rule is relevance. A memory reaches a task only when it would help with
// that task: "my manager is Priya" belongs in "email my manager", not in
// "tidy my Downloads". Local code shortlists memories that share words or a
// topic with the request; Jev then judges each one on the shortlist with a
// yes/no; without Jev the shortlist has to clear a stricter bar instead.
// Nothing that fails is mentioned anywhere.
//
// Nothing here decides anything on its own. A remembered default is a
// starting point the person can see ("From memory: …") and overrule.

// MARK: - Words

private let STOP: Set<String> = [
    "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into",
    "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had", "will", "would", "can",
    "could", "should", "please", "merry", "hey", "i", "me", "my", "mine", "you", "your", "it", "its", "this", "that",
    "these", "those", "there", "here", "what", "when", "where", "which", "who", "how", "why", "all", "any", "some",
    "just", "also", "always", "never", "remember", "forget", "know", "like", "want", "need", "get", "make", "put",
    "add", "set", "up", "out", "new", "now", "today", "tomorrow", "tonight", "am", "pm", "next", "last", "every",
    "thing", "things", "stuff", "one", "use", "using", "so", "if", "than", "then", "too", "very", "really", "ok"
]

/// Lower-case word stems, with plurals folded, minus the words every request has.
public func words(_ text: String) -> [String] {
    var out: [String] = []
    for raw in Rx.ecma("[^a-z0-9@.+-]+").split(text.lowercased()) {
        let w = Rx.ecma("^[.+-]+|[.+-]+$").replaceAll(raw, "")
        if w.jsLength < 2 || STOP.contains(w) || Rx.ecma("^\\d+$").test(w) { continue }
        out.append(w.hasSuffix("ies") ? "\(w.jsSlice(0, -3))y" : w.jsLength > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? w.jsSlice(0, -1) : w)
    }
    return out.unique
}

/// Topics a memory or a request touches, from the same words the planner setup uses.
private let TOPICS: [(String, Rx)] = [
    ("calendar", Rx.ecma("\\b(calendar|meeting|event|schedule|appointment|standup|call|sync|1:1)s?\\b", "i")),
    ("reminders", Rx.ecma("\\b(remind|reminder|to-?do|task)s?\\b", "i")),
    ("notes", Rx.ecma("\\bnotes?\\b", "i")),
    ("mail", Rx.ecma("\\b(e-?mail|mail|inbox|reply|draft|signature)s?\\b", "i")),
    ("files", Rx.ecma("\\b(files?|folders?|downloads?|desktop|documents?|pdfs?|screenshots?|invoices?|receipts?)\\b", "i")),
    ("web", Rx.ecma("\\b(browser|website|site|chrome|safari|arc|web)\\b", "i")),
    ("time", Rx.ecma("\\b(time|clock|24-?hour|12-?hour|timezone|morning|evening|hours?)\\b", "i"))
]

public func topics(_ text: String) -> [String] {
    TOPICS.filter { $0.1.test(text) }.map(\.0)
}

// MARK: - What must never be remembered

/// Secrets stay out of memory whatever anyone asks, because memory is shown
/// back and sent to the model when relevant. Card numbers, passwords, one-time
/// codes, keys and government ID numbers are refused here, in code.
public func looksSecret(_ text: String) -> String? {
    let t = text.lowercased()
    if Rx.ecma("\\b(password|passcode|passwd|pin code|\\bpin\\b|otp|one[- ]time code|2fa|secret key|api key|private key|seed phrase|recovery phrase|cvv|security code)\\b").test(t) {
        return "passwords, codes and keys"
    }
    let digits = Rx.ecma("[\\s-]").replaceAll(text, "")
    if let run = Rx.ecma("\\d{13,19}").exec(digits), luhn(run.text) { return "card numbers" }
    if Rx.ecma("\\b\\d{4}\\s?\\d{4}\\s?\\d{4}\\b").test(text) && Rx.ecma("aadhaa?r|uid", "i").test(text) { return "ID numbers" }
    if Rx.ecma("\\b(sk|pk|ghp|xox[abp])[-_][a-z0-9_-]{16,}\\b", "i").test(text) { return "keys" }
    return nil
}

private func luhn(_ n: String) -> Bool {
    var sum = 0
    for (i, c) in n.utf8.reversed().enumerated() {
        var d = Int(c) - 48
        if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
        sum += d
    }
    return sum % 10 == 0
}

// MARK: - Making memories

extension String {
    /// `s.charAt(0).toUpperCase() + s.slice(1)`: only the first UTF-16 unit is
    /// raised, so a character outside the basic plane is left as it is.
    var ecmaUpperFirst: String {
        guard let first = unicodeScalars.first, first.value <= 0xFFFF else { return self }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: unicodeScalars.dropFirst())
        return String(first).uppercased() + String(rest)
    }
}

public func makeMemory(
    _ text: String,
    kind: String,
    source: String,
    keys: [String]? = nil,
    choice: Memory.Choice? = nil,
    id: String = newId(),
    now: Double = nowMs()
) -> Memory {
    let clean = Rx.ecma("\\s+").replaceAll(text, " ").ecmaTrimmed
    return Memory(
        id: id,
        text: clean.ecmaUpperFirst,
        kind: kind,
        keys: Array(((keys ?? []) + words(clean)).unique.prefix(16)),
        choice: choice,
        source: source,
        evidence: 1,
        createdAt: now,
        updatedAt: now,
        lastUsedAt: nil,
        uses: 0
    )
}

private enum Told {
    static let that = Rx.ecma("^(?:hey |please |merry[, ]+)*(?:can you |could you )?(?:remember|keep in mind|don'?t forget)\\s*(?:that|:|,)\\s*(.+)$", "i")
    static let about = Rx.ecma("^(?:hey |please |merry[, ]+)*(?:remember|keep in mind|don'?t forget)\\s+(?!to\\b)((?:my|i|i'm|i am|we|our|the)\\b.+)$", "i")
    static let preference = Rx.ecma("\\b(prefer|like|love|hate|always|never|rather|don'?t like)\\b", "i")
    static let standing = Rx.ecma("^(?:from now on|going forward|in (?:the )?future),?\\s+(.+)$", "i")
}

/// "Remember that my manager is Priya" → "My manager is Priya".
/// "Remember to call mom" is a reminder, not a memory, and is not claimed here.
public func explicitMemory(_ request: String) -> (text: String, kind: String)? {
    let r = request.ecmaTrimmed
    if let told = Told.that.exec(r) ?? Told.about.exec(r), let said = told[1] {
        return (tidy(said), Told.preference.test(said) ? "preference" : "fact")
    }
    if let standing = Told.standing.exec(r), let said = standing[1] { return (tidy(said), "preference") }
    return nil
}

private func tidy(_ s: String) -> String {
    Rx.ecma("^\\s+").replaceFirst(Rx.ecma("[\\s.!]+$").replaceFirst(s, ""), "")
}

/// Folds a new memory into what is already known, rather than keeping near-copies.
public func mergeMemory(_ existing: [Memory], _ incoming: Memory, now: Double = nowMs()) -> (memory: Memory, replaces: String?) {
    if let choice = incoming.choice {
        let same = existing.first { m in
            m.choice?.decision == choice.decision && overlap(m.keys, incoming.keys) >= min(m.keys.count, incoming.keys.count, 2)
        }
        if var same {
            // Same decision about the same kind of thing: the newest answer wins,
            // and repeating an answer makes it more trusted.
            let agrees = same.choice!.value == choice.value
            let replaces = same.id
            same.text = incoming.text
            same.choice = choice
            same.evidence = agrees ? same.evidence + 1 : 1
            same.updatedAt = now
            return (same, replaces)
        }
    }
    func norm(_ t: String) -> String { words(t).sorted().joined(separator: " ") }
    if var dup = existing.first(where: { norm($0.text) == norm(incoming.text) }) {
        dup.evidence += 1
        dup.updatedAt = now
        return (dup, dup.id)
    }
    return (incoming, nil)
}

private func overlap(_ a: [String], _ b: [String]) -> Int {
    let set = Set(a)
    return b.filter(set.contains).count
}

// MARK: - Recall

public struct Recalled: Equatable, Sendable {
    public var memory: Memory
    /// Why it came up, for the log.
    public var why: String
    public init(memory: Memory, why: String) { self.memory = memory; self.why = why }
}

/// How strongly a memory's words and topics match a request. Local and instant.
public func lexicalScore(_ request: String, _ m: Memory) -> Int {
    let req = Set(words(request))
    let keyHits = m.keys.filter(req.contains).count
    let about = topics(m.text)
    let topicHits = topics(request).filter(about.contains).count
    // A shared name or distinctive word counts for much more than a shared topic.
    return keyHits * 2 + topicHits
}

extension Array {
    /// `array.sort(compare)` as JavaScript does it: equal elements keep their order.
    func ecmaSorted(_ before: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if before(a.element, b.element) { return true }
            if before(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// The memories worth knowing for this request, at most `limit`.
///
/// With Jev: a shortlist (anything sharing a word or topic, or every memory
/// when there are only a few) goes to Jev in one call, one yes/no each, and
/// only the clear yeses come back. Without Jev: only memories sharing a
/// distinctive word with the request.
public func recall(_ request: String, _ memories: [Memory], _ jev: Jev?, limit: Int = 6) async -> [Recalled] {
    if memories.isEmpty { return [] }
    let scored = memories
        .map { (m: $0, score: lexicalScore(request, $0)) }
        .ecmaSorted { a, b in a.score != b.score ? a.score > b.score : a.m.uses > b.m.uses }

    guard let jev, jev.available else {
        let asked = words(request)
        return scored
            .filter { $0.score >= 2 }
            .prefix(max(limit, 0))
            .map { s in Recalled(memory: s.m, why: "shares \"\(s.m.keys.filter(asked.contains).joined(separator: "\", \""))\"") }
    }

    // A handful of memories can all be judged; more than that are shortlisted
    // first, so the call stays small and fast.
    let shortlist = Array((memories.count <= 16 ? scored : scored.filter { $0.score > 0 }).prefix(16))
    if shortlist.isEmpty { return [] }
    let questions = shortlist.enumerated().map { i, s in
        ("m\(i)", JevQuestion.noul("Would knowing this help with the request? \"\(s.m.text)\"", [
            "true": "Yes: it changes or improves what the assistant should do for this request.",
            "false": "No: it is about something else, and bringing it up would be odd."
        ]))
    }
    guard let answers = await jev.ask("recall", state: ["request": .string(request)], questions: questions) else {
        // Jev unreachable: the strict local bar, same as having no Jev.
        return shortlist.filter { $0.score >= 2 }.prefix(max(limit, 0)).map { Recalled(memory: $0.m, why: "shares words (Jev unavailable)") }
    }
    return shortlist.enumerated()
        .map { i, s in (m: s.m, p: answers["m\(i)"]?.noul ?? 0) }
        .filter { $0.p > 0.6 }
        .ecmaSorted { $0.p > $1.p }
        .prefix(max(limit, 0))
        .map { Recalled(memory: $0.m, why: "Jev: \(($0.p * 100).toFixed(0))% relevant") }
}

/// A learned default for one decision, when this request is about the same
/// kind of thing: "standup tomorrow 10am" → the calendar standups went on
/// before. Needs a shared distinctive word; a topic alone is not enough.
public func suggestChoice(_ decision: String, _ text: String, _ memories: [Memory], allowed: [String]? = nil) -> Memory? {
    let w = Set(words(text))
    return memories
        .filter { m in
            guard let choice = m.choice, choice.decision == decision else { return false }
            return allowed?.contains(choice.value) ?? true
        }
        .map { (m: $0, hits: $0.keys.filter(w.contains).count) }
        .filter { $0.hits > 0 }
        .ecmaSorted { a, b in
            if a.hits != b.hits { return a.hits > b.hits }
            if a.m.evidence != b.m.evidence { return a.m.evidence > b.m.evidence }
            return a.m.updatedAt > b.m.updatedAt
        }
        .first?.m
}

/// A learned choice: "Standup goes on the Work calendar."
public func learnedChoice(_ decision: String, _ value: String, about: String, sentence: String, id: String = newId(), now: Double = nowMs()) -> Memory? {
    let keys = words(about)
    if keys.isEmpty || looksSecret(about) != nil { return nil }
    return makeMemory(sentence, kind: "choice", source: "learned", keys: keys, choice: Memory.Choice(decision: decision, value: value), id: id, now: now)
}

/// How the planner is told what is remembered: data, clearly labelled, with ids to cite.
public func memoryNote(_ recalled: [Recalled]) -> String? {
    if recalled.isEmpty { return nil }
    let lines = recalled.map { "- [\($0.memory.id)] \($0.memory.text)" }.joined(separator: "\n")
    return "Things you know about the user, chosen because they look relevant to this request:\n<memory>\n\(lines)\n</memory>\n" +
        "Use them where they genuinely help, as defaults the user can overrule. If one does not matter to this request, ignore it " +
        "and do not mention it. When you rely on one, list its id in finish's usedMemories."
}
