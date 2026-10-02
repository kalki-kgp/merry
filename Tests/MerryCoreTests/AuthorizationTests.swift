import Testing
@testable import MerryCore

@Test func pathRulesMatchTheOriginal() {
    let fixture = Fixture.load("js-cases")
    Path.homeOverride = fixture.str("home")
    defer { Path.homeOverride = nil }
    for row in fixture.list("tilde") { #expect(normalizePath(row.str("p")) == row.str("normalized"), "normalizePath \(row.str("p"))") }
    for row in fixture.list("within") { #expect(isWithin(row.str("parent"), row.str("child")) == row.flag("within"), "isWithin \(row.str("parent")) \(row.str("child"))") }
    for row in fixture.list("forbidden") { #expect(isForbidden(row.str("p")) == row.flag("forbidden"), "isForbidden \(row.str("p"))") }
}

@Test func scopesAreCheckedAgainstTheGrant() {
    let auth = Authorization(readRoots: ["/tmp/merry-a"], writeRoots: ["/tmp/merry-w"], apps: ["Notes"], origins: ["https://example.com"], capabilities: ["files.read"])
    #expect(checkScopes(auth, [.read(path: "/tmp/merry-a/x.txt")]).allowed)
    // A write root implies read on the same tree; a read root does not imply write.
    #expect(checkScopes(auth, [.read(path: "/tmp/merry-w/x.txt")]).allowed)
    #expect(checkScopes(auth, [.write(path: "/tmp/merry-a/x.txt")]).missing == [.write(path: "/tmp/merry-a/x.txt")])
    // Siblings sharing a prefix are not nested.
    #expect(!checkScopes(auth, [.read(path: "/tmp/merry-ab/x")]).allowed)
    #expect(checkScopes(auth, [.app(name: "notes")]).allowed)
    #expect(checkScopes(auth, [.origin(url: "https://example.com/a/b?c")]).allowed)
    #expect(checkScopes(auth, [.origin(url: "https://example.com.evil.io/")]).missing == [.origin(url: "https://example.com.evil.io")])
    #expect(checkScopes(auth, [.origin(url: "not a url")]).refused != nil)
    // Protected locations are refused outright, never offered as something to grant.
    let refused = checkScopes(auth, [.write(path: "/System/Library/x")])
    #expect(refused.refused != nil && refused.missing.isEmpty)
    // Granting what is missing makes the identical check pass.
    let missing = checkScopes(auth, [.write(path: "/tmp/merry-new/file.txt"), .capability(name: "browser.upload")]).missing
    let widened = extendAuthorization(auth, grantFor(missing))
    #expect(checkScopes(widened, [.write(path: "/tmp/merry-new/file.txt"), .capability(name: "browser.upload")]).allowed)
}
