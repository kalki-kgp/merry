import Foundation

// Everyday requests to Mac apps, handled by code and Jev with no planning
// model: "remind me to call the bank tomorrow at 5", "put dentist on my
// calendar friday 10am", "what's on tomorrow", "dark mode", "run my Focus
// shortcut", "make a note: …".
//
// The workflow rule holds here too. Titles and times are read out of the
// user's own words by local code; Jev only chooses between things that code
// built: which of two readings of "at 5", which of the user's real
// calendars, which of their real shortcuts. When a request needs anything
// invented, the workflow hands it to the planner.

private let appsRoutes = ["apps", "desktop", "files", "mixed", "unclear"]

/// Whether the request names this calendar, list or shortcut as a whole word.
private func names(_ request: String, _ name: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: [.caseInsensitive]) else { return false }
    return re.firstMatch(in: request, range: NSRange(location: 0, length: request.utf16.count)) != nil
}

/// Of two or more readings of a time, lets Jev pick; the first is the default.
private func pickTime(_ ctx: WorkflowContext, _ request: String, _ reading: TimeReading) async -> JSDate {
    if reading.candidates.count == 1 { return reading.candidates[0] }
    let options = reading.candidates.enumerated().map { ("t\($0.offset)", $0.element.format("EEEE h:mm a")) }
    let answers = await ctx.ask("pick_time", ["userRequest": .string(request), "now": .string(JSDate().format("M/d/yyyy, h:mm:ss a"))],
                                [("when", .choice("Which time does the user mean?", options))])
    let index = answers?["when"]?.choice.flatMap { Int($0.dropFirst()) } ?? 0
    return reading.candidates.indices.contains(index) ? reading.candidates[index] : reading.candidates[0]
}

/// One of the user's real names (calendars, lists, shortcuts): the one the
/// request names, else Jev's pick among them, else `fallback`.
private func pickNamed(_ ctx: WorkflowContext, _ label: String, _ request: String, _ list: [String], _ question: String, _ fallback: String?) async -> String? {
    if list.isEmpty { return fallback }
    if list.count == 1 { return list[0] }
    if let named = list.filter({ names(request, $0) }).ecmaSorted({ $0.jsLength > $1.jsLength }).first { return named }
    let options = list.prefix(60).enumerated().map { ("n\($0.offset)", $0.element) }
    let answers = await ctx.ask(label, ["userRequest": .string(request)], [("pick", .choice(question, options))])
    guard let pick = answers?["pick"]?.choice, let index = Int(pick.dropFirst()) else { return fallback }
    return list.indices.contains(index) ? list[index] : fallback
}

private func runOrFail(_ ctx: WorkflowContext, _ tool: String, _ input: JSON) async throws -> JSON {
    let res = try await ctx.run(tool, input)
    if !res.ok { throw MerryError(res.error ?? "\(tool) failed") }
    return res.result ?? .null
}

/// A failed step becomes the answer; a cancelled task stays cancelled.
private func failed(_ error: Error) throws -> WorkflowResult {
    if error is CancelledError { throw error }
    return WorkflowResult(success: false, headline: messageOf(error))
}

private func clockTime(_ d: JSDate) -> String { d.format("h:mm a").lowercased() }

// MARK: - Reminders

private let remind = Rx("\\b(?:remind me|set a reminder|add a reminder|remember to|add .+ to (?:my |the )?(?:[\\w-]+ )?(?:reminders|to-?do(?: list)?|todo list))\\b", "i")

func reminderTitle(_ request: String, _ reading: TimeReading?) -> String {
    var r = stripTime(request, reading)
    r = Rx("^\\s*(?:hey |please |merry[, ]+)*", "i").replaceFirst(r, "")
    if let add = Rx("^add (.+?) to (?:my |the )?(?:[\\w-]+ )?(?:reminders|to-?do(?: list)?|todo list)\\b(.*)$", "i").exec(r) {
        r = "\(add[1] ?? "") \(add[2] ?? "")"
    }
    r = Rx("^(?:can you |could you )?(?:remind me|set a reminder|add a reminder|remember)\\s*(?:to|about|that|:)?\\s*", "i").replaceFirst(r, "")
    r = Rx("\\s*\\b(?:please|thanks?|thank you)\\b\\s*$", "i").replaceFirst(r, "")
    return Rx("\\s{2,}").replaceAll(r, " ").jsTrimmed.capitalizedFirst
}

let reminderWorkflow = Workflow(
    id: "add_reminder",
    description: "Add a reminder to the Reminders app, possibly at a time.",
    routes: appsRoutes,
    plausible: { request, _ in remind.test(request) },
    run: { request, _, ctx in
        let reading = readTime(request)
        let title = reminderTitle(request, reading)
        if title.isEmpty { return WorkflowResult(success: false, headline: "What should I remind you about?", handoffToPlanner: "no reminder text") }
        do {
            let due: JSDate? = reading != nil ? await pickTime(ctx, request, reading!) : nil
            let lists = try await runOrFail(ctx, "reminders_lists", [:]).arrayValue?.compactMap(\.stringValue) ?? []
            // Only a list the user actually named; otherwise the default list.
            // "Reminders" is also just the word for them, so a specific name wins over it.
            let generic: (String) -> Bool = { Rx("^(reminders|to-?do|todo)$", "i").test($0) }
            let named = lists.filter { names(request, $0) }
                .ecmaSorted { a, b in generic(a) != generic(b) ? !generic(a) : a.jsLength > b.jsLength }.first
            // Not named this time: the list this kind of reminder went on before, if any.
            let remembered = named != nil ? nil : suggestChoice("reminder-list", title, ctx.memory.all(), allowed: lists)
            let list = named ?? remembered?.choice?.value
            let made = try await runOrFail(ctx, "reminders_create", .obj([
                "title": .string(title), "due": due.map { .string($0.toISOString()) }, "list": list.map(JSON.string)
            ]))
            let when = due.map { " \(describeTime($0, dateOnly: reading?.dateOnly ?? false))" } ?? ""
            var evidence: [Evidence] = [.text("Reminders · \(made.str("list"))", "\(title)\(when.isEmpty ? "" : " ·\(when)")")]
            if let remembered { evidence.append(ctx.memory.used(remembered)) }
            // Naming a specific list is a choice worth keeping for next time.
            if let named, !generic(named), ctx.memory.learn,
               let m = learnedChoice("reminder-list", named, about: title, sentence: "Reminders like \"\(title)\" go on the \(named) list") {
                _ = ctx.memory.keep(m)
            }
            return WorkflowResult(success: true, headline: "I'll remind you: \(title)\(when)\(remembered != nil ? " (on \(made.str("list")), like last time)" : "").", evidence: evidence)
        } catch {
            return try failed(error)
        }
    }
)

// MARK: - Calendar: add an event

private let addEvent = Rx("\\b(?:(?:add|put|schedule|book|block(?: out)?|create|set up)\\b.*\\b(?:calendar|meeting|event|appointment|call|lunch|dinner|coffee|sync|1:1|interview)|\\bon my calendar\\b)", "i")

func eventTitle(_ request: String, _ reading: TimeReading?) -> String {
    var r = stripTime(request, reading)
    r = Rx("^\\s*(?:hey |please |merry[, ]+)*(?:can you |could you )?", "i").replaceFirst(r, "")
    r = Rx("^(?:add|put|schedule|book|block(?: out)?|create|set up)\\s+(?:an? |the )?(?:new )?(?:event |meeting |time )?(?:for |called |named )?", "i").replaceFirst(r, "")
    r = Rx("\\s*\\b(?:to|on|in|into) (?:my |the )?(?:[\\w-]+ )?calendar\\b.*$", "i").replaceFirst(r, "")
    r = Rx("\\s*\\bon my calendar\\b", "i").replaceFirst(r, "")
    r = Rx("\\s*\\b(?:please|thanks?)\\b\\s*$", "i").replaceFirst(r, "")
    return Rx("\\s{2,}").replaceAll(r, " ").jsTrimmed.capitalizedFirst
}

let eventWorkflow = Workflow(
    id: "add_event",
    description: "Add an event or meeting to the Calendar app at a given time.",
    routes: appsRoutes,
    plausible: { request, _ in addEvent.test(request) && !remind.test(request) && !Rx("\\b(what|when|am i|do i have)\\b", "i").test(request) },
    run: { request, _, ctx in
        guard let reading = readTime(request) else {
            return WorkflowResult(success: false, headline: "When should it be?", handoffToPlanner: "no time given for the event")
        }
        let title = eventTitle(request, reading)
        if title.isEmpty { return WorkflowResult(success: false, headline: "What is the event?", handoffToPlanner: "no event title") }
        do {
            let start = await pickTime(ctx, request, reading)
            let minutes = reading.durationMin ?? 60
            let end = reading.dateOnly ? JSDate(start.time + 86_400_000) : JSDate(start.time + minutes * 60_000)

            let calendars = (try await runOrFail(ctx, "calendar_list_calendars", [:]).arrayValue ?? [])
                // Calendars macOS keeps for itself are never where a new event belongs.
                .filter { $0.flag("writable") && !Rx("^(scheduled reminders|siri suggestions|birthdays|found in (mail|apps))$", "i").test($0.str("name")) }
                .map { $0.str("name") }
            let named = calendars.filter { names(request, $0) }.ecmaSorted { $0.jsLength > $1.jsLength }.first
            // Not named this time: where this kind of event went before, else Jev's pick.
            let remembered = named != nil ? nil : suggestChoice("calendar", title, ctx.memory.all(), allowed: calendars)
            var calendar = named ?? remembered?.choice?.value
            if calendar == nil {
                calendar = await pickNamed(ctx, "pick_calendar", request, calendars, "Which calendar does this event belong on?", calendars.first)
            }

            // A heads-up about clashes costs one read and saves a double booking.
            var clashes: [JSON] = []
            if !reading.dateOnly {
                let res = try await ctx.run("calendar_events", ["from": .string(start.toISOString()), "to": .string(end.toISOString())])
                if res.ok { clashes = res.result?.arrayValue ?? [] }
            }

            _ = try await runOrFail(ctx, "calendar_create_event", .obj([
                "title": .string(title), "start": .string(start.toISOString()), "end": .string(end.toISOString()),
                "allDay": .bool(reading.dateOnly), "calendar": calendar.map(JSON.string)
            ]))
            let when = describeTime(start, dateOnly: reading.dateOnly)
            let clash = clashes.first { !$0.flag("allDay") }
            var evidence: [Evidence] = [.text("Calendar\(calendar.map { " · \($0)" } ?? "")", "\(title) · \(when)")]
            if let remembered { evidence.append(ctx.memory.used(remembered)) }
            // Naming the calendar is the person's choice; keep it for events like this one.
            if let named, calendars.count > 1, ctx.memory.learn,
               let m = learnedChoice("calendar", named, about: title, sentence: "Events like \"\(title)\" go on the \(named) calendar") {
                _ = ctx.memory.keep(m)
            }
            return WorkflowResult(
                success: true,
                headline: "Added \"\(title)\" \(when)\(calendar.map { " to \($0)" } ?? "")\(remembered != nil ? ", like last time" : "").\(clash.map { " Heads up: it overlaps \"\($0.str("title"))\"." } ?? "")",
                evidence: evidence
            )
        } catch {
            return try failed(error)
        }
    }
)

// MARK: - Calendar: what's on

private let agenda = Rx("\\b(?:what(?:'s| is| do i have)? (?:on )?(?:my )?(?:calendar|schedule|agenda)|what(?:'s| is) (?:on |happening )?(?:today|tomorrow|this week|next)|am i (?:free|busy)|do i have (?:any )?(?:meetings?|events?|anything)|my (?:day|week|schedule) look|meetings? (?:today|tomorrow|this week))\\b", "i")

struct AgendaRange {
    var from: JSDate
    var to: JSDate
    var label: String
    var probe: JSDate?
}

func agendaRange(_ request: String, now: JSDate = JSDate()) -> AgendaRange {
    func day(_ offset: Int) -> JSDate { now.with { $0.setHours(0, 0, 0, 0); $0.setDate($0.day + offset) } }
    if Rx("\\bwhat(?:'s| is) next\\b", "i").test(request) { return AgendaRange(from: now, to: day(2), label: "next") }
    if Rx("\\b(?:this|the) week\\b|\\bmy week\\b", "i").test(request) { return AgendaRange(from: now, to: day(7), label: "this week") }
    let reading = readTime(request, now: now)
    if let reading, !reading.dateOnly, Rx("\\bam i (?:free|busy)\\b", "i").test(request) {
        let at = reading.candidates[0]
        return AgendaRange(from: at, to: JSDate(at.time + (reading.durationMin ?? 60) * 60_000), label: describeTime(at, dateOnly: false, now: now), probe: at)
    }
    if let reading {
        let d = reading.candidates[0].with { $0.setHours(0, 0, 0, 0) }
        let end = d.with { $0.setDate($0.day + 1) }
        return AgendaRange(from: d.time < now.time ? now : d, to: end, label: describeTime(d, dateOnly: true, now: now))
    }
    return AgendaRange(from: now, to: day(1), label: "today")
}

// MARK: - Calendar: finding free time

private let freeSlot = Rx("\\b(?:(?:first|next|a|an|any) )?free (?:hour|slot|time|half[- ]hour|\\d+ ?(?:min(?:ute)?s?|hours?))\\b|\\bwhen am i free\\b|\\bfind (?:me )?(?:a |an )?(?:free )?(?:slot|time|hour|gap)\\b", "i")

/// One hour, unless the sentence says otherwise.
private func slotMinutes(_ request: String, _ reading: TimeReading?) -> Double {
    let r = request.lowercased()
    if Rx("half[- ]hour").test(r) { return 30 }
    if let n = Rx("(\\d+) ?(min(?:ute)?s?|hours?)\\b").exec(r) { return (Double(n[1] ?? "") ?? 0) * ((n[2] ?? "").hasPrefix("h") ? 60 : 1) }
    return reading?.durationMin ?? 60
}

private func clockToMinutes(_ h: String, _ m: String?, _ mer: String?) -> Double {
    var hour = Double(h) ?? 0
    if mer == "pm" && hour < 12 { hour += 12 }
    if mer == "am" && hour == 12 { hour = 0 }
    return hour * 60 + (m.flatMap(Double.init) ?? 0)
}

struct FreeSlotQuery {
    var day: JSDate
    var windowStart: JSDate
    var windowEnd: JSDate
    var minutes: Double
}

/// The day, the working window and the length being asked about.
func freeSlotQuery(_ request: String, now: JSDate = JSDate()) -> FreeSlotQuery {
    let reading = readTime(request, now: now)
    let day = (reading?.candidates.first ?? now).with { $0.setHours(0, 0, 0, 0) }
    var from = 9.0 * 60, to = 18.0 * 60
    if let between = Rx("\\b(?:between|from) (\\d{1,2})(?::(\\d{2}))? ?(am|pm)? (?:and|to|-) (\\d{1,2})(?::(\\d{2}))? ?(am|pm)?", "i").exec(request) {
        from = clockToMinutes(between[1] ?? "", between[2], between[3]?.lowercased())
        // "between 9 and 5": the second number is afternoon.
        to = clockToMinutes(between[4] ?? "", between[5], between[6]?.lowercased() ?? ((Int(between[4] ?? "") ?? 0) < 9 ? "pm" : nil))
    }
    var windowStart = JSDate(day.time + from * 60_000)
    let windowEnd = JSDate(day.time + to * 60_000)
    // Today, the window starts from now, rounded up to the next half hour.
    if windowStart.time < now.time {
        windowStart = now.with { $0.setMinutes($0.minutes <= 30 ? 30 : 60, 0, 0) }
    }
    return FreeSlotQuery(day: day, windowStart: windowStart, windowEnd: windowEnd, minutes: slotMinutes(request, reading))
}

/// Gaps of at least `minutes` inside the window, around the busy events.
func freeGaps(_ q: FreeSlotQuery, _ busy: [JSON]) -> [(start: JSDate, end: JSDate)] {
    let blocks = busy.filter { !$0.flag("allDay") }
        .compactMap { e -> (start: Double, end: Double)? in
            guard let s = JSDate(iso: e.str("start")), let en = JSDate(iso: e.str("end")) else { return nil }
            return (s.time, en.time)
        }
        .ecmaSorted { $0.start < $1.start }
    var gaps: [(start: JSDate, end: JSDate)] = []
    var cursor = q.windowStart.time
    for b in blocks {
        if b.start - cursor >= q.minutes * 60_000 { gaps.append((JSDate(cursor), JSDate(b.start))) }
        cursor = max(cursor, b.end)
    }
    if q.windowEnd.time - cursor >= q.minutes * 60_000 { gaps.append((JSDate(cursor), q.windowEnd)) }
    return gaps.filter { $0.start.time < q.windowEnd.time }
}

let freeSlotWorkflow = Workflow(
    id: "free_slot",
    description: "Find when the user is free on a day, from their calendar.",
    routes: appsRoutes,
    plausible: { request, _ in freeSlot.test(request) },
    run: { request, _, ctx in
        let q = freeSlotQuery(request)
        if q.windowEnd.time <= q.windowStart.time {
            return WorkflowResult(success: true, headline: "That window has already passed \(describeTime(q.day, dateOnly: true)).")
        }
        do {
            let events = try await runOrFail(ctx, "calendar_events", ["from": .string(q.windowStart.toISOString()), "to": .string(q.windowEnd.toISOString())]).arrayValue ?? []
            let gaps = freeGaps(q, events)
            let day = describeTime(q.day, dateOnly: true)
            let length = q.minutes == 60 ? "hour" : q.minutes.truncatingRemainder(dividingBy: 60) == 0 ? "\(JSON.format(q.minutes / 60)) hours" : "\(JSON.format(q.minutes)) minutes"
            guard let first = gaps.first else {
                return WorkflowResult(success: true, headline: "No free \(length) \(day) between \(clockTime(q.windowStart)) and \(clockTime(q.windowEnd)).")
            }
            if events.filter({ !$0.flag("allDay") }).isEmpty {
                return WorkflowResult(success: true, headline: "You're free all \(day == "today" ? "of today" : day) from \(clockTime(q.windowStart)) to \(clockTime(q.windowEnd)).")
            }
            return WorkflowResult(
                success: true,
                headline: "Your first free \(length) \(day) starts at \(clockTime(first.start)).",
                evidence: [.text("Free \(day)", gaps.map { "\(clockTime($0.start)) – \(clockTime($0.end))" }.joined(separator: "\n"))]
            )
        } catch {
            return try failed(error)
        }
    }
)

let agendaWorkflow = Workflow(
    id: "agenda",
    description: "Answer what is on the user's calendar, or whether they are free, for a day or time.",
    routes: appsRoutes,
    plausible: { request, _ in agenda.test(request) && !freeSlot.test(request) },
    run: { request, _, ctx in
        let range = agendaRange(request)
        do {
            let events = try await runOrFail(ctx, "calendar_events", ["from": .string(range.from.toISOString()), "to": .string(range.to.toISOString())]).arrayValue ?? []
            let time: (String) -> String = { iso in JSDate(iso: iso).map(clockTime) ?? iso }
            let lines = events.map { $0.flag("allDay") ? "all day · \($0.str("title"))" : "\(time($0.str("start"))) · \($0.str("title"))" }
            if range.probe != nil {
                return events.isEmpty
                    ? WorkflowResult(success: true, headline: "You're free \(range.label).")
                    : WorkflowResult(success: true, headline: "You're busy \(range.label): \(events.map { $0.str("title") }.joined(separator: ", ")).",
                                     evidence: [.text("Overlapping", lines.joined(separator: "\n"))])
            }
            if events.isEmpty { return WorkflowResult(success: true, headline: "Nothing on your calendar \(range.label).") }
            if range.label == "next" {
                let next = events[0]
                let at = JSDate(iso: next.str("start")) ?? JSDate()
                return WorkflowResult(success: true, headline: "Next up: \(next.str("title")), \(describeTime(at, dateOnly: next.flag("allDay"))).")
            }
            let body = range.label == "this week"
                ? events.map { "\(JSDate(iso: $0.str("start"))?.format("EEE") ?? "") \($0.flag("allDay") ? "all day" : time($0.str("start"))) · \($0.str("title"))" }.joined(separator: "\n")
                : lines.joined(separator: "\n")
            return WorkflowResult(
                success: true,
                headline: "\(range.label.capitalizedFirst): \(events.count) \(events.count == 1 ? "thing" : "things") on your calendar.",
                evidence: [.text(range.label.capitalizedFirst, body)]
            )
        } catch {
            return try failed(error)
        }
    }
)

// MARK: - System settings

struct SettingPlan: Equatable {
    var tool: String
    var input: JSON
    var done: String
    var volume: Double?
}

func readSetting(_ request: String, currentVolume: Double? = nil) -> SettingPlan? {
    let r = request.lowercased()
    if Rx("\\b(dark mode|go dark|turn (?:on )?dark|lights off)\\b").test(r) && !Rx("\\b(off|disable)\\b.*dark|\\bdark mode off\\b").test(r) {
        return SettingPlan(tool: "system_appearance", input: ["dark": true], done: "Dark mode is on.")
    }
    if Rx("\\b(light mode|dark mode off|turn off dark mode|disable dark mode|lights on)\\b").test(r) {
        return SettingPlan(tool: "system_appearance", input: ["dark": false], done: "Light mode is on.")
    }
    if Rx("\\bunmute\\b").test(r) { return SettingPlan(tool: "system_volume", input: ["muted": false], done: "Sound is back on.") }
    if Rx("\\b(mute|silence)\\b").test(r) { return SettingPlan(tool: "system_volume", input: ["muted": true], done: "Muted.") }
    if let set = Rx("\\bvolume (?:to |at )?(\\d{1,3})\\s*%?").exec(r) ?? Rx("\\b(?:set|turn) (?:the )?(?:volume|sound) (?:to |at )?(\\d{1,3})").exec(r) {
        let v = min(100, Double(set[1] ?? "") ?? 0)
        return SettingPlan(tool: "system_volume", input: ["volume": .number(v), "muted": false], done: "Volume is at \(JSON.format(v)).", volume: v)
    }
    let step = currentVolume ?? 50
    if Rx("\\b(louder|turn (?:it |the volume |the sound )?up|volume up|increase (?:the )?volume)\\b").test(r) {
        let v = min(100, step + 15)
        return SettingPlan(tool: "system_volume", input: ["volume": .number(v), "muted": false], done: "Volume up to \(JSON.format(v)).", volume: v)
    }
    if Rx("\\b(quieter|turn (?:it |the volume |the sound )?down|volume down|lower (?:the )?volume|decrease (?:the )?volume)\\b").test(r) {
        let v = max(0, step - 15)
        return SettingPlan(tool: "system_volume", input: ["volume": .number(v)], done: "Volume down to \(JSON.format(v)).", volume: v)
    }
    return nil
}

let settingWorkflow = Workflow(
    id: "system_setting",
    description: "Switch dark or light mode, or change, mute or unmute the volume.",
    routes: appsRoutes,
    plausible: { request, _ in readSetting(request) != nil },
    run: { request, _, ctx in
        do {
            guard var plan = readSetting(request) else { return WorkflowResult(success: false, headline: "I could not tell which setting.") }
            if plan.tool == "system_volume", Rx("\\b(louder|quieter|up|down|increase|decrease|lower)\\b", "i").test(request), plan.volume != nil, !Rx("\\d").test(request) {
                // Relative changes need the current level first.
                let now = try await runOrFail(ctx, "system_volume", [:])
                plan = readSetting(request, currentVolume: now.num("volume")) ?? plan
            }
            _ = try await runOrFail(ctx, plan.tool, plan.input)
            return WorkflowResult(success: true, headline: plan.done)
        } catch {
            return try failed(error)
        }
    }
)

// MARK: - Shortcuts

private let shortcut = Rx("\\b(?:run|start|trigger|do|use)\\b.*\\bshortcut\\b|\\bshortcut\\b.*\\b(?:run|start)\\b", "i")

let shortcutWorkflow = Workflow(
    id: "run_shortcut",
    description: "Run one of the user's own shortcuts from the Shortcuts app.",
    routes: appsRoutes,
    plausible: { request, _ in shortcut.test(request) },
    run: { request, _, ctx in
        do {
            let list = try await runOrFail(ctx, "shortcuts_list", [:]).arrayValue?.compactMap(\.stringValue) ?? []
            if list.isEmpty { return WorkflowResult(success: false, headline: "You don't have any shortcuts yet.") }
            let named = list.filter { names(request, $0) }.ecmaSorted { $0.jsLength > $1.jsLength }.first
            var pick = named
            // "focus mode" → the shortcut it meant last time.
            let remembered = named != nil ? nil : suggestChoice("shortcut", request, ctx.memory.all(), allowed: list)
            if let value = remembered?.choice?.value { pick = value }
            var guessed = false
            if pick == nil {
                guessed = true
                var options = [("none", "None of these is the one the user means.")]
                options += list.prefix(60).enumerated().map { ("s\($0.offset)", $0.element) }
                let answers = await ctx.ask("pick_shortcut", ["userRequest": .string(request)], [("pick", .choice("Which shortcut does the user want to run?", options))])
                if let c = answers?["pick"]?.choice, c != "none", let index = Int(c.dropFirst()), list.indices.contains(index) { pick = list[index] }
            }
            guard let pick else {
                return WorkflowResult(success: false, headline: "I couldn't tell which shortcut. You have: \(list.prefix(8).joined(separator: ", "))\(list.count > 8 ? "…" : "").")
            }
            let out = try await runOrFail(ctx, "shortcuts_run", ["name": .string(pick)])
            let said = out.str("output").jsTrimmed
            var evidence: [Evidence] = said.isEmpty ? [] : [.text("\(pick) said", said.jsSlice(0, 1500))]
            if let remembered { evidence.append(ctx.memory.used(remembered)) }
            // A shortcut found from other words: keep the words, so next time needs no guessing.
            if guessed, ctx.memory.learn {
                let about = aboutWords(request).joined(separator: " ")
                if let m = learnedChoice("shortcut", pick, about: about, sentence: "\"\(about)\" means your \(pick) shortcut"), ctx.memory.keep(m) != nil {
                    evidence.append(.text("Remembered", m.text))
                }
            }
            return WorkflowResult(success: true, headline: "Ran \"\(pick)\".", evidence: evidence)
        } catch {
            return try failed(error)
        }
    }
)

// MARK: - Notes

private let note = Rx("^\\s*(?:note:|(?:make|take|write|add|jot)(?: down)? (?:a )?note\\b|jot down\\b|save (?:this|that|it) (?:to|in|as a) notes?\\b)", "i")

func noteFromWords(_ request: String) -> (title: String, body: String)? {
    if Rx("^\\s*save (?:this|that|it)\\b", "i").test(request) { return nil }
    let text = Rx("^\\s*(?:note:|(?:make|take|write|add|jot)(?: down)? (?:a )?note(?: that| saying| about|:)?|jot down)\\s*", "i").replaceFirst(request, "").jsTrimmed
    if text.isEmpty || Rx("^(?:this|that|it)$", "i").test(text) { return nil }
    let firstLine = (Rx("\\n|(?<=[.!?])\\s").split(text).first ?? "").jsTrimmed
    let title = (firstLine.jsLength > 60 ? "\(firstLine.jsSlice(0, 57).trimmingTrailingSpace)…" : firstLine).capitalizedFirst
    return (title, text == firstLine ? "" : text)
}

let noteWorkflow = Workflow(
    id: "make_note",
    description: "Write a note in the Notes app from what the user said, or from what they have selected or open.",
    routes: appsRoutes,
    plausible: { request, _ in note.test(request) },
    run: { request, _, ctx in
        do {
            var made = noteFromWords(request)
            if made == nil {
                // "Save this to notes": this is whatever they had selected, or the page they had open.
                let seen = ScreenContext(json: try await runOrFail(ctx, "context_now", ["selection": true, "tab": true]))
                let picked = [seen.selectedText?.jsTrimmed, seen.page?.optStr("selection")?.jsTrimmed].compactMap { $0 }.first { !$0.isEmpty }
                if let text = picked {
                    let first = (text.jsSplit("\n").first ?? "").jsTrimmed
                    made = (first.jsLength > 60 ? "\(first.jsSlice(0, 57).trimmingTrailingSpace)…" : first, text == first ? "" : text)
                } else if let url = seen.tabURL {
                    let title = seen.tabTitle ?? ""
                    made = (title.isEmpty ? url : title, url)
                    if let why = seen.pageNote { ctx.log(.info, "saved the link only: \(why)") }
                } else {
                    return WorkflowResult(success: false, headline: "Select some text or open a page first, then ask again.")
                }
            }
            guard let note = made else { return WorkflowResult(success: false, headline: "Select some text or open a page first, then ask again.") }
            let saved = try await runOrFail(ctx, "notes_create", ["title": .string(note.title), "body": .string(note.body)])
            return WorkflowResult(success: true, headline: "Saved to Notes: \"\(note.title)\".", evidence: [.text("Notes · \(saved.str("folder"))", note.title)])
        } catch {
            return try failed(error)
        }
    }
)

let assistWorkflows: [Workflow] = [reminderWorkflow, eventWorkflow, freeSlotWorkflow, agendaWorkflow, settingWorkflow, shortcutWorkflow, noteWorkflow]

extension String {
    /// `string.trimEnd()`.
    var trimmingTrailingSpace: String { Rx("\\s+$").replaceFirst(self, "") }
}
