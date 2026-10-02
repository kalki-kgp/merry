import SwiftUI
import MerryCore

/// The receipt: every tool call, its outcome, and whether its effect was
/// independently verified. This is what makes "I did it" checkable instead of
/// something you have to take on trust.
struct StepsView: View {
    var task: TaskState?
    var logs: [LogEntry]

    static func mark(_ outcome: ActionRecord.Outcome) -> String {
        switch outcome {
        case .success: return "✓"
        case .failure: return "✕"
        case .uncertain: return "?"
        }
    }

    static func duration(_ action: ActionRecord) -> String {
        action.finishedAt.map { "\((($0 - action.startedAt) / 1000).toFixed(1))s" } ?? ""
    }

    static func logLine(_ entry: LogEntry) -> String {
        "\(JSDate(entry.at).format("h:mm:ss a"))  \(entry.source): \(entry.message)"
    }

    var body: some View {
        if let task {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: task.request).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                if task.actions.isEmpty {
                    PaneEmpty(text: "Nothing ran.")
                } else {
                    ChromeCard {
                        ForEach(Array(task.actions.enumerated()), id: \.element.id) { index, action in
                            if index > 0 { ChromeRowDivider(inset: 34) }
                            row(action)
                        }
                    }
                }
                if !task.observations.isEmpty {
                    Details(title: "what I looked at (\(task.observations.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(task.observations.suffix(8), id: \.id) { observation in
                                (Text(verbatim: observation.kind).foregroundStyle(Chrome.primaryText) + Text(verbatim: "  \(observation.summary)"))
                                    .font(.system(size: 11)).foregroundStyle(Chrome.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                if !logs.isEmpty {
                    Details(title: "the whole log (\(logs.count))") {
                        Text(verbatim: logs.suffix(60).map(StepsView.logLine).joined(separator: "\n"))
                            .font(Chrome.mono(11, weight: .regular)).foregroundStyle(Chrome.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05)))
                    }
                    .padding(.horizontal, 4)
                }
            }
        } else {
            PaneEmpty(text: "I haven’t done anything yet.")
        }
    }

    private func row(_ action: ActionRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: StepsView.mark(action.outcome)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(action.outcome == .success ? Chrome.lime : action.outcome == .failure ? Chrome.red : Chrome.amber)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: action.tool).font(Chrome.mono(11.5)).foregroundStyle(Chrome.primaryText)
                if let verification = action.verification {
                    Text(verbatim: verification.detail).foregroundStyle(verification.verified ? Chrome.secondaryText : Chrome.red)
                }
                if let error = action.error, !error.isEmpty {
                    Text(verbatim: error).foregroundStyle(Chrome.red)
                }
                if action.outcome == .uncertain {
                    Text(verbatim: "couldn’t confirm this one, so I’ll check before repeating it").foregroundStyle(Chrome.amber)
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: StepsView.duration(action)).font(Chrome.mono(10)).foregroundStyle(Chrome.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A page with nothing on it yet.
struct PaneEmpty: View {
    var text: String

    var body: some View {
        Text(verbatim: text).font(.system(size: 13)).foregroundStyle(Chrome.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 20)
    }
}
