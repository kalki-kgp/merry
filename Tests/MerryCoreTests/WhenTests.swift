import Testing
@testable import MerryCore

private func json(_ reading: TimeReading?) -> JSON {
    guard let r = reading else { return .null }
    return JSON.obj([
        "candidates": .array(r.candidates.map { $0.time.isNaN ? .null : .number($0.time) }),
        "dateOnly": .bool(r.dateOnly),
        "matched": JSON(r.matched),
        "durationMin": r.durationMin.map(JSON.number)
    ])
}

@Test func timesAreReadLikeTheOriginal() {
    LocalTime.use(timeZone: "Asia/Kolkata")
    var rows = 0
    for clock in Fixture.load("when").list("clocks") {
        let now = JSDate(clock.num("now"))
        for row in clock.list("rows") {
            rows += 1
            let text = row.str("text")
            let reading = readTime(text, now: now)
            let difference = json(reading).firstDifference(from: row["reading"] ?? .null)
            #expect(difference == nil, "readTime \(text.debugDescription) at \(now.time): \(difference ?? "")")
            #expect(stripTime(text, reading) == row.str("stripped"), "stripTime \(text.debugDescription)")
            let described = (reading?.candidates ?? []).filter { !$0.time.isNaN }.map {
                JSON([describeTime($0, dateOnly: false, now: now), describeTime($0, dateOnly: true, now: now)])
            }
            #expect(JSON.array(described) == row["described"], "describeTime \(text.debugDescription): \(JSON.array(described))")
        }
    }
    #expect(rows > 500)
}

@Test func spelledDurationsMatchTheOriginal() {
    for row in Fixture.load("when").list("spelled") {
        #expect(spelledDurations(row.str("text")) == row.str("out"), "\(row.str("text").debugDescription)")
    }
}

@Test func timePhrasesAreStrippedLikeTheOriginal() {
    LocalTime.use(timeZone: "Asia/Kolkata")
    let fixture = Fixture.load("when")
    let now = JSDate(fixture.list("clocks")[0].num("now"))
    for row in fixture.list("titles") {
        let reading = row.optStr("phrase").flatMap { readTime($0, now: now) }
        #expect(stripTime(row.str("text"), reading) == row.str("stripped"), "\(row.str("text").debugDescription) minus \(row.optStr("phrase") ?? "nothing")")
    }
}

@Test func timesAreDescribedLikeTheOriginal() {
    LocalTime.use(timeZone: "Asia/Kolkata")
    let fixture = Fixture.load("when")
    let now = JSDate(fixture.list("clocks")[0].num("now"))
    for row in fixture.list("describe") {
        let d = JSDate(row.num("at"))
        #expect(describeTime(d, dateOnly: false, now: now) == row.str("text"))
        #expect(describeTime(d, dateOnly: true, now: now) == row.str("day"))
    }
}
