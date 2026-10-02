import Testing
@testable import MerryCore

@Test func memoryWordsAndTopicsMatchTheOriginal() {
    let rows = Fixture.load("memory").list("texts")
    for row in rows {
        let text = row.str("text")
        #expect(words(text) == row.strings("words"), "words \(text.debugDescription)")
        #expect(topics(text) == row.strings("topics"), "topics \(text.debugDescription)")
    }
    #expect(rows.count > 100)
}

@Test func secretsAreRefusedLikeTheOriginal() {
    for row in Fixture.load("memory").list("secrets") {
        #expect(looksSecret(row.str("text")) == row.optStr("secret"), "\(row.str("text").debugDescription)")
    }
}

@Test func explicitMemoriesAreReadLikeTheOriginal() {
    for row in Fixture.load("memory").list("explicit") {
        let request = row.str("request")
        let told = explicitMemory(request)
        let got: JSON = told.map { ["text": .string($0.text), "kind": .string($0.kind)] } ?? .null
        #expect(got == row["memory"], "\(request.debugDescription) gave \(got)")
    }
}

@Test func memoriesAreMadeLikeTheOriginal() {
    let fixture = Fixture.load("memory")
    let now = fixture.num("now")
    for row in fixture.list("made") {
        let choice = row["extra"]?["choice"].map { Memory.Choice(decision: $0.str("decision"), value: $0.str("value")) }
        let made = makeMemory(row.str("text"), kind: row.str("kind"), source: row.str("source"), keys: row["extra"]?.optStrings("keys"), choice: choice, id: "id", now: now)
        let difference = JSON.encode(made).firstDifference(from: row["memory"]!)
        #expect(difference == nil, "\(row.str("text").debugDescription): \(difference ?? "")")
    }
    for row in fixture.list("learned") {
        let made = learnedChoice(row.str("decision"), row.str("value"), about: row.str("about"), sentence: row.str("sentence"), id: "id", now: now)
        let got = made.map { JSON.encode($0) } ?? .null
        let difference = got.firstDifference(from: row["memory"] ?? .null)
        #expect(difference == nil, "\(row.str("about").debugDescription): \(difference ?? "")")
    }
    // Without an injected id or time, a memory still gets both.
    let fresh = makeMemory("x marks the spot", kind: "fact", source: "told")
    #expect(fresh.id.count == 36 && fresh.createdAt > now && fresh.updatedAt == fresh.createdAt)
}

@Test func memoriesMergeLikeTheOriginal() {
    let fixture = Fixture.load("memory")
    for row in fixture.list("merges") {
        let incoming = try! row["incoming"]!.decode(Memory.self)
        let merged = mergeMemory(parityMemories(row.list("existing")), incoming, now: fixture.num("now"))
        let got: JSON = ["memory": JSON.encode(merged.memory), "replaces": JSON(merged.replaces)]
        let difference = got.firstDifference(from: row["merged"]!)
        #expect(difference == nil, "\(incoming.text): \(difference ?? "")")
    }
}

@Test func recallWithoutJevMatchesTheOriginal() async {
    let fixture = Fixture.load("memory")
    let known = parityMemories(fixture.list("known"))
    for row in fixture.list("scores") {
        #expect(known.map { lexicalScore(row.str("request"), $0) } == row.list("scores").map { $0.intValue ?? -1 }, "\(row.str("request"))")
    }
    let off = Jev(apiKey: nil, enabled: false)
    for row in fixture.list("recalls") {
        for jev in [nil, off] {
            let recalled = await recall(row.str("request"), known, jev, limit: row.int("limit"))
            let difference = JSON.array(recalled.map(\.parityJSON)).firstDifference(from: row["recalled"]!)
            #expect(difference == nil, "\(row.str("request")) limit \(row.int("limit")): \(difference ?? "")")
        }
    }
    #expect(await recall("anything", [], nil).isEmpty)
    #expect(off.metrics.calls.isEmpty)
}

@Test func learnedChoicesAreSuggestedLikeTheOriginal() {
    let fixture = Fixture.load("memory")
    let known = parityMemories(fixture.list("known"))
    for row in fixture.list("suggestions") {
        let suggested = suggestChoice(row.str("decision"), row.str("text"), known, allowed: row.optStrings("allowed"))
        let got = suggested.map { JSON.encode($0) } ?? .null
        #expect(got.firstDifference(from: row["memory"] ?? .null) == nil, "\(row.str("decision")) for \(row.str("text").debugDescription): \(suggested?.id ?? "none")")
    }
}

@Test func theMemoryNoteMatchesTheOriginal() {
    for row in Fixture.load("memory").list("notes") {
        let recalled = row.list("recalled").map { Recalled(memory: try! $0["memory"]!.decode(Memory.self), why: $0.str("why")) }
        #expect(memoryNote(recalled) == row.optStr("note"))
    }
}
