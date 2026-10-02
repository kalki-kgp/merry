import Testing
@testable import MerryCore

@Test func documentVocabularyMatchesTheOriginal() {
    for row in Fixture.load("search-language").list("texts") {
        let text = row.str("text")
        #expect(documentTerms(text) == row.strings("terms"), "terms: \(text)")
        #expect(hasLocalSearchIntent(text) == row.flag("intent"), "intent: \(text)")
        #expect(removeDocumentWords(text) == row.str("removed"), "removed: \(text)")
    }
}

@Test func scriptErrorsAreExplainedTheSameWay() {
    for row in Fixture.load("search-language").list("errors") {
        #expect(explainScriptError(row.str("stderr"), app: row.optStr("app")) == row.str("said"), "\(row.str("stderr"))")
    }
}

@Test func onlyWebLinksOpen() {
    for row in Fixture.load("search-language").list("urls") {
        let url = row.str("url")
        if let href = row.optStr("href") {
            #expect((try? externalWebUrl(url)) == href, "\(url)")
        } else {
            #expect((try? externalWebUrl(url)) == nil, "\(url) should be refused")
        }
    }
}
