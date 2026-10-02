import Testing
import MerryCore
@testable import MerryUI

/// The markup React's static renderer produces for the reference component,
/// rebuilt from the Swift parser's output so the two can be compared.
private func html(_ source: String) -> String {
    func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#x27;")
    }
    func runs(_ list: [MarkdownRun]) -> String {
        list.map { run in
            switch run {
            case .text(let s): return escape(s)
            case .code(let s): return "<code>\(escape(s))</code>"
            case .strong(let inner): return "<strong>\(runs(inner))</strong>"
            case .emphasis(let inner): return "<em>\(runs(inner))</em>"
            case .link(let label, let href): return "<button class=\"md-link\" title=\"\(escape(href))\">\(escape(label))</button>"
            }
        }.joined()
    }
    func inline(_ s: String) -> String { runs(Markdown.inline(s)) }
    var out = "<div class=\"md \">"
    for (i, block) in Markdown.parseBlocks(source).enumerated() {
        let style = "style=\"--i:\(i)\""
        switch block {
        case .paragraph(let t): out += "<p \(style)>\(inline(t))</p>"
        case .heading(let t): out += "<h3 \(style)>\(inline(t))</h3>"
        case .quote(let t): out += "<blockquote \(style)>\(inline(t))</blockquote>"
        case .code(let t): out += "<pre \(style)><code>\(escape(t))</code></pre>"
        case .bullets(let items):
            let terms = items.allSatisfy { Markdown.termParts($0) != nil }
            out += "<ul \(style) class=\"\(terms ? "md-terms" : "")\">"
            for item in items {
                if let parts = Markdown.termParts(item) {
                    out += "<li class=\"md-term-item\"><span class=\"md-term\">\(inline(parts.term))</span><span class=\"md-def\">\(inline(parts.definition))</span></li>"
                } else {
                    out += "<li>\(inline(item))</li>"
                }
            }
            out += "</ul>"
        case .numbered(let items, let start):
            out += "<ol start=\"\(start)\" \(style)>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
        }
    }
    return out + "</div>"
}

@Test func markdownMatchesTheOriginalRenderer() {
    for row in Fixture.load("markdown").arrayValue ?? [] {
        let source = row.str("source")
        #expect(html(source) == row.str("html"), "\(source.debugDescription)")
        #expect(Markdown.plainText(source) == row.str("plain"), "plain: \(source.debugDescription)")
        #expect(source.jsSplit("\n").map(Markdown.stripEmoji) == row.strings("stripped"), "emoji: \(source.debugDescription)")
    }
}
