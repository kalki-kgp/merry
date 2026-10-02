import Testing
@testable import MerryCore

@Test func numbersPrintLikeJavaScript() throws {
    for row in Fixture.load("js-cases").list("numbers") {
        #expect(try JSON.parse(row.str("source")).stringify() == row.str("text"), "\(row.str("source"))")
    }
}

@Test func stringifyMatchesJavaScript() throws {
    for row in Fixture.load("js-cases").list("values") {
        let value = try JSON.parse(row.str("source"))
        #expect(value.stringify() == row.str("compact"))
        #expect(value.stringify(indent: 1) == row.str("pretty"))
    }
}

@Test func pathsMatchNode() {
    let fixture = Fixture.load("js-cases")
    for row in fixture.list("paths") {
        let p = row.str("p")
        #expect(Path.normalize(p) == row.str("normalize"), "normalize \(p)")
        #expect(Path.dirname(p) == row.str("dirname"), "dirname \(p)")
        #expect(Path.basename(p) == row.str("basename"), "basename \(p)")
        #expect(Path.extname(p) == row.str("extname"), "extname \(p)")
        #expect(Path.basename(p, Path.extname(p)) == row.str("stem"), "stem \(p)")
        #expect(Path.isAbsolute(p) == row.flag("absolute"), "absolute \(p)")
    }
    for row in fixture.list("joins") { #expect(Path.join(row.strings("parts")) == row.str("joined"), "join \(row.strings("parts"))") }
    for row in fixture.list("resolves") { #expect(Path.resolve(row.strings("parts")) == row.str("resolved"), "resolve \(row.strings("parts"))") }
    for row in fixture.list("relatives") { #expect(Path.relative(row.str("from"), row.str("to")) == row.str("relative")) }
}
