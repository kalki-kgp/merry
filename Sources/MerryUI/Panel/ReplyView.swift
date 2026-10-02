import AppKit
import SwiftUI
import MerryCore

/// What the person asked: their side of the chat.
struct AskedBubble: View {
    var text: String
    var past = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0).frame(minWidth: 110)
            Text(verbatim: text)
                .font(.system(size: 13.5))
                .foregroundStyle(past ? Chrome.primaryText.opacity(0.8) : Chrome.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous)
                    .fill(Chrome.overlay(past ? 0.04 : 0.08)))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// "Merry", and whatever belongs beside the name.
struct SaysHead<Trailing: View>: View {
    var past = false
    var took: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Merry").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Chrome.lime.opacity(past ? 0.6 : 1))
            if let took {
                Text(verbatim: "· \(took)").font(Chrome.mono(10.5)).foregroundStyle(Chrome.tertiaryText)
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 24)
    }
}

/// What Merry is saying right now: one line while it works, the question when it
/// stops to ask, the outcome with its evidence when it is done. Everything
/// else (the tool calls, the verifications, the log) lives behind /steps.
struct ReplyView: View {
    let bridge: MerryBridge
    var task: TaskState
    /// Show how it ended. A plain answer did nothing, so it has no outcome to badge.
    var badge: Bool
    var onRetry: () -> Void
    var onAnswer: (UserQuestion, String?) async throws -> Void
    var onSteps: () -> Void
    var onWorkspace: () -> Void

    @State private var undoing = false
    @State private var undoNote: String?
    @State private var copied = false

    private var running: Bool { !task.status.isTerminal }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AskedBubble(text: task.request)
            VStack(alignment: .leading, spacing: 12) {
                SaysHead(took: running ? nil : PanelModel.took(task)) {
                    if !running && (task.status == .failed || task.status == .cancelled) {
                        QuietButton(title: "Try again", tint: Chrome.lime, action: onRetry)
                    }
                    if !running && badge {
                        let status = StatusMark.forTask(task.status)
                        StatusView(kind: status.kind, label: status.label)
                    }
                }

                if !running && task.summary == nil {
                    said(task.error.flatMap { $0.isEmpty ? nil : $0 } ?? (task.statusLine.isEmpty ? "Task ended." : task.statusLine))
                }
                if running && !task.plan.isEmpty {
                    Details(title: "Plan") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(task.plan, id: \.id) { step in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Text(verbatim: step.status == "done" ? "✓" : step.status == "active" ? "◉" : "○")
                                    Text(verbatim: step.description).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(step.status == "done" ? Chrome.lime : step.status == "active" ? Chrome.primaryText : Chrome.secondaryText)
                            }
                        }
                    }
                }

                if running && task.question == nil {
                    HStack(spacing: 10) {
                        DotGlyphView(kind: task.status == .paused ? .paused : .working, color: task.status == .paused ? Chrome.tertiaryText : Chrome.lime)
                        Text(verbatim: task.statusLine.isEmpty ? "thinking" : task.statusLine)
                            .font(.system(size: 13)).foregroundStyle(Chrome.secondaryText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if task.status == .paused {
                            QuietButton(title: "Resume") { bridge.resumeTask(task.id) }
                        } else {
                            QuietButton(title: "Pause") { bridge.pauseTask(task.id) }
                        }
                        QuietButton(title: "Stop") { bridge.cancelTask(task.id) }
                    }
                }

                if running { TraceLink(title: "Details", action: onSteps) }

                if let question = task.question {
                    AskView(question: question, onAnswer: onAnswer, onLeave: { bridge.cancelTask(task.id) }).id(question.id)
                }

                if let summary = task.summary, !running {
                    MarkdownView(summary.headline, short: summary.headline.jsLength < 90 && !summary.headline.contains("\n")) { url in
                        Task { try? await bridge.openUrl(url) }
                    }
                    if let error = task.error, !error.isEmpty, task.status != .succeeded {
                        Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Chrome.red)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if summary.undoable {
                        Text(verbatim: "Changed your mind? Everything I moved can go back.")
                            .font(.system(size: 12)).foregroundStyle(Chrome.secondaryText).padding(.top, -6)
                    }
                    if !summary.evidence.isEmpty {
                        ChromeCard {
                            ForEach(Array(summary.evidence.enumerated()), id: \.offset) { index, evidence in
                                if index > 0 { ChromeRowDivider(inset: 12) }
                                ProofView(bridge: bridge, evidence: evidence, onWorkspace: onWorkspace)
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        QuietButton(title: copied ? "Copied" : "Copy", icon: copied ? .check : .copy, filled: false) { copy(summary.headline) }
                            .accessibilityLabel(Text(verbatim: copied ? "Copied" : "Copy answer"))
                        if !task.actions.isEmpty {
                            QuietButton(title: "\(task.actions.count) step\(task.actions.count == 1 ? "" : "s")", icon: .list, filled: false, action: onSteps)
                        }
                        Spacer(minLength: 8)
                        if summary.undoable {
                            LimeButton(title: undoing ? "Undoing…" : "Undo") { undo() }.disabled(undoing)
                        }
                    }
                    .padding(.leading, -10)
                    .padding(.top, 2)
                    if let undoNote {
                        Text(verbatim: undoNote).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func said(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 14)).lineSpacing(3)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ headline: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(Markdown.plainText(headline), forType: .string) else { return }
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func undo() {
        undoing = true
        Task {
            do {
                let report = try await bridge.undoTask(task.id)
                undoNote = report.reversed == 0 && report.skipped.isEmpty
                    ? "Nothing to undo."
                    : "\(report.reversed) restored" + (report.skipped.isEmpty ? "" : ", left \(report.skipped.count) alone: \(report.skipped[0].reason)")
            } catch {
                undoNote = messageOf(error)
            }
            undoing = false
        }
    }
}

/// A quiet text link: Details, Cancel, Show all.
struct TraceLink: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Chrome.primaryText : Chrome.secondaryText)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One piece of evidence.
///
/// A path is a thing you open, so the row is a target with its action on the
/// right. Text is something to read, so it gets the full width and wraps;
/// squeezing prose into a right-hand column is what made these unreadable.
struct ProofView: View {
    let bridge: MerryBridge
    var evidence: Evidence
    var onWorkspace: () -> Void

    @State private var error: String?
    @State private var hovering = false

    var body: some View {
        Group {
            // Something kept in the workspace is a place to go, not a note to read.
            if evidence.kind == .text && evidence.label == "Merry workspace" {
                row(glyph: "›", label: "Saved to your workspace", help: nil, main: onWorkspace) {
                    QuietButton(title: "Open", filled: false, action: onWorkspace)
                }
            } else if evidence.kind == .text {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: evidence.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Chrome.secondaryText)
                    Text(verbatim: evidence.value).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            } else if evidence.kind == .url {
                row(glyph: "↗", label: evidence.label, help: evidence.value, main: { open() }) {
                    Text(verbatim: evidence.value).font(Chrome.mono(10.5)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 230, alignment: .trailing)
                        .padding(.trailing, 10).help(evidence.value)
                }
            } else {
                row(glyph: "›", label: evidence.label, help: evidence.value, main: { open() }) {
                    QuietButton(title: "Reveal", filled: false) { open(reveal: true) }
                }
            }
        }
    }

    private func row<Side: View>(glyph: String, label: String, help: String?, main: @escaping () -> Void, @ViewBuilder side: () -> Side) -> some View {
        HStack(spacing: 10) {
            Button(action: main) {
                HStack(spacing: 10) {
                    Text(verbatim: glyph).font(.system(size: 13, weight: .bold)).foregroundStyle(Chrome.lime).frame(width: 10)
                    Text(verbatim: label).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovering ? Chrome.lime : Chrome.primaryText)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(help ?? label)
            if let error {
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(Chrome.red).lineLimit(1)
            }
            side()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(hovering ? Chrome.overlay(0.04) : Color.clear)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }

    private func open(reveal: Bool = false) {
        error = nil
        Task {
            do {
                if evidence.kind == .url { try await bridge.openUrl(evidence.value) }
                else if reveal { try bridge.revealPath(evidence.value) }
                else { try await bridge.openPath(evidence.value) }
            } catch { self.error = messageOf(error) }
        }
    }
}

/// Where Merry stops and asks. Two cases share this: a real ambiguity, and a
/// request to widen what it is allowed to touch; the second says so plainly.
/// Answers are one keystroke: the options are numbered.
struct AskView: View {
    var question: UserQuestion
    var onAnswer: (UserQuestion, String?) async throws -> Void
    var onLeave: () -> Void

    @State private var sent = false
    @State private var error: String?
    @State private var expanded = false

    private var ops: [FileOp] { question.preview?.fileOps ?? [] }
    private var options: [QuestionOption] { question.options ?? [QuestionOption(id: "ok", label: "go ahead")] }

    /// Where a file is going: just its new name when it stays in its folder.
    static func destination(_ op: FileOp) -> String {
        func folder(_ p: String) -> String {
            let slash = (p as NSString).range(of: "/", options: .backwards).location
            return p.jsSlice(0, slash == NSNotFound ? -1 : slash)
        }
        return op.kind == "rename" || folder(op.from) == folder(op.to) ? PanelPaths.basename(op.to) : op.to
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: question.prompt).font(.system(size: 14)).lineSpacing(3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)

            if let preview = question.preview {
                ChromeCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: preview.title).font(.system(size: 12, weight: .semibold))
                        if let note = preview.note, !note.isEmpty {
                            Text(verbatim: note).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                        }
                        if !ops.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(ops.prefix(expanded ? ops.count : 10).enumerated()), id: \.offset) { _, op in
                                        HStack(spacing: 10) {
                                            Text(verbatim: PanelPaths.basename(op.from)).foregroundStyle(Chrome.secondaryText)
                                                .frame(maxWidth: .infinity, alignment: .leading).help(op.from)
                                            Text(verbatim: "→ \(AskView.destination(op))").foregroundStyle(Chrome.lime)
                                                .frame(maxWidth: .infinity, alignment: .leading).help(op.to)
                                        }
                                        .font(Chrome.mono(11.5, weight: .regular))
                                        .lineLimit(1).truncationMode(.middle)
                                        .textSelection(.enabled)
                                    }
                                    if ops.count > 10 {
                                        TraceLink(title: expanded ? "Show fewer" : "Show all \(ops.count) changes") { expanded.toggle() }.padding(.top, 2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 210)
                            .padding(.top, 9)
                        }
                    }
                    .padding(12)
                }
            }

            if let error {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Chrome.red)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    OptionButton(number: index + 1, label: option.label, primary: index == 0) { answer(option.id) }
                        .help(option.detail ?? "")
                }
            }
            .disabled(sent)
            HStack(spacing: 12) {
                if sent { Text(verbatim: "Sent").font(.system(size: 12)).foregroundStyle(Chrome.secondaryText) }
                TraceLink(title: "Cancel", action: onLeave)
            }
        }
    }

    private func answer(_ optionId: String?) {
        if sent { return }
        sent = true
        Task {
            do { try await onAnswer(question, optionId) } catch {
                sent = false
                self.error = messageOf(error)
            }
        }
    }
}

/// A numbered answer. The first is the one Merry would pick.
struct OptionButton: View {
    var number: Int
    var label: String
    var primary: Bool
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(verbatim: "\(number)").font(Chrome.mono(10, weight: .bold)).opacity(0.55)
                Text(verbatim: label).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(primary ? Chrome.limeInk : Chrome.primaryText)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(primary ? Chrome.lime : Chrome.overlay(hovering ? 0.1 : 0.06)))
            .brightness(primary && hovering ? 0.05 : 0)
            .contentShape(Capsule(style: .continuous))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }
}
