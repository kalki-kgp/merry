import Testing
@testable import MerryCore

private func entry(_ name: String, _ index: Int) -> FileEntry {
    let ext = name.contains(".") ? String(name[name.lastIndex(of: ".")!...]) : ""
    let modified = JSDate(iso: "2026-\(String(7 + index % 4).jsPadStart(2, "0"))-\(String(3 + index).jsPadStart(2, "0"))T00:00:00.000Z")!.time
    return FileEntry(path: "/x/\(name)", name: name, kind: "file", size: 10, modifiedAt: modified, createdAt: modified, ext: ext)
}

@Suite(.serialized) struct WorkflowParityTests {
    let fixture = Fixture.load("workflows")

    init() { LocalTime.use(timeZone: "Asia/Kolkata") }

    @Test func workflowsAreTheSameJobsInTheSameOrder() {
        let expected = fixture.list("ids")
        #expect(WORKFLOWS.map(\.id) == expected.map { $0.str("id") })
        for (workflow, row) in zip(WORKFLOWS, expected) {
            #expect(workflow.description == row.str("description"), "\(workflow.id)")
            #expect(workflow.routes == row.strings("routes"), "\(workflow.id)")
        }
    }

    @Test func sentencesAreReadTheSameWay() {
        let now = JSDate(fixture.num("now"))
        for row in fixture.list("requests") {
            let request = row.str("request")
            #expect(WORKFLOWS.filter { $0.plausible(request, []) }.map(\.id) == row.strings("plausible"), "plausible: \(request)")
            #expect(WORKFLOWS.filter { $0.plausible(request, ["/x/a"]) }.map(\.id) == row.strings("plausibleDropped"), "plausible with a drop: \(request)")
            #expect(isBrainRequest(request) == row.flag("brain"), "workspace: \(request)")
            let reading = readTime(request, now: now)
            #expect(reminderTitle(request, reading) == row.str("reminderTitle"), "reminder title: \(request)")
            #expect(eventTitle(request, reading) == row.str("eventTitle"), "event title: \(request)")

            let range = agendaRange(request, now: now)
            let agenda = row["agenda"]!
            #expect(range.from.time == agenda.num("from") && range.to.time == agenda.num("to") && range.label == agenda.str("label") && range.probe?.time == agenda["probe"]?.doubleValue, "agenda: \(request)")

            let q = freeSlotQuery(request, now: now)
            let free = row["free"]!
            #expect(q.day.time == free.num("day") && q.windowStart.time == free.num("start") && q.windowEnd.time == free.num("end") && q.minutes == free.num("minutes"), "free slot: \(request)")

            for (key, volume) in [("setting", nil as Double?), ("settingAt20", 20)] {
                let plan = readSetting(request, currentVolume: volume)
                if let expected = row[key], !expected.isNull {
                    #expect(plan?.tool == expected.str("tool") && plan?.done == expected.str("done") && plan?.input == expected["input"], "\(key): \(request)")
                } else {
                    #expect(plan == nil, "\(key): \(request)")
                }
            }
            let note = noteFromWords(request)
            if let expected = row["note"], !expected.isNull {
                #expect(note?.title == expected.str("title") && note?.body == expected.str("body"), "note: \(request)")
            } else {
                #expect(note == nil, "note: \(request)")
            }
            #expect(splitArgs(request) == row.strings("args"), "args: \(request)")
            #expect(aboutWords(request) == row.strings("about"), "about: \(request)")
        }
    }

    @Test func freeTimeIsFoundAroundTheSameEvents() {
        let now = JSDate(fixture.num("now"))
        for row in fixture.list("gaps") {
            let gaps = freeGaps(freeSlotQuery(row.str("request"), now: now), row.list("busy"))
            #expect(JSON.array(gaps.map { [.number($0.start.time), .number($0.end.time)] }) == row["gaps"], "\(row.str("request")) with \(row.list("busy").count) events")
        }
    }

    @Test func foldersAndNamesAreDerivedTheSameWay() {
        for row in fixture.list("groups") {
            let files = row.strings("names").enumerated().map { entry($0.element, $0.offset) }
            #expect(candidateProjectGroups(files) == row.strings("projects"), "projects: \(row.strings("names"))")
            #expect(candidateDateGroups(files) == row.strings("months"), "months: \(row.strings("names"))")
            #expect(files.map { typeGroupFor($0.ext) } == row.list("types").map(\.stringValue), "types: \(row.strings("names"))")
        }
        let stems = fixture.strings("stems")
        let file = entry("a.txt", 0)
        #expect(NAMING_SCHEMES.map(\.id) == fixture.list("schemes").map { $0.str("id") })
        for (scheme, row) in zip(NAMING_SCHEMES, fixture.list("schemes")) {
            #expect(scheme.description == row.str("description"))
            #expect(stems.enumerated().map { scheme.apply($0.element, $0.offset, file) } == row.strings("names"), "\(scheme.id)")
        }
    }
}
