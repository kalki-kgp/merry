import SwiftUI
import MerryCore

// The small slice of Markdown models actually write in a chat answer:
// paragraphs, bullet and numbered lists, headings, quotes, fenced code, and
// inline bold, italic, code and links.
//
// It builds views from parsed runs rather than handing text to a renderer, so
// model text can never inject markup, and links open through the bridge's
// validated URL handler only.

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    case quote(String)
    case code(String)
    case bullets([String])
    case numbered([String], start: Int)
}

public indirect enum MarkdownRun: Equatable, Sendable {
    case text(String)
    case code(String)
    case strong([MarkdownRun])
    case emphasis([MarkdownRun])
    case link(label: String, href: String)
}

public enum Markdown {
    // Emoji read as noise in a calm interface. A line that opens with one is
    // being used as a list item, so it becomes one; anywhere else they are
    // simply dropped.
    private static let emoji = Rx("(?:\\p{Extended_Pictographic}|\\p{Regional_Indicator})(?:\\x{FE0F}|\\x{200D}(?:\\p{Extended_Pictographic}))*\\x{FE0F}?")
    private static let emojiLead = Rx("^\\s*(?:\\p{Extended_Pictographic}|\\p{Regional_Indicator})[\\x{FE0F}\\x{200D}\\p{Extended_Pictographic}]*\\s+")

    public static func stripEmoji(_ line: String) -> String {
        var line = line
        if emojiLead.test(line) { line = emojiLead.replaceFirst(line, "- ") }
        return Rx(" {2,}").replaceAll(emoji.replaceAll(line, ""), " ")
    }

    private static let bullet = Rx("^\\s*[-*•]\\s+(.*)$")
    private static let number = Rx("^\\s*(\\d+)[.)]\\s+(.*)$")
    private static let heading = Rx("^\\s*#{1,6}\\s+(.*)$")
    private static let quote = Rx("^\\s*>\\s?(.*)$")
    private static let fence = Rx("^\\s*```")

    public static func parseBlocks(_ source: String) -> [MarkdownBlock] {
        let lines = Rx("\\r\\n?").replaceAll(source, "\n").jsSplit("\n").map(stripEmoji)
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))) }
            para = []
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            defer { i += 1 }
            if fence.test(line) {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !fence.test(lines[i]) { code.append(lines[i]); i += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if line.jsTrimmed.isEmpty { flush(); continue }
            if let m = heading.exec(line) { flush(); blocks.append(.heading(m[1] ?? "")); continue }
            if let m = quote.exec(line) { flush(); blocks.append(.quote(m[1] ?? "")); continue }
            let b = bullet.exec(line)
            let n = number.exec(line)
            if b != nil || n != nil {
                flush()
                let item = (b != nil ? b![1] : n![2]) ?? ""
                switch (blocks.last, b != nil) {
                case (.bullets(let items)?, true): blocks[blocks.count - 1] = .bullets(items + [item])
                case (.numbered(let items, let start)?, false): blocks[blocks.count - 1] = .numbered(items + [item], start: start)
                case (_, true): blocks.append(.bullets([item]))
                case (_, false): blocks.append(.numbered([item], start: Int(n![1] ?? "1") ?? 1))
                }
                continue
            }
            // A wrapped continuation of the previous list item.
            if para.isEmpty, Rx("^\\s{2,}").test(line) {
                if case .bullets(var items)? = blocks.last {
                    items[items.count - 1] += " \(line.jsTrimmed)"
                    blocks[blocks.count - 1] = .bullets(items)
                    continue
                }
                if case .numbered(var items, let start)? = blocks.last {
                    items[items.count - 1] += " \(line.jsTrimmed)"
                    blocks[blocks.count - 1] = .numbered(items, start: start)
                    continue
                }
            }
            para.append(line.jsTrimmed)
        }
        flush()
        return blocks
    }

    private static let inlinePattern = Rx("(`[^`]+`)|(\\*\\*[^*]+\\*\\*|__[^_]+__)|(\\*[^*\\s][^*]*\\*|_[^_\\s][^_]*_)|(\\[[^\\]]+\\]\\((https?://[^)\\s]+)\\))|(https?://[^\\s)]+[^\\s).,;:!?])")

    public static func inline(_ text: String) -> [MarkdownRun] {
        var out: [MarkdownRun] = []
        var last = 0
        for m in inlinePattern.all(text) {
            if m.index > last { out.append(.text(text.jsSlice(last, m.index))) }
            if let code = m[1] { out.append(.code(code.jsSlice(1, -1))) }
            else if let strong = m[2] { out.append(.strong(inline(strong.jsSlice(2, -2)))) }
            else if let em = m[3] { out.append(.emphasis(inline(em.jsSlice(1, -1)))) }
            else if let link = m[4] { out.append(.link(label: link.jsSlice(1, link.jsIndexOf("]")), href: m[5] ?? "")) }
            else if let bare = m[6] { out.append(.link(label: Rx("^https?://").replaceFirst(bare, ""), href: bare)) }
            last = m.end
        }
        if last < text.jsLength { out.append(.text(text.jsSlice(last))) }
        return out
    }

    /// "**Files**: find and sort things": a label and what it means.
    private static let term = Rx("^\\*\\*([^*]{1,40})\\*\\*\\s*(?:[\\x{2014}–:-]\\s*)?(.+)$")

    public static func termParts(_ item: String) -> (term: String, definition: String)? {
        guard let m = term.exec(item), let t = m[1], let d = m[2] else { return nil }
        return (t, d)
    }

    /// The same text with the formatting marks removed, for one-line places like the pet's bubble.
    public static func plainText(_ md: String) -> String {
        var text = md.jsSplit("\n").map(stripEmoji).joined(separator: "\n")
        text = Rx("```[\\s\\S]*?```").replaceAll(text, " ")
        text = Rx("\\[([^\\]]+)\\]\\([^)]+\\)").replaceAll(text, "$1")
        text = Rx("(\\*\\*|__|`)").replaceAll(text, "")
        text = Rx("(^|\\s)[*_]([^*_\\s][^*_]*)[*_]").replaceAll(text, "$1$2")
        text = Rx("^\\s*(?:[-*•]|\\d+[.)]|#{1,6}|>)\\s+", "m").replaceAll(text, "")
        text = Rx("\\s*\\n+\\s*").replaceAll(text, " ")
        return text.jsTrimmed
    }
}

/// Renders a model's answer.
public struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// A one-line answer reads better a little larger.
    var short: Bool
    var onOpenURL: (String) -> Void

    public init(_ text: String, short: Bool = false, onOpenURL: @escaping (String) -> Void = { _ in }) {
        blocks = Markdown.parseBlocks(text)
        self.short = short
        self.onOpenURL = onOpenURL
    }

    private var bodyFont: Font { .system(size: short ? 15 : 13.5) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    runs(text).font(bodyFont).lineSpacing(3)
                case .heading(let text):
                    runs(text).font(.system(size: 14, weight: .semibold)).padding(.top, 2)
                case .quote(let text):
                    runs(text).font(bodyFont).foregroundStyle(Chrome.secondaryText)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Chrome.overlay(0.18)).frame(width: 2) }
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: text).font(Chrome.mono(12, weight: .regular)).textSelection(.enabled).padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.06)))
                case .bullets(let items):
                    list(items) { _ in Text(verbatim: "•").foregroundStyle(Chrome.secondaryText) }
                case .numbered(let items, let start):
                    list(items) { index in Text(verbatim: "\(start + index).").font(Chrome.mono(12)).foregroundStyle(Chrome.secondaryText) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in onOpenURL(url.absoluteString); return .handled })
    }

    private func list(_ items: [String], marker: @escaping (Int) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index).frame(minWidth: 14, alignment: .trailing)
                    if let parts = Markdown.termParts(item) {
                        var term = attributed(Markdown.inline(parts.term), [.stronglyEmphasized])
                        let definition: AttributedString = {
                            var d = attributed(Markdown.inline(parts.definition), [])
                            d.foregroundColor = Chrome.secondaryText
                            return d
                        }()
                        let _ = term.append(AttributedString("  ") + definition)
                        Text(term).font(bodyFont).lineSpacing(3)
                    } else {
                        runs(item).font(bodyFont).lineSpacing(3)
                    }
                }
            }
        }
    }

    private func runs(_ text: String) -> Text { Text(attributed(Markdown.inline(text), [])) }

    /// Inline runs as attributed text. Bold, italic and code are presentation
    /// intents, so they nest and take the surrounding font.
    private func attributed(_ runs: [MarkdownRun], _ intent: InlinePresentationIntent) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            switch run {
            case .text(let s):
                var piece = AttributedString(s)
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                out.append(piece)
            case .code(let s):
                var piece = AttributedString(s)
                piece.inlinePresentationIntent = intent.union(.code)
                out.append(piece)
            case .strong(let inner): out.append(attributed(inner, intent.union(.stronglyEmphasized)))
            case .emphasis(let inner): out.append(attributed(inner, intent.union(.emphasized)))
            case .link(let label, let href):
                var piece = AttributedString(label)
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                piece.link = URL(string: href)
                piece.underlineStyle = .single
                out.append(piece)
            }
        }
        return out
    }
}
