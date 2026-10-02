import Testing
@testable import MerryCore

@Test func requestsAreUnderstoodLocallyLikeTheOriginal() async {
    let off = Jev(apiKey: nil, enabled: false)
    let rows = Fixture.load("jev-local").list("understood")
    for row in rows {
        let request = row.str("request")
        let read = await understand(request, off, hasDroppedPaths: row.flag("dropped"))
        let difference = read.parityJSON.firstDifference(from: row["read"]!)
        #expect(difference == nil, "understand \(request.debugDescription) dropped \(row.flag("dropped")): \(difference ?? "")")
        #expect(routeFor(read).parityJSON == row["route"], "routeFor \(request.debugDescription)")
    }
    #expect(rows.count > 200)
}

@Test func requestsAreRoutedLocallyLikeTheOriginal() async {
    let fixture = Fixture.load("jev-local")
    let off = Jev(apiKey: nil, enabled: false)
    #expect(off.available == fixture.flag("available"))
    for row in fixture.list("routed") {
        let decision = await off.routeRequest(row.str("request"), hasDroppedPaths: row.flag("dropped"))
        let difference = decision.parityJSON.firstDifference(from: row["decision"]!)
        #expect(difference == nil, "route \(row.str("request").debugDescription) dropped \(row.flag("dropped")): \(difference ?? "")")
    }
    let difference = off.metrics.json.firstDifference(from: fixture["routeMetrics"]!)
    #expect(difference == nil, "metrics: \(difference ?? "")")
}

@Test func planSetupFromKeywordsMatchesTheOriginal() async {
    let fixture = Fixture.load("jev-local")
    let rows = fixture.list("setups")
    for row in rows {
        let setup = localPlanSetup(row.str("request"), route: row.str("route"), hasDroppedPaths: row.flag("dropped"))
        let difference = setup.parityJSON.firstDifference(from: row["setup"]!)
        #expect(difference == nil, "\(row.str("request").debugDescription) \(row.str("route")) dropped \(row.flag("dropped")): \(difference ?? "")")
    }
    #expect(rows.count > 500)
    let off = Jev(apiKey: nil, enabled: false)
    for row in fixture.list("planned") {
        let setup = await off.planSetup(row.str("request"), route: "unclear", hasDroppedPaths: false)
        #expect(setup.parityJSON.firstDifference(from: row["setup"]!) == nil, "\(row.str("request").debugDescription)")
    }
    // The outcome of each record is the one-line description of the setup.
    let difference = off.metrics.json.firstDifference(from: fixture["plannedMetrics"]!)
    #expect(difference == nil, "metrics: \(difference ?? "")")
}

@Test func progressIsJudgedLocallyLikeTheOriginal() async {
    let fixture = Fixture.load("jev-local")
    let off = Jev(apiKey: nil, enabled: false)
    for row in fixture.list("progress") {
        let task = parityTask(max: row.int("max"), actions: row.list("actions"))
        #expect(off.assessProgressLocally(task).parityJSON == row["local"], "\(row.str("name")): \(off.assessProgressLocally(task))")
        #expect(await off.assessProgress(task).parityJSON == row["verdict"], "\(row.str("name"))")
    }
    #expect(off.metrics.json.firstDifference(from: fixture["progressMetrics"]!) == nil)
}

@Test func aSwitchedOffJevAnswersNothing() async {
    let fixture = Fixture.load("jev-local")
    let off = Jev(apiKey: "key", enabled: false)
    #expect(!off.available)
    #expect(await off.ask("x", state: ["a": 1], questions: []) == nil && fixture["askOff"] == .null)
    #expect(await off.ask("x", state: ["a": 1], questions: [("q", .noul("Yes?"))]) == nil)
    #expect(await off.shouldCloseBrowser("find flights") == fixture.flag("closeOff"))
    #expect(await off.assignFilesToGroups([JevFile(name: "a.pdf", ext: ".pdf", modifiedAt: 0)], [JevGroup(name: "Docs", description: "Documents")]) == nil && fixture["assignOff"] == .null)
    #expect(off.metrics.calls.isEmpty)
}

@Test func readingsMapOntoFiltersLikeTheOriginal() {
    let fixture = Fixture.load("jev-local")
    for row in fixture.list("kinds") { #expect(extensionsFor(Understanding.Kind(rawValue: row.str("kind"))!) == row.strings("extensions")) }
    for row in fixture.list("sizes") { #expect(bytesFor(Understanding.Size(rawValue: row.str("size"))!) == row.optInt("bytes")) }
    for row in fixture.list("whens") { #expect(sinceFor(Understanding.When(rawValue: row.str("when"))!) == row.optNum("since")) }
    for row in fixture.list("places") { #expect(folderFor(Understanding.Place(rawValue: row.str("place"))!) == row.optStr("folder")) }
    for row in fixture.list("readings") { #expect(routeFor(Understanding(parity: row["read"]!)).parityJSON == row["route"]) }
    #expect(fallbackUnderstanding().parityJSON == fixture["neutral"])
    #expect(Understanding.Kind.allCases.count == fixture.list("kinds").count && Understanding.Place.allCases.count == fixture.list("places").count)
}

@Test func jevIsSummarisedLikeTheOriginal() {
    for row in Fixture.load("jev-local").list("summaries") {
        #expect(summarizeJev(JevMetrics(parity: row["metrics"]!)) == row.str("text"))
    }
}
