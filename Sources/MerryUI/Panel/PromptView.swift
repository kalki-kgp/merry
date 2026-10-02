import AppKit
import SwiftUI
import MerryCore

/// Renderer-side path helpers.
enum PanelPaths {
    static func basename(_ p: String) -> String {
        p.jsSplit("/").last { !$0.isEmpty } ?? p
    }

    static func dirname(_ p: String) -> String {
        guard let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[..<slash])
    }

    static func shortenPath(_ p: String, home: String? = nil) -> String {
        var withHome = p
        if let home, !home.isEmpty, p.hasPrefix(home) { withHome = "~" + p.dropFirst(home.count) }
        let parts = withHome.jsSplit("/")
        if parts.count <= 4 { return withHome }
        return "\(parts.prefix(2).joined(separator: "/"))/…/\(parts.suffix(2).joined(separator: "/"))"
    }
}

/// A persistent composer: preserve drafts on failure and support answers as well as new tasks.
struct PromptView: View {
    /// The launcher in the bar starts chats; the reply box under a chat continues it.
    enum Variant { case launcher, reply }

    static let maxLength = 4000
    static let paletteRow: CGFloat = 31

    var variant: Variant = .launcher
    var placeholder: String
    /// A task is running: plain requests wait, commands still go through.
    var busy: Bool
    var canAnswer = false
    var seed: PanelModel.Seed?
    var dropped: [String]
    var front: FrontWindow?
    var focusTick = 0
    var onClearDropped: () -> Void
    var onAttach: () -> Void
    var onSend: (String, Bool) async throws -> Void
    var onCommand: (String) -> Void
    /// Returns true when the digit was consumed (e.g. picking an answer).
    var onNumber: (Int) -> Bool = { _ in false }
    var onEscape: () -> Void
    /// The draft as it is typed, so the creature can react to it.
    var onDraft: (String) -> Void = { _ in }
    /// How much room the command palette needs, or 0 when it is closed.
    var onPaletteHeight: (CGFloat) -> Void = { _ in }

    @State private var text = ""
    @State private var pick = 0
    @State private var submitting = false
    @State private var error: String?
    @State private var withFront = false

    private var reply: Bool { variant == .reply }
    private var slash: Bool { text.hasPrefix("/") }
    private var matches: [PanelCommand] { PanelCommand.matches(text) }
    private var query: String { slash ? text.jsSlice(1).jsTrimmed.lowercased() : "" }

    static func paletteHeight(_ count: Int) -> CGFloat {
        count == 0 ? 0 : min(280, CGFloat(count) * paletteRow + 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if reply {
                row.padding(4)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Chrome.overlay(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Chrome.overlay(0.11), lineWidth: 1))
            } else {
                row
            }
            if let error {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Chrome.red)
                    .padding(.top, reply ? 6 : 4).padding(.horizontal, reply ? 6 : 2)
                    .accessibilityAddTraits(.isStaticText)
            }
            if !dropped.isEmpty {
                chips.padding(.top, reply ? 6 : 4).padding(.horizontal, reply ? 6 : 0).padding(.bottom, reply ? 0 : 2)
            }
        }
        .overlay(alignment: reply ? .top : .bottom) {
            if !matches.isEmpty {
                let height = PromptView.paletteHeight(matches.count)
                if reply {
                    palette.offset(y: -(height + 6))
                } else {
                    // The palette spans the bar, not just the field beside the face.
                    palette.frame(width: 620).offset(x: -29, y: height + 15)
                }
            }
        }
        .onChange(of: seed, initial: true) { _, seed in
            if let seed { text = seed.text; error = nil }
        }
        .onChange(of: text, initial: true) { _, text in onDraft(text) }
        .onChange(of: query) { pick = 0 }
        .onChange(of: matches.count, initial: true) { _, count in onPaletteHeight(PromptView.paletteHeight(count)) }
        .onDisappear { onPaletteHeight(0); onDraft("") }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: reply ? 4 : 6) {
            if reply { attachButton }
            ComposerField(
                text: $text,
                placeholder: placeholder,
                font: reply ? .systemFont(ofSize: 14) : .systemFont(ofSize: 19),
                inset: reply ? 5 : 6,
                editable: !submitting,
                focusTick: focusTick + (seed?.id ?? 0) * 1000,
                label: canAnswer ? "Answer Merry" : reply ? "Reply to Merry" : "Ask Merry for help",
                onKey: handle
            )
            if !reply { attachButton }
            if let front, !canAnswer, !busy {
                Button { withFront.toggle() } label: {
                    Icon.screen.image(size: 12)
                        .foregroundStyle(withFront ? Chrome.limeInk : Chrome.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(withFront ? Chrome.lime : Color.clear))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(withFront ? "Remove" : "Include") \(front.name) context (⌥Enter)")
                .accessibilityLabel(Text(verbatim: "Include \(front.name)"))
            }
            sendButton
        }
    }

    private var attachButton: some View {
        PanelIconButton(icon: .attach, help: "Attach files", size: reply ? 13 : 14, action: onAttach)
    }

    private var sendDisabled: Bool {
        text.jsTrimmed.isEmpty || submitting || (busy && !canAnswer && !slash)
    }

    private var sendButton: some View {
        let side: CGFloat = reply ? 30 : 32
        return Button { run(includeFront: withFront && front != nil && !canAnswer) } label: {
            (reply ? Icon.up : Icon.arrow).image(size: reply ? 13 : 14, weight: .semibold)
                .foregroundStyle(sendDisabled ? Chrome.tertiaryText : Chrome.limeInk)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(sendDisabled ? Chrome.overlay(0.06) : Chrome.lime))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(sendDisabled)
        .accessibilityLabel(Text(verbatim: canAnswer ? "Send answer" : reply ? "Send reply" : "Send task"))
    }

    private var chips: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(dropped.prefix(5)), id: \.self) { path in
                chip(PanelPaths.basename(path), color: Chrome.primaryText).frame(maxWidth: 170).help(path)
            }
            if dropped.count > 5 { chip("+\(dropped.count - 5)", color: Chrome.secondaryText) }
            Button(action: onClearDropped) { chip("×", color: Chrome.secondaryText) }
                .buttonStyle(.plain)
                .help("Remove attached files")
                .accessibilityLabel(Text(verbatim: "Remove attached files"))
        }
    }

    private func chip(_ label: String, color: Color) -> some View {
        Text(verbatim: label)
            .font(Chrome.mono(11)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 21)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.overlay(0.07)))
    }

    private var palette: some View {
        let matches = self.matches
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.name) { index, command in
                        Button {
                            text = ""
                            onCommand(command.name)
                        } label: {
                            HStack(spacing: 14) {
                                Text(verbatim: "/\(command.name)").font(Chrome.mono(12, weight: .semibold)).foregroundStyle(Chrome.lime)
                                    .frame(minWidth: 76, alignment: .leading)
                                Text(verbatim: command.hint).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if index == pick { Kbd("↩") }
                            }
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: PromptView.paletteRow)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == pick ? Chrome.overlay(0.08) : Color.clear))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { pick = index } }
                        .id(index)
                    }
                }
                .padding(5)
            }
            .onChange(of: pick) { _, pick in proxy.scrollTo(pick) }
        }
        .frame(height: PromptView.paletteHeight(matches.count))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "#1b1b1f")))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Chrome.overlay(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
    }

    // MARK: - Behaviour

    private func run(includeFront: Bool) {
        let trimmed = text.jsTrimmed
        if trimmed.isEmpty || submitting { return }
        if trimmed.hasPrefix("/") {
            let matches = self.matches
            guard let chosen = pick < matches.count ? matches[pick] : matches.first else { error = "No matching shortcut. Try /help."; return }
            text = ""
            onCommand(chosen.name)
            return
        }
        if busy && !canAnswer { return }
        submitting = true
        error = nil
        Task {
            do {
                try await onSend(trimmed, includeFront)
                text = ""
                withFront = false
            } catch {
                // The draft stays where it is.
                self.error = messageOf(error)
            }
            submitting = false
        }
    }

    private func handle(_ key: ComposerKey) -> Bool {
        let matches = self.matches
        switch key {
        case .escape:
            if !text.isEmpty { text = "" } else { onEscape() }
            return true
        case .digit(let n):
            return text.isEmpty && onNumber(n)
        case .backspace:
            guard text.isEmpty, !dropped.isEmpty else { return false }
            onClearDropped()
            return true
        case .down, .up:
            guard !matches.isEmpty else { return false }
            pick = (pick + (key == .down ? 1 : matches.count - 1)) % matches.count
            return true
        case .tab:
            guard !matches.isEmpty else { return false }
            text = "/\((pick < matches.count ? matches[pick] : matches[0]).name)"
            return true
        case .enter(let alt):
            run(includeFront: (alt || withFront) && front != nil && !canAnswer)
            return true
        }
    }
}

enum ComposerKey: Equatable {
    case enter(alt: Bool), escape, up, down, tab, backspace, digit(Int)
}

/// The text field itself. SwiftUI's own cannot tell Enter from Shift+Enter,
/// swallow a digit, or grow to a limit and then scroll, so this is an NSTextView.
struct ComposerField: NSViewRepresentable {
    static let maxHeight: CGFloat = 132

    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var inset: CGFloat
    var editable: Bool
    var focusTick: Int
    var label: String
    /// Returns true when the key was dealt with.
    var onKey: (ComposerKey) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.delegate = context.coordinator
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = true
        view.font = font
        view.textColor = .labelColor
        view.insertionPointColor = NSColor(Chrome.lime)
        view.textContainerInset = NSSize(width: 0, height: inset)
        view.textContainer?.lineFragmentPadding = 2
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.placeholder = placeholder
        view.string = text
        view.setAccessibilityLabel(label)
        scroll.documentView = view
        context.coordinator.focusTick = focusTick
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.needsDisplay = true
        }
        if view.placeholder != placeholder { view.placeholder = placeholder; view.needsDisplay = true }
        if view.isEditable != editable { view.isEditable = editable }
        view.setAccessibilityLabel(label)
        if context.coordinator.focusTick != focusTick {
            context.coordinator.focusTick = focusTick
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    /// The line grows with what is being typed, to a limit, and then scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: ComposerField.height(text: text, font: font, inset: inset, width: width))
    }

    static func height(text: String, font: NSFont, inset: CGFloat, width: CGFloat) -> CGFloat {
        var measured = text.isEmpty ? " " : text
        if measured.hasSuffix("\n") { measured += " " }
        let box = (measured as NSString).boundingRect(
            with: NSSize(width: max(20, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(maxHeight, box.height.rounded(.up) + inset * 2)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        var focusTick = 0

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            view.needsDisplay = true
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            if view.hasMarkedText() { return true }
            if view.string.isEmpty, replacement.count == 1, let n = Int(replacement), n >= 1, parent.onKey(.digit(n)) { return false }
            let current = (view.string as NSString).length
            let room = PromptView.maxLength - (current - range.length)
            if (replacement as NSString).length > room {
                let kept = replacement.jsSlice(0, max(0, room))
                if !kept.isEmpty { view.insertText(kept, replacementRange: range) }
                return false
            }
            return true
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Keys pressed while an input method is composing belong to it.
            if view.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) { view.insertNewlineIgnoringFieldEditor(nil); return true }
                return parent.onKey(.enter(alt: flags.contains(.option)))
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) { return false }
                return parent.onKey(.enter(alt: true))
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.tab)
            case #selector(NSResponder.deleteBackward(_:)): return parent.onKey(.backspace)
            default: return false
            }
        }
    }
}

/// An NSTextView that draws a placeholder and takes the cursor when it appears.
final class ComposerTextView: NSTextView {
    var placeholder = ""

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.tertiaryLabelColor]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
