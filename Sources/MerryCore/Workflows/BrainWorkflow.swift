import Foundation

private let externalApp = Rx("\\b(?:apple (?:notes|reminders)|(?:in|to|using) (?:the )?(?:notes|reminders) app|calendar)\\b", "i")
private let brainShape = Rx("^(?:(?:hey merry|merry|please)[, ]+)*(?:(?:start|set|pause|resume|cancel|stop) (?:a |an |the |my )?(?:\\d+(?:\\.\\d+)?[ -](?:minute|second|hour)s?[ -])?(?:focus )?timer\\b|(?:focus|time me) for\\b|remind me\\b|remember to\\b|(?:set|add) a reminder\\b|save where I am\\b|resume (?:my )?(?:project|session)\\b|note:|(?:make|take|create|save|add) (?:a )?note\\b|(?:save|keep) (?:this|that|these)\\b|(?:add|create) (?:a )?(?:task|project|tracker)\\b|track .+ daily$|(?:show|list|what(?:'s| is| are)) (?:in )?(?:my |merry(?:'s)? )?(?:workspace|notes|tasks|reminders|projects|trackers)\\b)", "i")

/// Whether this is a request for Merry's own workspace rather than for another app.
public func isBrainRequest(_ text: String) -> Bool {
    if externalApp.test(text) { return false }
    return brainShape.test(spelledDurations(text.jsTrimmed))
}

/// A date and time the way `toLocaleString()` writes it for this workspace.
private func localString(_ ms: Double) -> String { JSDate(ms).format("M/d/yyyy, h:mm:ss a") }

/// Narrow, local commands stay useful without a model connection. Novel combinations hand off.
public func runBrainWorkflow(_ request: String, _ dropped: [String], _ ctx: WorkflowContext, previousApp: String? = nil, now: JSDate = JSDate()) async throws -> WorkflowResult? {
    if !isBrainRequest(request) { return nil }
    let text = Rx("^(?:(?:hey merry|merry|please)[, ]+)*", "i").replaceFirst(request.jsTrimmed, "")

    /// Sends one workspace request and returns the items it reports.
    func run(_ req: JSON) async throws -> [JSON] {
        let result = try await ctx.run("merry_workspace", ["request": req])
        if !result.ok { throw MerryError(result.error ?? "Could not save to Merry.") }
        return result.result?.list("items") ?? []
    }
    func seeContext(_ want: JSON) async throws -> ScreenContext? {
        var input = want
        if let previousApp, !previousApp.isEmpty { input["app"] = .string(previousApp) }
        let seen = try await ctx.run("context_now", input)
        return seen.ok ? seen.result.map(ScreenContext.init(json:)) : nil
    }
    func source(_ kind: String, _ label: String, _ value: String) -> JSON { ["kind": .string(kind), "label": .string(label), "value": .string(value)] }
    func evidence(_ sources: [JSON]) -> [Evidence] {
        sources.map { Evidence(kind: $0.str("kind") == "url" ? .url : .path, label: $0.str("label"), value: $0.str("value")) }
    }

    if let session = Rx("^save where I am(?: with (.+?))?(?:[.!]\\s*|$)(.*)$", "is").exec(text) {
        let name = session[1]?.jsTrimmed ?? "Work session"
        let next = session[2]?.jsTrimmed ?? ""
        let context = try await seeContext(["selection": true, "tab": true, "finder": true])
        var sources = (dropped + (context?.finderPaths ?? [])).unique.map { source("path", Path.basename($0), $0) }
        if let url = context?.tabURL { sources.append(source("url", context?.tabTitle ?? "", url)) }
        let selection = context?.selectedText ?? ""
        if next.isEmpty && sources.isEmpty && selection.isEmpty {
            return WorkflowResult(success: false, headline: "Tell me your next step, or drop the files you want to return to.")
        }
        var projectId: JSON = .null
        if session[1] != nil {
            let projects = try await run(["op": "list", "kind": "project"]).filter { $0.str("status") == "open" && $0.str("title").lowercased() == name.lowercased() }
            if projects.count > 1 { return nil }
            if projects.count == 1 { projectId = .string(projects[0].str("id")) }
            else { projectId = .string(try await run(["op": "create", "item": ["kind": "project", "title": .string(name)]]).first?.str("id") ?? "") }
        }
        let pageSelection = context?.page?.optStr("selection") ?? ""
        let body = [next, selection.isEmpty ? pageSelection : selection].filter { !$0.isEmpty }.joined(separator: "\n\n")
        _ = try await run(["op": "create", "item": ["kind": "session", "title": .string("\(name) · \(now.format("M/d/yyyy"))"), "body": .string(body), "sources": .array(sources), "projectId": projectId]])
        return WorkflowResult(success: true, headline: "Saved where you left off with \(name). \(next.isEmpty ? "Your sources are in Workspace → Sessions." : next)", evidence: evidence(sources))
    }

    if let resume = Rx("^resume (?:my )?(?:project|session) [\"']?(.+?)[\"']?[.!]?$", "i").exec(text) {
        let projects = try await run(["op": "list", "kind": "project"])
        let wanted = resume[1] ?? ""
        let name = wanted.lowercased()
        let project = projects.first { $0.str("kind") == "project" && $0.str("title").lowercased() == name && $0.str("status") == "open" }
        let listed = try await run(.obj(["op": "list", "kind": "session", "projectId": project.map { .string($0.str("id")) }]))
        let sessions = listed.filter { i in
            i.str("kind") == "session" && i.str("status") == "open" && ((project != nil && i.optStr("projectId") == project?.str("id")) || i.str("title").lowercased().contains(name))
        }.ecmaSorted { $0.num("updatedAt") > $1.num("updatedAt") }
        guard let latest = sessions.first else { return WorkflowResult(success: false, headline: "No saved session for “\(wanted)” yet.") }
        guard let saved = try await run(["op": "list", "id": .string(latest.str("id"))]).first else {
            return WorkflowResult(success: false, headline: "No saved session for “\(wanted)” yet.")
        }
        let body = saved.str("body")
        return WorkflowResult(success: true, headline: "\(saved.str("title"))\n\n\(body.isEmpty ? "Your saved files and links are ready below." : body)", evidence: evidence(saved.list("sources")))
    }

    // Let planning interpret multiple jobs and content transformations, before changing anything.
    if Rx("\\b(?:and (?:then |also )?(?:remind|save|create|add|open)|summari[sz]e|extract|turn .+ into|rewrite)\\b", "i").test(text) { return nil }

    if let control = Rx("^(pause|resume|cancel|stop) (?:the |my )?(?:focus )?timer\\b", "i").exec(text) {
        let verb = (control[1] ?? "").lowercased()
        _ = try await run(["op": "timer", "action": .string(verb == "stop" ? "cancel" : verb)])
        return WorkflowResult(success: true, headline: "Timer \(verb == "pause" ? "paused" : verb == "resume" ? "resumed" : "cancelled").")
    }

    if Rx("\\btimer\\b|^(?:focus|time me) for\\b", "i").test(text) {
        // "a timer of one minute" is as clear as "a 1 minute timer".
        guard let duration = Rx("(\\d+(?:\\.\\d+)?)\\s*[- ]?\\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)\\b", "i").exec(spelledDurations(text)) else { return nil }
        let unit = duration[2] ?? ""
        let minutes = (Double(duration[1] ?? "") ?? 0) * (Rx("^s", "i").test(unit) ? 1.0 / 60 : Rx("^h", "i").test(unit) ? 60 : 1)
        let label = Rx("(?:called|named)\\s+(.+)$", "i").exec(text)?[1] ?? "Focus time"
        _ = try await run(["op": "timer", "action": "start", "minutes": .number(minutes), "label": .string(label)])
        return WorkflowResult(success: true, headline: "\(duration[1] ?? "") \(unit) on the clock. I'll keep time.")
    }

    if Rx("^(show|list|what)", "i").test(text) {
        let kind = Rx("\\b(notes|tasks|reminders|projects|trackers)\\b", "i").exec(text)?[1].map { Rx("s$").replaceFirst($0.lowercased(), "") }
        let items = try await run(.obj(["op": "list", "kind": kind.map(JSON.string)])).filter { $0.str("status") == "open" }
        return WorkflowResult(success: true, headline: items.isEmpty
            ? "Nothing here yet. You can add a note, task, reminder, project, or daily tracker."
            : items.prefix(30).map { "• \($0.str("title"))\($0["dueAt"]?.doubleValue.map { " · \(localString($0))" } ?? "")" }.joined(separator: "\n"))
    }

    var item: JSONObject?
    if Rx("^(remind me|remember to|set a reminder|add a reminder)", "i").test(text) {
        // Do not silently treat an unsupported recurrence as a one-time reminder.
        if Rx("\\bevery\\b", "i").test(text) && !Rx("\\bevery (?:day|week)\\b", "i").test(text) { return nil }
        let repeating = Rx("\\b(?:daily|every day)\\b", "i").test(text) ? "daily" : Rx("\\b(?:weekly|every week)\\b", "i").test(text) ? "weekly" : "none"
        let clean = Rx("\\b(?:daily|weekly|every day|every week)\\b", "i").replaceAll(text, "")
        var reading = readTime(clean, now: now)
        if reading == nil {
            let answer = try await ctx.askUser(QuestionDraft(reason: .ambiguous, prompt: "When should I remind you?", allowFreeText: true,
                                                             options: [QuestionOption(id: "hour", label: "In an hour"), QuestionOption(id: "tomorrow", label: "Tomorrow at 9am")]))
            let time = answer.optionId == "hour" ? "in 1 hour" : answer.optionId == "tomorrow" ? "tomorrow at 9am" : answer.text
            reading = time.flatMap { $0.isEmpty ? nil : readTime($0, now: now) }
            if reading == nil { return WorkflowResult(success: false, headline: "No reminder saved. Give me a time such as “tomorrow at 9am”.") }
        }
        guard let reading else { return nil }
        var due = reading.candidates[0]
        if reading.candidates.count > 1 {
            let answer = try await ctx.askUser(QuestionDraft(reason: .ambiguous, prompt: "Which time did you mean?", allowFreeText: false,
                                                             options: reading.candidates.enumerated().map { QuestionOption(id: String($0.offset), label: localString($0.element.time)) }))
            guard let id = answer.optionId, let index = Int(id), reading.candidates.indices.contains(index) else {
                return WorkflowResult(success: false, headline: "No reminder saved.")
            }
            due = reading.candidates[index]
        }
        if due.time <= now.time { return WorkflowResult(success: false, headline: "That time has passed. Please choose a future time.") }
        item = JSONObject([("kind", "reminder"), ("title", .string(reminderTitle(clean, readTime(clean, now: now)))), ("dueAt", .number(due.time)), ("repeat", .string(repeating))])
    } else if let create = Rx("^(?:add|create|make|take|save) (?:a )?(note|task|project|tracker)(?:\\s+(?:called|named))?\\s*:?\\s+(.+)$", "is").exec(text) {
        let kind = (create[1] ?? "").lowercased()
        let rest = create[2] ?? ""
        item = JSONObject([("kind", .string(kind)), ("title", .string((rest.jsSplit("\n").first ?? "").jsSlice(0, 300))), ("body", .string(kind == "note" ? rest : ""))])
    } else if Rx("^note:", "i").test(text) {
        let body = Rx("^note:\\s*", "i").replaceFirst(text, "")
        item = JSONObject([("kind", "note"), ("title", .string((body.jsSplit("\n").first ?? "").jsSlice(0, 100))), ("body", .string(body))])
    } else if let track = Rx("^track (.+?) daily[.!]?$", "i").exec(text) {
        item = JSONObject([("kind", "tracker"), ("title", .string(track[1] ?? ""))])
    }

    if item == nil, Rx("^(save|keep) (this|that|these)\\b", "i").test(text) {
        // Broader transformations should be interpreted by the planner, not stored as a link.
        if !Rx("^(save|keep) (this|that|these)(?: (?:for later|to (?:my )?notes|for .+))?[.!]?$", "i").test(text) { return nil }
        var sources = dropped.map { source("path", Path.basename($0), $0) }
        let context = dropped.isEmpty ? try await seeContext(["selection": true, "tab": true, "finder": true]) : nil
        let own = context?.selectedText ?? ""
        let selection = own.isEmpty ? (context?.page?.optStr("selection") ?? "") : own
        if let url = context?.tabURL { sources.append(source("url", context?.tabTitle ?? "", url)) }
        if sources.isEmpty { for path in context?.finderPaths ?? [] { sources.append(source("path", Path.basename(path), path)) } }
        if selection.isEmpty && sources.isEmpty { return WorkflowResult(success: false, headline: "Select some text, open a page, or drop files onto me first.") }
        var projectId: JSON = .null
        if let project = Rx("\\bfor (?!later\\b)(.+?)[.!]?$", "i").exec(text)?[1] {
            let existing = try await run(["op": "list", "kind": "project"]).filter { $0.str("status") == "open" && $0.str("title").lowercased() == project.lowercased() }
            if existing.count != 1 { return nil }
            projectId = .string(existing[0].str("id"))
        }
        item = JSONObject([
            ("kind", selection.isEmpty ? "bookmark" : "note"),
            ("title", .string(selection.isEmpty ? (sources.first?.str("label") ?? "") : (selection.jsSplit("\n").first ?? "").jsSlice(0, 100))),
            ("body", .string(selection)), ("sources", .array(sources)), ("projectId", projectId)
        ])
    }
    guard var item else { return nil }

    if item["kind"] == "reminder", Rx("^(?:this|that|it)[.!]?$", "i").test(item["title"]?.stringValue ?? "") {
        let context = try await seeContext(["selection": true, "tab": true])
        let own = context?.selectedText ?? ""
        let selection = own.isEmpty ? (context?.page?.optStr("selection") ?? "") : own
        if selection.isEmpty && context?.tabURL == nil {
            return WorkflowResult(success: false, headline: "Select what you want to be reminded about, or give it a name.")
        }
        item["title"] = .string(selection.isEmpty ? (context?.tabTitle ?? "") : (selection.jsSplit("\n").first ?? "").jsSlice(0, 300))
        item["body"] = .string(selection)
        item["sources"] = .array(context?.tabURL.map { [source("url", context?.tabTitle ?? "", $0)] } ?? [])
    }
    if item["kind"] == "task" {
        var title = item["title"]?.stringValue ?? ""
        let estimate = Rx("\\b(?:takes?|estimate|estimated)\\s+(\\d+)\\s*(?:minutes?|mins?)\\b", "i").exec(title)
        if let estimate { title = title.replacingOccurrences(of: estimate.text, with: "", options: [], range: title.range(of: estimate.text)).jsTrimmed }
        let reading = readTime(title, now: now)
        if let reading, reading.candidates.count > 1 { return nil }
        item["title"] = .string(stripTime(title, reading))
        if let reading { item["dueAt"] = .number(reading.candidates[0].time) }
        if let minutes = estimate?[1].flatMap(Double.init) { item["estimateMinutes"] = .number(minutes) }
    }
    let title = item["title"]?.stringValue ?? ""
    if title.jsTrimmed.isEmpty { return WorkflowResult(success: false, headline: "Give this a title first.") }
    _ = try await run(["op": "create", "item": .object(item)])
    let when = item["dueAt"]?.doubleValue.map { " · \(localString($0))" } ?? ""
    return WorkflowResult(success: true, headline: "Saved in Merry: \(title)\(when).", evidence: [
        .text("Workspace", item["kind"] == "reminder" ? "I’ll remind you when it’s due, or when you return to Merry." : "Kept locally in your workspace.")
    ])
}
