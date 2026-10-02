import SwiftUI
import MerryCore

// Things that outlive a conversation, in the same rows and hairlines as the
// rest of the panel. The focus timer on top is a tiny screen: the same dots,
// the same clock, that the pet shows on its TV while it runs.

/// Merry's own workspace: notes, tasks, reminders, projects and the focus timer.
public struct BrainView: View {
    private let state: BrainSnapshot
    private let onCompose: (String) -> Void
    private let onBack: () -> Void

    @StateObject private var model: BrainModel
    @StateObject private var clock: BrainClock

    public init(bridge: MerryBridge, state: BrainSnapshot, onCompose: @escaping (String) -> Void, onBack: @escaping () -> Void) {
        self.init(bridge: bridge, state: state, now: nil, prepare: nil, onCompose: onCompose, onBack: onBack)
    }

    /// `now` stops the clock at one moment and `prepare` arranges the page before it is first drawn: both for previews.
    init(bridge: MerryBridge, state: BrainSnapshot, now: Double?, prepare: ((BrainModel) -> Void)?, onCompose: @escaping (String) -> Void, onBack: @escaping () -> Void) {
        self.state = state
        self.onCompose = onCompose
        self.onBack = onBack
        _model = StateObject(wrappedValue: {
            let model = BrainModel(bridge: bridge, state: state)
            prepare?(model)
            return model
        }())
        _clock = StateObject(wrappedValue: now.map { BrainClock(fixed: $0) } ?? BrainClock())
    }

    public var body: some View {
        let now = clock.now
        let groups = model.groups(now: now)
        VStack(alignment: .leading, spacing: 12) {
            header(now: now)
            BrainFocus(model: model, timer: model.state.timer, now: now)
            if let notice = model.dueNotice(now: now) { dueNotice(notice) }
            if !model.state.items.isEmpty { bar(now: now) }
            if !model.error.isEmpty {
                Text(verbatim: model.error).font(.system(size: 12)).foregroundStyle(Chrome.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
            if model.editing != nil { BrainEditor(model: model, now: now).transition(.softAppear) }
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.label) { group in groupView(group, now: now) }
                }
            }
            if model.showsEmpty(now: now) { empty }
            Text(verbatim: "Kept on this Mac · reminders catch up when Merry runs again")
                .font(Chrome.mono(10)).foregroundStyle(Chrome.tertiaryText)
                .frame(maxWidth: .infinity).padding(.top, 6)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.timeZone, LocalTime.calendar.timeZone)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Merry workspace")
        .onChange(of: state) { _, value in model.state = value }
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private func header(now: Double) -> some View {
        HStack(spacing: 8) {
            BrainCircleButton(icon: .back, help: "Back home", action: onBack)
            Text(verbatim: "Workspace").font(.system(size: 17, weight: .semibold)).foregroundStyle(Chrome.primaryText)
            Spacer(minLength: 8)
            Text(verbatim: model.headerDate(now: now) + (model.openCount > 0 ? "  ·  \(model.openCount) open" : ""))
                .font(Chrome.mono(10.5)).foregroundStyle(Chrome.tertiaryText).lineLimit(1)
                .padding(.trailing, 4)
            BrainPrimaryButton(icon: .plus, title: "New") { withAnimation(Chrome.panelSlide) { model.beginNew() } }
        }
    }

    private func dueNotice(_ text: String) -> some View {
        HStack(spacing: 9) {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Color(hex: "#ffd79a"))
            Spacer(minLength: 8)
            Button { model.review() } label: {
                Text(verbatim: "Review").font(.system(size: 12, weight: .semibold)).foregroundStyle(Chrome.amber).contentShape(.rect)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.amber.opacity(0.08)))
    }

    private func bar(now: Double) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.sections(now: now), id: \.tab) { section in
                        BrainTabButton(section: section, selected: model.isSelected(section.tab)) { model.select(section.tab) }
                    }
                }
                .padding(3)
            }
            // Sections that do not fit fade out at the edge rather than stop dead.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Chrome.overlay(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityLabel("Workspace sections")
            BrainSearch(model: model)
            if !model.projects.isEmpty {
                BrainPicker(options: [(value: "", title: "All projects")] + model.projects.map { (value: $0.id, title: Self.short($0.title)) },
                                  selection: $model.project, placeholder: "All projects")
                    .accessibilityLabel("Filter by project")
            }
        }
    }

    /// A picker's capsule is as wide as its title, so a long project name is cut to fit the bar.
    static func short(_ title: String) -> String { title.jsLength > 18 ? title.jsSlice(0, 17) + "…" : title }

    private func groupView(_ group: BrainGroup, now: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !group.label.isEmpty {
                HStack(spacing: 7) {
                    Text(verbatim: group.label.uppercased()).tracking(1.4)
                        .foregroundStyle(group.label == "Overdue" ? Chrome.amber : Chrome.tertiaryText)
                    Text(verbatim: "\(group.items.count)").foregroundStyle(Chrome.tertiaryText.opacity(0.7))
                }
                .font(Chrome.mono(10, weight: .semibold))
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 6, trailing: 10))
            }
            ChromeCard {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { ChromeRowDivider(inset: 50) }
                    BrainRowView(model: model, item: item, now: now, onCompose: onCompose)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            SpriteView(state: .idle, mood: model.emptyMood, size: 54, quiet: true).padding(.bottom, 4)
            Text(verbatim: model.emptyTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Chrome.primaryText)
            Text(verbatim: model.emptyDetail).font(.system(size: 12)).foregroundStyle(Chrome.secondaryText)
            if !model.starters.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.starters, id: \.label) { starter in
                        BrainGlassButton(title: starter.label) { onCompose(starter.prompt) }
                    }
                }
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 18, leading: 10, bottom: 6, trailing: 10))
    }
}

// MARK: - The focus timer

/// The focus timer. While it runs, the pet on the desktop is a little TV showing the same clock.
private struct BrainFocus: View {
    @ObservedObject var model: BrainModel
    let timer: BrainTimer?
    let now: Double
    @FocusState private var labelFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
        ChromeCard {
            HStack(spacing: 14) {
                if let timer { running(timer) } else { idle }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            // How far along, as a hairline along the bottom edge.
            if let timer {
                GeometryReader { geo in
                    Rectangle().fill(timer.status == "running" ? Chrome.lime : Chrome.amber)
                        .frame(width: geo.size.width * BrainModel.timerProgress(timer, now: now), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .animation(.linear(duration: 1), value: now)
                }
                .accessibilityHidden(true)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
    }

    private var border: Color {
        switch timer?.status {
        case "running": return Chrome.lime.opacity(0.18)
        case "paused": return Chrome.amber.opacity(0.2)
        case "ringing": return Chrome.amber.opacity(0.4)
        default: return Chrome.overlay(0.06)
        }
    }

    private func screen(ms: Double, tone: String) -> some View {
        BrainDotClock(ms: ms, tone: tone, pitch: 3.4)
            .padding(.horizontal, 10)
            .frame(minWidth: 84, minHeight: 44, maxHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(RadialGradient(colors: [Color(hex: "#121609"), Color(hex: "#050506")], center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 60))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1) }
            }
    }

    @ViewBuilder private var idle: some View {
        screen(ms: model.idleMs, tone: "idle")
        VStack(alignment: .leading, spacing: 5) {
            TextField("", text: Binding(get: { model.label }, set: { model.label = $0.jsSlice(0, 100) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .focused($labelFocused)
                .overlay(alignment: .bottom) { if labelFocused { Rectangle().fill(Chrome.lime).frame(height: 1).offset(y: 2) } }
                .onSubmit(start)
                .accessibilityLabel("Timer label")
            HStack(spacing: 4) {
                ForEach(BrainModel.presets, id: \.self) { preset in
                    let chosen = model.isChosen(preset: preset)
                    Button { model.choose(preset: preset) } label: {
                        Text(verbatim: "\(preset)").font(Chrome.mono(11))
                            .foregroundStyle(chosen ? Chrome.lime : Chrome.secondaryText)
                            .frame(minWidth: 30, minHeight: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chosen ? Chrome.lime.opacity(0.09) : Chrome.overlay(0.06)))
                            .overlay { if chosen { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Chrome.lime.opacity(0.25), lineWidth: 1) } }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
                TextField("", text: Binding(get: { model.minutesText }, set: { model.minutesText = String($0.filter { $0.isNumber || $0 == "." }.prefix(6)) }))
                    .textFieldStyle(.plain)
                    .font(Chrome.mono(11, weight: .regular))
                    .foregroundStyle(Chrome.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(width: 46, height: 22)
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Chrome.overlay(0.11), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                    .padding(.leading, 4)
                    .onSubmit(start)
                    .accessibilityLabel("Timer minutes")
                Text(verbatim: "min").font(Chrome.mono(10.5)).foregroundStyle(Chrome.tertiaryText).padding(.leading, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        BrainPrimaryButton(icon: nil, title: "Start", isEnabled: !model.busy && model.canStart, action: start)
    }

    private func start() { Task { await model.startTimer() } }

    @ViewBuilder private func running(_ timer: BrainTimer) -> some View {
        screen(ms: timer.remaining(now: now), tone: BrainModel.timerTone(timer))
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: timer.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Chrome.primaryText).lineLimit(1)
            Text(verbatim: BrainModel.timerLine(timer)).font(.system(size: 11.5)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        BrainGlassButton(title: BrainModel.timerButton(timer), isEnabled: !model.busy) { Task { await model.timerAct(timer) } }
        if timer.status != "ringing" {
            BrainCircleButton(icon: .close, help: "Cancel timer") { Task { await model.cancelTimer() } }
                .disabled(model.busy)
        }
    }
}

/// A dot-matrix clock for the panel, drawn like the TV's screen.
private struct BrainDotClock: View {
    let ms: Double
    /// on | idle | paused | ringing
    let tone: String
    var pitch: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = DotText.clock(ms)
        let layout = DotText.layout(text)
        TimelineView(.animation(minimumInterval: tone == "paused" ? 1.0 / 20 : 0.1, paused: tone == "idle" || reduceMotion)) { context in
            Canvas { ctx, _ in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let r = pitch * 0.36
                var lit = Path(), unlit = Path(), colon = Path()
                for cell in layout.cells {
                    let cx = CGFloat(cell.col) * pitch + pitch / 2, cy = CGFloat(cell.row) * pitch + pitch / 2
                    let radius = cell.on ? r : r * 0.6
                    let dot = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                    if !cell.on { unlit.addEllipse(in: dot) } else if cell.colon { colon.addEllipse(in: dot) } else { lit.addEllipse(in: dot) }
                }
                let phase: (Double) -> Double = { period in (seconds / period).truncatingRemainder(dividingBy: 1) }
                var body = 1.0, colonLevel = 1.0
                if !reduceMotion {
                    switch tone {
                    case "on": colonLevel = phase(1) < 0.5 ? 1 : 0.15
                    case "paused":
                        let p = phase(1.6)
                        body = 0.35 + 0.65 * (p < 0.5 ? p * 2 : (1 - p) * 2)
                    case "ringing": body = phase(0.7) < 0.5 ? 1 : 0.15
                    default: break
                    }
                }
                let colour: Color = tone == "idle" ? Color(hex: "#8d8f95") : tone == "on" ? Chrome.lime : Chrome.amber
                ctx.fill(unlit, with: .color(.white.opacity(0.07)))
                if tone != "idle" {
                    ctx.drawLayer { glow in
                        glow.addFilter(.blur(radius: 1.2))
                        glow.fill(lit, with: .color(colour.opacity(0.55 * body)))
                        glow.fill(colon, with: .color(colour.opacity(0.55 * body * colonLevel)))
                    }
                }
                ctx.fill(lit, with: .color(colour.opacity(body)))
                ctx.fill(colon, with: .color(colour.opacity(body * colonLevel)))
            }
        }
        .frame(width: CGFloat(layout.cols) * pitch, height: 5 * pitch)
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

// MARK: - The bar

private struct BrainTabButton: View {
    let section: BrainSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: section.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Chrome.primaryText.opacity(selected ? 1 : hovering ? 0.9 : 0.62))
                if section.count > 0 {
                    Text(verbatim: "\(section.count)").font(Chrome.mono(10))
                        .foregroundStyle(selected ? Chrome.lime : Chrome.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.13)) }
                else if hovering { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BrainSearch: View {
    @ObservedObject var model: BrainModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Icon.search.image(size: 12).foregroundStyle(focused ? Chrome.lime : Chrome.tertiaryText)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .frame(width: focused || !model.query.isEmpty ? 140 : 64)
                .onKeyPress(.escape) { model.clearSearch() ? .handled : .ignored }
                .accessibilityLabel("Search workspace")
        }
        .padding(.horizontal, 10)
        .frame(height: Chrome.capsuleContentHeight)
        .background(Capsule(style: .continuous).fill(Chrome.overlay(0.05)))
        .overlay { Capsule(style: .continuous).strokeBorder(focused ? Chrome.lime.opacity(0.27) : Chrome.overlay(0.06), lineWidth: 1) }
        .animation(.easeOut(duration: 0.18), value: focused)
        .onTapGesture { focused = true }
    }
}

// MARK: - A row

private struct BrainRowView: View {
    @ObservedObject var model: BrainModel
    let item: BrainItem
    let now: Double
    let onCompose: (String) -> Void
    @State private var hovering = false

    var body: some View {
        let overdue = model.isOverdue(item, now: now)
        let done = item.status == "done"
        HStack(alignment: .top, spacing: 12) {
            leading(overdue: overdue, done: done).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button { edit() } label: {
                        Text(verbatim: item.title).font(.system(size: 13.5, weight: .medium))
                            .strikethrough(done, color: Chrome.tertiaryText)
                            .foregroundStyle(done ? Chrome.secondaryText : Chrome.primaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if model.mixed {
                        Text(verbatim: model.kindLabel(item).uppercased()).font(Chrome.mono(9.5)).tracking(1.1).foregroundStyle(Chrome.tertiaryText)
                            .opacity(hovering ? 0 : 1)
                    }
                }
                .frame(minHeight: 28)
                // The row's own actions appear over its right edge while the pointer is on it.
                .overlay(alignment: .trailing) {
                    HStack(spacing: 2) {
                        BrainLinkButton(title: "Edit", colour: Chrome.secondaryText) { edit() }
                        BrainLinkButton(title: model.archiveLabel(item), colour: Chrome.secondaryText, isEnabled: !model.busy) { Task { await model.toggleArchive(item) } }
                    }
                    .background(Capsule(style: .continuous).fill(Color(hex: "#2b2c31")))
                    .offset(x: 4)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
                if !item.body.isEmpty {
                    Text(verbatim: item.body).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(2).textSelection(.enabled).padding(.top, 1)
                }
                meta(overdue: overdue)
                if !item.sources.isEmpty {
                    BrainFlow(spacing: 5) {
                        ForEach(Array(item.sources.enumerated()), id: \.offset) { _, source in
                            Button { Task { await model.open(source) } } label: {
                                HStack(spacing: 5) {
                                    (source.kind == "url" ? Icon.arrow : Icon.attach).image(size: 9.5)
                                    Text(verbatim: model.sourceLabel(source)).font(Chrome.mono(11)).lineLimit(1).truncationMode(.middle)
                                }
                                .foregroundStyle(Chrome.ice)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: 220).fixedSize(horizontal: true, vertical: false)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.overlay(0.06)))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(source.value)
                        }
                    }
                    .padding(.top, 7).padding(.bottom, 2)
                }
                if item.kind == "tracker" { tracker }
                more
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hovering ? Chrome.overlay(0.04) : Color.clear)
        .contentShape(.rect)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }

    private func edit() { withAnimation(Chrome.panelSlide) { model.beginEdit(item) } }

    @ViewBuilder private func leading(overdue: Bool, done: Bool) -> some View {
        if model.isCheckable(item) {
            Button { Task { await model.toggleDone(item) } } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(done ? Chrome.lime : Color.clear)
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(done ? Chrome.lime : overdue ? Chrome.amber : Chrome.overlay(0.22), lineWidth: 1.5) }
                    .overlay { if done { Icon.check.image(size: 10, weight: .bold).foregroundStyle(Chrome.limeInk) } }
                    .frame(width: 18, height: 18)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .accessibilityLabel(model.checkLabel(item))
        } else {
            IconTile(symbol: BrainModel.icon(item.kind).rawValue, hue: Self.hue(item.kind))
        }
    }

    static func hue(_ kind: String) -> Int {
        switch kind {
        case "project": return 5
        case "bookmark": return 6
        case "session": return 3
        case "tracker": return 4
        default: return 7
        }
    }

    @ViewBuilder private func meta(overdue: Bool) -> some View {
        let due = model.dueText(item, now: now), project = model.projectName(item), estimate = model.estimateText(item)
        if due != nil || project != nil || estimate != nil {
            BrainFlow(spacing: 12, lineSpacing: 4) {
                if let due {
                    HStack(spacing: 5) { Icon.clock.image(size: 9.5); Text(verbatim: due) }
                        .foregroundStyle(overdue ? Chrome.amber : Chrome.tertiaryText)
                }
                if let project { HStack(spacing: 5) { Icon.folder.image(size: 9.5); Text(verbatim: project).lineLimit(1) } }
                if let estimate { Text(verbatim: estimate) }
            }
            .font(Chrome.mono(10.5))
            .foregroundStyle(Chrome.tertiaryText)
            .padding(.top, 5)
        }
    }

    private var tracker: some View {
        let done = model.doneToday(item, now: now)
        return HStack(spacing: 4) {
            ForEach(model.days(item, now: now), id: \.key) { day in
                Text(verbatim: day.letter).font(Chrome.mono(9.5))
                    .foregroundStyle(day.checked ? Chrome.limeInk : day.isToday ? Chrome.secondaryText : Chrome.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(day.checked ? Chrome.lime : Chrome.overlay(0.06)))
                    .overlay { if day.isToday && !day.checked { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Chrome.overlay(0.2), lineWidth: 1) } }
                    .help(day.key)
            }
            Spacer(minLength: 8)
            BrainGlassButton(icon: done ? .check : nil, title: model.checkInLabel(item, now: now), isEnabled: !model.busy, colour: done ? Chrome.lime : nil) {
                Task { await model.checkIn(item) }
            }
            .accessibilityAddTraits(done ? .isSelected : [])
        }
        .padding(.top, 8).padding(.bottom, 2)
    }

    @ViewBuilder private var more: some View {
        let offers = model.more(item, now: now)
        if !offers.isEmpty {
            BrainFlow(spacing: 4) {
                ForEach(offers, id: \.self) { offer in
                    BrainLinkButton(title: offer.label, colour: Chrome.lime, isEnabled: !(model.busy && (offer == .snooze || offer == .dismiss))) { perform(offer) }
                }
            }
            .padding(.top, 6).padding(.leading, -7)
        }
    }

    private func perform(_ offer: BrainMore) {
        switch offer {
        case .viewProject: model.viewProject(item)
        case .saveSession, .resume: if let prompt = model.prompt(offer, item) { onCompose(prompt) }
        case .snooze: Task { await model.snooze(item) }
        case .dismiss: Task { await model.acknowledge(item) }
        }
    }
}

// MARK: - The editor

private struct BrainEditor: View {
    @ObservedObject var model: BrainModel
    let now: Double
    @FocusState private var titleFocused: Bool

    private func field<T>(_ path: WritableKeyPath<BrainDraft, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { model.editing?[keyPath: path] ?? fallback }, set: { model.editing?[keyPath: path] = $0 })
    }

    var body: some View {
        let draft = model.editing ?? BrainDraft(id: nil, kind: "note")
        ChromeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BrainPicker(options: BrainTab.kinds.map { (value: $0.rawValue, title: $0.name) }, selection: field(\.kind, "note"))
                        .accessibilityLabel("Item type")
                    BrainPicker(options: [(value: "", title: "No project")] + model.projects.map { (value: $0.id, title: BrainView.short($0.title)) },
                                      selection: Binding(get: { model.editing?.projectId ?? "" }, set: { model.editing?.projectId = $0.isEmpty ? nil : $0 }),
                                      placeholder: "No project")
                        .disabled(draft.kind == "project").opacity(draft.kind == "project" ? 0.45 : 1)
                        .accessibilityLabel("Item project")
                    Spacer(minLength: 0)
                }
                TextField("Give it a name", text: Binding(get: { model.editing?.title ?? "" }, set: { model.editing?.title = $0.jsSlice(0, 300) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($titleFocused)
                    .padding(.horizontal, 2).padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(titleFocused ? Chrome.lime : Chrome.overlay(0.08)).frame(height: 1) }
                    .onSubmit(save)
                    .accessibilityLabel("Item title")
                TextField(model.bodyPlaceholder(draft.kind), text: Binding(get: { model.editing?.body ?? "" }, set: { model.editing?.body = $0.jsSlice(0, 40000) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13)).lineSpacing(3)
                    .lineLimit(4...12)
                    .brainField()
                    .accessibilityLabel("Item details")
                HStack(alignment: .top, spacing: 16) {
                    labelled("Remind me") { dueControl(draft) }
                    labelled("Repeat") {
                        BrainPicker(options: [(value: "none", title: "Once"), (value: "daily", title: "Daily"), (value: "weekly", title: "Weekly")], selection: field(\.repeats, "none"))
                            .accessibilityLabel("Repeat reminder")
                    }
                    if draft.kind == "task" {
                        labelled("Minutes") {
                            TextField("", text: Binding(get: { model.editing?.estimate ?? "" }, set: { model.editing?.estimate = String($0.filter { $0.isNumber || $0 == "." }.prefix(6)) }))
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .frame(width: 64)
                                .brainField()
                                .accessibilityLabel("Task estimate")
                        }
                    }
                    Spacer(minLength: 0)
                }
                TextField("Keep a source link (optional)", text: field(\.url, ""))
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .brainField()
                    .onSubmit(save)
                    .accessibilityLabel("Source link")
                ForEach(Array(draft.sources.enumerated()), id: \.offset) { index, source in
                    HStack(spacing: 8) {
                        Text(verbatim: source.label).font(Chrome.mono(11, weight: .regular)).foregroundStyle(Chrome.ice)
                            .lineLimit(2).help(source.value)
                        Spacer(minLength: 8)
                        Button { model.removeSource(at: index) } label: {
                            Icon.close.image(size: 10).foregroundStyle(Chrome.secondaryText).frame(width: 22, height: 22).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove source \(source.label)")
                    }
                }
                if !draft.error.isEmpty {
                    Text(verbatim: draft.error).font(.system(size: 12)).foregroundStyle(Chrome.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    BrainGlassButton(icon: .attach, title: "Add files") { Task { await model.addFiles() } }
                    Spacer(minLength: 8)
                    BrainGlassButton(title: "Cancel", isEnabled: !draft.busy) { withAnimation(Chrome.panelSlide) { model.cancelEdit() } }
                    BrainPrimaryButton(icon: nil, title: draft.busy ? "Saving…" : "Save", isEnabled: model.canSave, action: save)
                }
            }
            .padding(12)
        }
        .overlay { RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous).strokeBorder(Chrome.overlay(0.11), lineWidth: 1) }
        .onAppear { titleFocused = true }
    }

    private func save() { Task { await model.save() } }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title.uppercased()).font(Chrome.mono(9.5)).tracking(1.1).foregroundStyle(Chrome.tertiaryText)
            content().frame(minHeight: Chrome.capsuleContentHeight)
        }
    }

    /// A date field once there is a time; until then, a button that sets one.
    @ViewBuilder private func dueControl(_ draft: BrainDraft) -> some View {
        if draft.due.isEmpty {
            BrainCircleButton(icon: .plus, help: "Reminder time") {
                let next = JSDate(now).with { $0.setHours($0.hours + 1, 0, 0, 0) }
                model.editing?.due = BrainModel.localTime(next.time)
            }
        } else {
            HStack(spacing: 6) {
                DatePicker("", selection: Binding(
                    get: { JSDate(iso: draft.due)?.date ?? Date(timeIntervalSince1970: now / 1000) },
                    set: { model.editing?.due = BrainModel.localTime(JSDate($0).time) }
                ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .environment(\.calendar, LocalTime.calendar)
                    .accessibilityLabel("Reminder time")
                Button { model.editing?.due = "" } label: {
                    Icon.close.image(size: 10).foregroundStyle(Chrome.secondaryText).frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }
}

// MARK: - Pieces

private struct BrainFlatGlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Draws the page's glass controls as flat shapes. Tinted glass cannot be
    /// captured offscreen, so the snapshot screens set this; the app never does.
    var brainFlatGlass: Bool {
        get { self[BrainFlatGlassKey.self] }
        set { self[BrainFlatGlassKey.self] = newValue }
    }
}

private extension View {
    @ViewBuilder func brainGlass<S: Shape>(flat: Bool, in shape: S) -> some View {
        if flat { background(shape.fill(Chrome.overlay(0.08))) } else { glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: shape) }
    }
}

private struct BrainCircleButton: View {
    let icon: Icon
    let help: String
    let action: () -> Void
    @Environment(\.brainFlatGlass) private var flat

    var body: some View {
        if flat {
            Image(systemName: icon.rawValue).font(Chrome.iconFont).foregroundStyle(Chrome.primaryText.opacity(0.92))
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .background(Circle().fill(Chrome.overlay(0.08)))
        } else {
            ChromeCircleButton(symbol: icon.rawValue, help: help, action: action)
        }
    }
}

private struct BrainPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var placeholder = "—"
    @Environment(\.brainFlatGlass) private var flat

    var body: some View {
        if flat {
            HStack(spacing: 6) {
                Text(verbatim: options.first { $0.value == selection }?.title ?? placeholder).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Chrome.chevronFont).foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .background(Capsule(style: .continuous).fill(Chrome.overlay(0.08)))
            .fixedSize()
        } else {
            GlassPickerButton(options: options, selection: $selection, placeholder: placeholder)
        }
    }
}

private extension View {
    /// The quiet inset the editor's text fields sit in.
    func brainField() -> some View {
        padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.overlay(0.05)))
    }
}

/// The page's primary action: lime, with dark ink.
private struct BrainPrimaryButton: View {
    let icon: Icon?
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { icon.image(size: 11, weight: .bold) }
                Text(verbatim: title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(isEnabled ? Chrome.limeInk : Chrome.tertiaryText)
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleHeight)
            .background(Capsule(style: .continuous).fill(isEnabled ? Chrome.lime : Chrome.overlay(0.06)))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
    }
}

/// `ChromeTextButton` for a title that has no icon of its own.
private struct BrainGlassButton: View {
    var icon: Icon?
    let title: String
    var isEnabled = true
    var colour: Color?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.brainFlatGlass) private var flat

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { icon.image(size: 11, weight: .semibold) }
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle((colour ?? Chrome.primaryText).opacity(!isEnabled ? 0.32 : hovering ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
        .brainGlass(flat: flat, in: Capsule(style: .continuous))
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
    }
}

/// The small capitals a row's own actions are set in.
private struct BrainLinkButton: View {
    let title: String
    let colour: Color
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title.uppercased()).font(Chrome.mono(10, weight: .semibold)).tracking(1)
                .foregroundStyle(colour.opacity(isEnabled ? 1 : 0.4))
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Chrome.overlay(0.07) : Color.clear))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { h in withAnimation(Chrome.hover) { hovering = h } }
        .accessibilityLabel(title)
    }
}

/// Lays children out left to right and wraps them onto new lines.
private struct BrainFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat?

    private func place(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + (lineSpacing ?? spacing)
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = place(subviews, width: bounds.width).origins
        for (view, origin) in zip(subviews, origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
