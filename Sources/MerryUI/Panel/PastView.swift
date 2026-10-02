import SwiftUI
import MerryCore

/// History: every saved chat, newest first.
struct PastView: View {
    var rows: [TaskSummaryRow]
    var now: Double = nowMs()
    var onOpen: (String) -> Void
    var onUndo: (String) async throws -> UndoReport
    var onDelete: (String) async throws -> Void

    @State private var note: String?
    @State private var busy = false
    @State private var deleting: String?

    init(rows: [TaskSummaryRow], now: Double = nowMs(), deleting: String? = nil,
         onOpen: @escaping (String) -> Void, onUndo: @escaping (String) async throws -> UndoReport, onDelete: @escaping (String) async throws -> Void) {
        self.rows = rows; self.now = now; self.onOpen = onOpen; self.onUndo = onUndo; self.onDelete = onDelete
        _deleting = State(initialValue: deleting)
    }

    static func confirmText(_ row: TaskSummaryRow) -> String {
        (row.turns > 1 ? "Delete this chat (\(row.turns) messages) and its undo history?" : "Delete this chat and its undo history?") + " Files stay."
    }

    static func undoNote(_ report: UndoReport) -> String {
        "\(report.reversed) restored" + (report.skipped.isEmpty ? "" : " · \(report.skipped.count) skipped")
    }

    var body: some View {
        if rows.isEmpty {
            PaneEmpty(text: "No saved chats.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let note {
                    Text(verbatim: note).font(.system(size: 12)).foregroundStyle(Color(hex: "#ffd79a"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Chrome.amber.opacity(0.08)))
                }
                ChromeCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { ChromeRowDivider(inset: 35) }
                        PastRow(row: row, age: PanelModel.relative(row.createdAt, now: now), busy: busy,
                                onOpen: { onOpen(row.id) }, onUndo: { undo(row.id) },
                                onTrash: { deleting = deleting == row.id ? nil : row.id })
                        if deleting == row.id {
                            ConfirmBar(text: PastView.confirmText(row), confirm: "Delete", cancelLabel: "Cancel deletion", busy: busy,
                                       onConfirm: { remove(row.id) }, onCancel: { deleting = nil })
                                .padding(.horizontal, 6).padding(.bottom, 6)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))
            }
        }
    }

    private func undo(_ id: String) {
        busy = true
        Task {
            do { note = PastView.undoNote(try await onUndo(id)) } catch { note = messageOf(error) }
            busy = false
        }
    }

    private func remove(_ id: String) {
        busy = true
        Task {
            do { try await onDelete(id); deleting = nil } catch { note = messageOf(error) }
            busy = false
        }
    }
}

private struct PastRow: View {
    var row: TaskSummaryRow
    var age: String
    var busy: Bool
    var onOpen: () -> Void
    var onUndo: () -> Void
    var onTrash: () -> Void

    @State private var hovering = false

    var body: some View {
        let status = StatusMark.forTask(row.status)
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    DotGlyphView(kind: status.kind, color: StatusView<EmptyView>.tone(status.kind)).help(status.label)
                    Text(verbatim: PanelModel.firstLine(row.request)).font(.system(size: 13)).foregroundStyle(Chrome.primaryText)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if row.turns > 1 {
                        Text(verbatim: "\(row.turns)").font(Chrome.mono(10)).foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Chrome.overlay(0.07)))
                            .help("\(row.turns) messages")
                    }
                    Text(verbatim: age).font(Chrome.mono(10)).foregroundStyle(Chrome.tertiaryText)
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if row.undoable {
                QuietButton(title: "Undo", tint: Chrome.lime, action: onUndo).disabled(busy)
            }
            PanelIconButton(icon: .trash, help: row.status.isTerminal ? "Delete chat" : "Stop the task before deleting",
                            label: "Delete \(row.request)", size: 12, action: onTrash)
                .disabled(busy || !row.status.isTerminal)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 40)
        .background(hovering ? Chrome.overlay(0.04) : Color.clear)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }
}
