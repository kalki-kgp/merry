import SwiftUI
import MerryCore

// Merry's one glyph language, outside the face: the same dots spell out a
// clock on its TV screen and in the workspace, and a status in 5 × 5.

/// A 5 × 5 status mark. "working" is drawn as a sweeping scanner.
struct DotGlyphView: View {
    var kind: StatusKind
    var color: Color = Chrome.secondaryText
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animated = !reduceMotion && (kind == .working || kind == .ask)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                let glyph = StatusMark.glyph(kind)
                for (r, line) in glyph.enumerated() {
                    for (c, ch) in line.enumerated() {
                        let rect = CGRect(x: Double(c) * 2.6 + 0.3, y: Double(r) * 2.6 + 0.3, width: 2, height: 2)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 0.4), with: .color(color.opacity(opacity(lit: ch == "#", column: c, t: t, animated: animated))))
                    }
                }
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    private func opacity(lit: Bool, column: Int, t: Double, animated: Bool) -> Double {
        switch kind {
        case .working:
            guard animated else { return column % 2 == 0 ? 1 : 0.16 }
            let phase = ((t - Double(column) * 0.12).truncatingRemainder(dividingBy: 0.84) + 0.84).truncatingRemainder(dividingBy: 0.84) / 0.84
            return phase < 0.15 ? 1 : phase < 0.3 ? 0.5 : 0.2
        case .ask:
            guard lit else { return 0.16 }
            guard animated else { return 1 }
            let phase = t.truncatingRemainder(dividingBy: 1.2) / 1.2
            return 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * 2 * .pi))
        default:
            return lit ? 1 : 0.16
        }
    }
}

/// One status, everywhere: a tiny dot glyph, a word, and an optional quiet detail.
struct StatusView<Detail: View>: View {
    var kind: StatusKind
    var label: String
    @ViewBuilder var detail: Detail

    static func tone(_ kind: StatusKind) -> Color {
        switch kind {
        case .working, .done: return Chrome.lime
        case .ask: return Chrome.amber
        case .failed: return Chrome.red
        default: return Chrome.secondaryText
        }
    }

    var body: some View {
        let tone = StatusView.tone(kind)
        HStack(spacing: 7) {
            DotGlyphView(kind: kind, color: tone)
            Text(verbatim: label).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone)
            if Detail.self != EmptyView.self {
                Rectangle().fill(Chrome.secondaryText.opacity(0.35)).frame(width: 1, height: 10)
                detail.font(Chrome.mono(10.5)).monospacedDigit().foregroundStyle(Chrome.secondaryText)
            }
        }
        .lineLimit(1)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tone.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tone.opacity(0.22), lineWidth: 1))
        .fixedSize()
    }
}

extension StatusView where Detail == EmptyView {
    init(kind: StatusKind, label: String) { self.init(kind: kind, label: label) { EmptyView() } }
}

/// Time since a moment, ticking by itself so its parent does not redraw.
struct ElapsedText: View {
    var since: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: PanelModel.elapsed(since: since, now: context.date.timeIntervalSince1970 * 1000))
        }
    }
}

/// A countdown that ticks by itself.
struct TimerText: View {
    var timer: BrainTimer

    var body: some View {
        if timer.status == "running" {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: PanelModel.timerText(timer, now: context.date.timeIntervalSince1970 * 1000))
            }
        } else {
            Text(verbatim: PanelModel.timerText(timer, now: nowMs()))
        }
    }
}

/// A dot-matrix clock for the panel, drawn like the TV's screen.
struct DotClockView: View {
    enum Tone { case on, idle, paused, ringing }

    var ms: Double
    var tone: Tone = .on
    var pitch: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = DotText.clock(ms)
        let layout = DotText.layout(text)
        let r = pitch * 0.36
        let lit: Color = tone == .idle ? Chrome.secondaryText : (tone == .on ? Chrome.lime : Chrome.amber)
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || tone == .idle)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                for cell in layout.cells {
                    let radius = cell.on ? r : r * 0.6
                    let center = CGPoint(x: CGFloat(cell.col) * pitch + pitch / 2, y: CGFloat(cell.row) * pitch + pitch / 2)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    let color = cell.on ? lit.opacity(litOpacity(colon: cell.colon, t: t)) : Color.white.opacity(0.07)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(layout.cols) * pitch, height: 5 * pitch)
        .accessibilityLabel(Text(verbatim: text))
    }

    private func litOpacity(colon: Bool, t: Double) -> Double {
        if reduceMotion { return 1 }
        switch tone {
        case .on: return colon && t.truncatingRemainder(dividingBy: 1) >= 0.5 ? 0.15 : 1
        case .paused:
            let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            return 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * 2 * .pi))
        case .ringing: return t.truncatingRemainder(dividingBy: 0.7) >= 0.35 ? 0.15 : 1
        case .idle: return 1
        }
    }
}

/// A small live waveform while it works, the island's "something is happening".
struct IslandWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let delays: [Double] = [0, 0.7, 0.45, 0.2]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = ((t + IslandWave.delays[i]).truncatingRemainder(dividingBy: 0.9)) / 0.9
                    let scale = reduceMotion ? [0.5, 1, 0.7, 0.4][i] : 0.3 + 0.7 * (0.5 - 0.5 * cos(phase * 2 * .pi))
                    RoundedRectangle(cornerRadius: 1).fill(Chrome.lime).frame(width: 2, height: 14 * scale)
                }
            }
            .frame(height: 14)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Small shared pieces

/// A key cap, for the hints.
struct Kbd: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(Chrome.mono(10))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Chrome.overlay(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Chrome.overlay(0.12), lineWidth: 1))
    }
}

/// A quiet 30-point icon button: the status bar's navigation, a row's delete.
struct PanelIconButton: View {
    var icon: Icon
    var help: String
    var label: String? = nil
    var size: CGFloat = 13
    var selected = false
    var tint: Color? = nil
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            icon.image(size: size)
                .foregroundStyle(tint ?? ((hovering || selected) && enabled ? Chrome.primaryText : Chrome.secondaryText))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((hovering || selected) && enabled ? Chrome.overlay(0.08) : Color.clear))
                .contentShape(.rect)
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
        .help(help)
        .accessibilityLabel(Text(verbatim: label ?? help))
    }
}

/// A small secondary action inside content: Pause, Stop, Copy, Reveal.
struct QuietButton: View {
    var title: String
    var icon: Icon? = nil
    var tint: Color? = nil
    var filled = true
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { icon.image(size: 11) }
                Text(verbatim: title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(tint ?? (hovering ? Chrome.primaryText : Chrome.secondaryText))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(Chrome.overlay(hovering ? 0.1 : (filled ? 0.06 : 0))))
            .contentShape(Capsule(style: .continuous))
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }
}

/// The one accent: the primary action.
struct LimeButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Chrome.limeInk)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule(style: .continuous).fill(Chrome.lime))
                .brightness(hovering ? 0.05 : 0)
                .contentShape(Capsule(style: .continuous))
                .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }
}

/// "Delete this? Files stay." with its two answers.
struct ConfirmBar: View {
    var text: String
    var confirm: String
    var cancelLabel: String
    var busy = false
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Color(hex: "#ffb0a8"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onConfirm) {
                Text(verbatim: confirm).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule(style: .continuous).fill(Chrome.red))
            }
            .buttonStyle(.plain)
            PanelIconButton(icon: .close, help: cancelLabel, action: onCancel)
        }
        .disabled(busy)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Chrome.red.opacity(0.08)))
    }
}

/// A section that opens on a click, like the reference's <details>.
struct Details<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(Chrome.chevronFont).rotationEffect(.degrees(open ? 90 : 0))
                    Text(verbatim: title).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Chrome.secondaryText)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: min(rows.sizes[index].width, bounds.width), height: nil))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, sizes, widest, y + rowHeight)
    }
}
