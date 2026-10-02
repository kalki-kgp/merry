import AppKit
import SwiftUI
import MerryCore

/// Merry on the desktop: the creature, its speech bubble, and the little
/// bursts of hearts and sparks. The one part of the interface that keeps the
/// reference's own look rather than glass.
public struct PetView: View {
    @StateObject private var model: PetModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide: CGFloat = 0
    @State private var fade = 1.0

    public init(bridge: MerryBridge) {
        _model = StateObject(wrappedValue: PetModel(bridge: bridge))
    }

    init(model: PetModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        let bubble = model.bubbleContent
        ZStack(alignment: .bottom) {
            PetMotion(dancing: model.dancing, hops: model.hops, still: reduceMotion) {
                SpriteView(state: model.state, mood: model.mood, size: PetLayout.spriteSize, look: model.look, timer: model.spriteTimer)
            }
            .padding(.bottom, 4)
            .allowsHitTesting(false)
            if let bubble {
                // The bubble sits just above Merry's head rather than at the top of
                // the window, so it reads as his and grows upwards when the text is long.
                PetBubbleView(bubble: bubble, pressed: model.pressedButton, still: reduceMotion) { model.press($0) }
                    .id(bubble.key)
                    .padding(.bottom, 100)
            }
            PetBursts(bursts: model.bursts)
                .allowsHitTesting(false)
            if model.dropping {
                PetDropHint(still: reduceMotion)
                    .allowsHitTesting(false)
            }
            // The mouse is handled in one place, above everything: the creature,
            // the bubble and its buttons are told apart by where the pointer is.
            PetMouseCatcher(model: model)
        }
        .frame(width: PetLayout.width, height: PetLayout.height)
        .coordinateSpace(name: PetBubbleView.space)
        .onPreferenceChange(PetBubbleFrameKey.self) { model.layout(bubble: $0.bubble, buttons: $0.buttons) }
        .offset(y: slide)
        .opacity(fade)
        .onAppear {
            model.reduceMotion = reduceMotion
            model.start()
        }
        .onChange(of: reduceMotion) { _, value in model.reduceMotion = value }
        .onChange(of: model.presence) { _, value in slideFor(value) }
    }

    /// Slides up on arrival, down on leaving.
    private func slideFor(_ presence: PetModel.Presence?) {
        switch presence {
        case .arriving:
            if reduceMotion { slide = 0; fade = 1; return }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { slide = 70; fade = 0 }
            DispatchQueue.main.async {
                withAnimation(.timingCurve(0.3, 1.4, 0.5, 1, duration: 0.38)) { slide = 0 }
                withAnimation(.timingCurve(0.3, 1, 0.5, 1, duration: 0.228)) { fade = 1 }
            }
        case .leaving:
            if reduceMotion { slide = 70; fade = 0; return }
            withAnimation(.timingCurve(0.5, 0, 0.75, 0, duration: 0.26)) { slide = 70; fade = 0 }
        case nil:
            slide = 0; fade = 1
        }
    }
}

// MARK: - The bubble

/// Where the bubble and each of its buttons are, in window coordinates.
struct PetBubbleFrames: Equatable {
    var bubble: CGRect?
    var buttons: [Int: CGRect] = [:]
}

struct PetBubbleFrameKey: PreferenceKey {
    static let defaultValue = PetBubbleFrames()
    static func reduce(value: inout PetBubbleFrames, nextValue: () -> PetBubbleFrames) {
        let next = nextValue()
        value.bubble = next.bubble ?? value.bubble
        value.buttons.merge(next.buttons) { _, new in new }
    }
}

/// A dark pill with pixel lettering and a little tail pointing at Merry.
struct PetBubbleView: View {
    static let space = "pet"
    static let ink = Color(hex: "#f3f4ef")

    var bubble: PetBubble
    /// The button the mouse is holding down, if any.
    var pressed: Int?
    var still: Bool
    var press: (PetBubble.Button) -> Void
    @State private var shown = false

    private var border: Color {
        switch bubble.tone {
        case .plain: return Color(hex: "#ffffff1f")
        case .chat: return Color(hex: "#ffffff2e")
        case .good: return Color(hex: "#d4ff3a4d")
        case .bad: return Color(hex: "#ff5a4e59")
        case .ask, .reminder: return Color(hex: "#ffb23e66")
        case .peek: return Color(hex: "#d4ff3a40")
        }
    }

    private var fill: Color { Color(hex: bubble.tone == .chat ? "#16161af2" : "#101012f0") }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if bubble.pulse { PetPulse(still: still) }
            Text(bubble.text)
                .font(MerryResources.pixelFont())
                .foregroundStyle(Self.ink)
                .lineSpacing(0.7)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 20)
            if !bubble.buttons.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(bubble.buttons.enumerated()), id: \.offset) { index, button in
                        PetBubbleButton(label: button.label, primary: index == 0, pressed: pressed == index)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: PetBubbleFrameKey.self, value: PetBubbleFrames(buttons: [index: geometry.frame(in: .named(Self.space))]))
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { press(button) }
                    }
                }
                .fixedSize()
            }
        }
        // The reference's padding plus its one-point border.
        .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 11))
        .background(alignment: .bottom) { backing }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PetBubbleFrameKey.self, value: PetBubbleFrames(bubble: geometry.frame(in: .named(Self.space))))
        })
        .frame(maxWidth: 244)
        .scaleEffect(shown || still ? 1 : 0.92)
        .offset(y: shown || still ? 0 : 6)
        .opacity(shown || still ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.3, 1.3, 0.5, 1, duration: 0.22)) { shown = true }
        }
        .accessibilityElement(children: .contain)
    }

    private var backing: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack(alignment: .bottom) {
            // A hard, unblurred drop shadow, as pixel art has.
            shape.fill(Color(hex: "#00000077")).offset(x: 3, y: 3)
            shape.fill(fill)
            shape.strokeBorder(border, lineWidth: 1)
            // The top edge catches a little light.
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex: "#ffffff12")).frame(height: 1).padding(.top, 1).padding(.horizontal, 4)
                Spacer(minLength: 0)
            }
            PetBubbleTail(fill: Color(hex: "#101012"), border: border)
                .frame(width: 13, height: 7)
                .offset(y: 6)
        }
    }
}

/// The tail: a 9-point square turned 45 degrees, half tucked into the bubble.
private struct PetBubbleTail: View {
    var fill: Color
    var border: Color

    var body: some View {
        Canvas { context, size in
            let mid = size.width / 2
            var wedge = Path()
            wedge.move(to: CGPoint(x: mid - 6.36, y: 0))
            wedge.addLine(to: CGPoint(x: mid, y: 6.36))
            wedge.addLine(to: CGPoint(x: mid + 6.36, y: 0))
            context.fill(wedge, with: .color(fill))
            var edge = Path()
            edge.move(to: CGPoint(x: mid - 5.86, y: 0.5))
            edge.addLine(to: CGPoint(x: mid, y: 5.86))
            edge.addLine(to: CGPoint(x: mid + 5.86, y: 0.5))
            context.stroke(edge, with: .color(border), lineWidth: 1)
        }
    }
}

/// The lime dot beside a status line while Merry works.
private struct PetPulse: View {
    var still: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            let k = PetEasing.ease(phase < 0.5 ? phase * 2 : (1 - phase) * 2)
            Circle().fill(Color(hex: PetFace.gold)).frame(width: 6, height: 6).opacity(still ? 1 : 0.35 + 0.65 * k)
        }
        .frame(width: 6, height: 6)
    }
}

/// Lime, upper-case, and it sinks two points when pressed. A second button is quiet.
struct PetBubbleButton: View {
    var label: String
    var primary: Bool
    var pressed: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1)
            .textCase(.uppercase)
            .lineLimit(1)
            .frame(height: 10)
            .foregroundStyle(primary ? Color(hex: "#0b0b0c") : PetBubbleView.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    if primary && !pressed { RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#6f8a12")).offset(y: 2) }
                    RoundedRectangle(cornerRadius: 5).fill(primary ? Color(hex: PetFace.gold) : Color(hex: "#ffffff0f"))
                }
            }
            .offset(y: pressed ? 2 : 0)
    }
}

/// Shown under the creature while files hover over it.
private struct PetDropHint: View {
    var still: Bool
    @State private var shown = false

    var body: some View {
        Text("drop it")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .textCase(.uppercase)
            .frame(height: 10)
            .foregroundStyle(Color(hex: "#0b0b0c"))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: PetFace.gold)))
            .fixedSize()
            .scaleEffect(shown || still ? 1 : 0.92)
            .offset(y: shown || still ? 0 : 6)
            .opacity(shown || still ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.2)) { shown = true } }
    }
}

// MARK: - Movement

enum PetEasing {
    static let hop = CubicBezier(0.2, 0.8, 0.2, 1)
    static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)
    static func ease(_ x: Double) -> Double { easeInOut(x) }

    /// The value at `phase` (0...1) of keyframes given as (offset, value), easing between each pair.
    static func keyframes(_ frames: [(Double, Double)], at phase: Double, easing: CubicBezier) -> Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if phase <= first.0 { return first.1 }
        for i in 1..<frames.count where phase <= frames[i].0 {
            let a = frames[i - 1], b = frames[i]
            let span = b.0 - a.0
            return a.1 + (b.1 - a.1) * easing(span > 0 ? (phase - a.0) / span : 1)
        }
        return last.1
    }
}

/// The hop and the dance, turning about the creature's feet.
struct PetMotion<Content: View>: View {
    static var hopSeconds: Double { 0.62 }
    static var danceSeconds: Double { 0.85 }

    var dancing: Bool
    var hops: Int
    var still: Bool
    @ViewBuilder var content: () -> Content
    @State private var hopStart: Date?
    @State private var danceStart = Date()

    var body: some View {
        TimelineView(.animation(paused: still || (!dancing && hopStart == nil))) { context in
            let pose = pose(at: context.date)
            content()
                .scaleEffect(x: pose.sx, y: pose.sy, anchor: .bottom)
                .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
                .offset(y: pose.dy)
        }
        .onChange(of: hops) { _, _ in
            guard !still else { return }
            let started = Date()
            hopStart = started
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hopSeconds + 0.05) {
                if hopStart == started { hopStart = nil }
            }
        }
        .onChange(of: dancing) { _, on in if on { danceStart = Date() } }
    }

    private func pose(at date: Date) -> Pose {
        if still { return Pose() }
        if dancing {
            let phase = (date.timeIntervalSince(danceStart) / Self.danceSeconds).truncatingRemainder(dividingBy: 1)
            return Pose(dy: PetEasing.keyframes([(0, 0), (0.25, -8), (0.5, 0), (0.75, -6), (1, 0)], at: phase, easing: PetEasing.easeInOut),
                        rotation: PetEasing.keyframes([(0, -9), (0.25, 9), (0.5, -9), (0.75, 9), (1, -9)], at: phase, easing: PetEasing.easeInOut))
        }
        guard let hopStart else { return Pose() }
        let phase = date.timeIntervalSince(hopStart) / Self.hopSeconds
        if phase >= 1 { return Pose() }
        return Pose(dy: PetEasing.keyframes([(0, 0), (0.42, -9), (0.82, 0), (1, 0)], at: phase, easing: PetEasing.hop),
                    sx: PetEasing.keyframes([(0, 1), (0.42, 0.97), (0.82, 1.08), (1, 1)], at: phase, easing: PetEasing.hop),
                    sy: PetEasing.keyframes([(0, 1), (0.42, 1.04), (0.82, 0.92), (1, 1)], at: phase, easing: PetEasing.hop))
    }
}

/// Hearts and sparks flying out from the creature.
struct PetBursts: View {
    static var seconds: Double { 1.1 }
    var bursts: [PetBurst]

    var body: some View {
        TimelineView(.animation(paused: bursts.isEmpty)) { context in
            Canvas { canvas, _ in
                for burst in bursts {
                    let elapsed = context.date.timeIntervalSince(burst.started)
                    for i in 0..<burst.count { draw(&canvas, burst, i, elapsed) }
                }
            }
        }
        .frame(width: PetLayout.width, height: PetLayout.height)
    }

    private func draw(_ canvas: inout GraphicsContext, _ burst: PetBurst, _ index: Int, _ elapsed: Double) {
        let p = PetLogic.particle(index, of: burst.count)
        let phase = (elapsed - p.delayMs / 1000) / Self.seconds
        guard phase > 0, phase < 1 else { return }
        let ease = PetEasing.hop
        let travel = PetEasing.keyframes([(0, 0), (0.65, 0.85), (1, 1)], at: phase, easing: ease)
        let spin = PetEasing.keyframes([(0, 0), (0.65, 0.6), (1, 1)], at: phase, easing: ease) * p.spin
        let scale = PetEasing.keyframes([(0, 0.6), (0.65, 1), (1, 0.2)], at: phase, easing: ease)
        let opacity = PetEasing.keyframes([(0, 0), (0.12, 1), (0.65, 1), (1, 0)], at: phase, easing: ease)
        let color = Color(hex: burst.color)
        canvas.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: PetLayout.burstOrigin.x + p.dx * travel, y: PetLayout.burstOrigin.y + p.dy * travel)
            layer.rotate(by: .degrees(spin))
            layer.scaleBy(x: scale, y: scale)
            switch burst.kind {
            case .sparks:
                layer.addFilter(.shadow(color: color, radius: 4))
                layer.fill(Path(roundedRect: CGRect(x: -3, y: -3, width: 6, height: 6), cornerRadius: 1.5), with: .color(color))
            case .hearts:
                layer.addFilter(.shadow(color: Color(hex: "#ff6fa866"), radius: 4))
                layer.draw(Text("♥").font(.system(size: 17)).foregroundColor(color), at: .zero, anchor: .center)
            }
        }
    }
}

// MARK: - The mouse

/// Turns AppKit's coordinates into the top-left ones the pet thinks in.
@MainActor
final class PetMouseView: NSView {
    weak var model: PetModel?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    // The pet never takes focus, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private var screen: CGPoint { PetScreenSpace.point(NSEvent.mouseLocation) }
    private var primaryDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    override func mouseDown(with event: NSEvent) {
        let pressedAt = Date().addingTimeInterval(event.timestamp - ProcessInfo.processInfo.systemUptime)
        model?.mouseDown(local: local(event), screen: screen, pressedAt: pressedAt)
    }
    override func mouseMoved(with event: NSEvent) { model?.mouseMoved(local: local(event), screen: screen, primaryDown: primaryDown) }
    override func mouseDragged(with event: NSEvent) { model?.mouseMoved(local: local(event), screen: screen, primaryDown: true) }
    override func mouseUp(with event: NSEvent) { model?.mouseUp(local: local(event)) }
    override func mouseExited(with event: NSEvent) { model?.mouseLeft(primaryDown: primaryDown) }
    override func rightMouseDown(with event: NSEvent) { model?.contextMenu() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        model?.dragEntered()
        model?.dragOver()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        model?.dragOver()
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { model?.dragLeft() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        model?.drop(urls.map(\.path))
        return true
    }
}

private struct PetMouseCatcher: NSViewRepresentable {
    var model: PetModel

    func makeNSView(context: Context) -> PetMouseView {
        let view = PetMouseView(frame: .zero)
        view.model = model
        return view
    }

    func updateNSView(_ view: PetMouseView, context: Context) { view.model = model }
}
