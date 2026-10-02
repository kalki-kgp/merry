import SwiftUI
import MerryCore

/// What each route actually costs on this machine, measured rather than
/// assumed. Grouped by where the work happens, because that is the decision:
/// anything on the network is a different design from anything local.
public struct BenchView: View {
    let rows: [BenchRow]
    let running: Bool

    public init(rows: [BenchRow], running: Bool) { self.rows = rows; self.running = running }

    public static func format(_ ms: Double) -> String {
        if ms < 1 { return "<1ms" }
        return ms >= 1000 ? "\((ms / 1000).toFixed(1))s" : "\(JSON.number(ms).stringify())ms"
    }

    /// Under 100ms feels instant, under a second feels responsive, past that you wait.
    public static func band(_ ms: Double) -> String { ms < 100 ? "fast" : ms < 1000 ? "ok" : "slow" }

    public static func spentLine(_ rows: [BenchRow]) -> String {
        let spent = rows.reduce(0) { $0 + ($1.usd ?? 0) }
        return spent > 0 ? "this measurement cost $\(spent.toFixed(6))" : "nothing was charged for this measurement"
    }

    public var body: some View {
        if running && rows.isEmpty {
            Text(verbatim: "Timing every route. The network calls take a few seconds…")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                ForEach(rows.map(\.group).unique, id: \.self) { group in
                    ChromeSection(title: group) {
                        ChromeCard {
                            let members = rows.filter { $0.group == group }
                            ForEach(Array(members.enumerated()), id: \.offset) { index, row in
                                if index > 0 { ChromeRowDivider(inset: 12) }
                                line(row)
                            }
                        }
                    }
                }
                Text(verbatim: Self.spentLine(rows))
                    .font(Chrome.mono(11))
                    .foregroundStyle(Chrome.tertiaryText)
                    .padding(.horizontal, 4)
            }
            .padding(Chrome.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ row: BenchRow) -> some View {
        let band = Self.band(row.ms)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: Self.format(row.ms))
                .font(Chrome.mono(12))
                .foregroundStyle(band == "fast" ? Chrome.lime : band == "slow" ? Chrome.red : Chrome.primaryText)
                .frame(width: 60, alignment: .leading)
            Text(verbatim: row.label).font(.system(size: 12.5)).foregroundStyle(Chrome.primaryText)
            Spacer(minLength: 10)
            Text(verbatim: row.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
