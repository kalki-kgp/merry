import SwiftUI
import MerryCore

/// A running focus timer turns Merry's face into a clock that shows it.
public struct SpriteTimer: Equatable, Sendable {
    public var remainingMs: Double
    public var progress: Double
    /// running | paused | ringing
    public var status: String
    public init(remainingMs: Double, progress: Double, status: String) {
        self.remainingMs = remainingMs; self.progress = progress; self.status = status
    }
}

extension Color {
    /// A colour from "#rrggbb" or "#rrggbbaa".
    init(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        if text.count == 8 {
            self.init(.sRGB, red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255, blue: Double((value >> 8) & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
        } else {
            self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: 1)
        }
    }
}

/// How the body sits at one instant: a little bob, tilt or squash.
struct Pose {
    var dx = 0.0, dy = 0.0, rotation = 0.0, sx = 1.0, sy = 1.0
}

/// The moods' body language. Every mood either holds a pose or loops a short
/// movement; a few play a movement a fixed number of times and then rest.
enum BodyMotion {
    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    /// Interpolates between keyframes given as (offset 0...1, pose).
    private static func keyframes(_ frames: [(Double, Pose)], at phase: Double, linear: Bool = false) -> Pose {
        guard let first = frames.first else { return Pose() }
        if phase <= first.0 { return first.1 }
        for i in 1..<frames.count where phase <= frames[i].0 {
            let a = frames[i - 1], b = frames[i]
            let span = b.0 - a.0
            let raw = span > 0 ? (phase - a.0) / span : 1
            let k = linear ? raw : easeInOut(raw)
            return Pose(dx: a.1.dx + (b.1.dx - a.1.dx) * k, dy: a.1.dy + (b.1.dy - a.1.dy) * k, rotation: a.1.rotation + (b.1.rotation - a.1.rotation) * k,
                        sx: a.1.sx + (b.1.sx - a.1.sx) * k, sy: a.1.sy + (b.1.sy - a.1.sy) * k)
        }
        return frames[frames.count - 1].1
    }

    private static func loop(_ seconds: Double, _ elapsed: Double, times: Int? = nil) -> Double? {
        if let times, elapsed >= seconds * Double(times) { return nil }
        return (elapsed / seconds).truncatingRemainder(dividingBy: 1)
    }

    private static let hop: [(Double, Pose)] = [(0, Pose()), (0.45, Pose(dy: -9)), (1, Pose())]
    private static let nod: [(Double, Pose)] = [(0, Pose()), (0.3, Pose(rotation: -4)), (0.7, Pose(rotation: 4)), (1, Pose())]
    private static func float(_ period: Double, _ elapsed: Double) -> Pose {
        keyframes([(0, Pose()), (0.5, Pose(dy: -3)), (1, Pose())], at: loop(period, elapsed)!)
    }

    static func pose(_ mood: Mood, elapsed: Double) -> Pose {
        switch mood {
        case .excited: return keyframes(hop, at: loop(0.5, elapsed)!)
        case .proud: return loop(0.8, elapsed, times: 3).map { keyframes(hop, at: $0) } ?? Pose()
        case .happy: return keyframes(nod, at: loop(1.4, elapsed)!)
        case .curious: return Pose(rotation: -6)
        case .listening: return Pose(dy: -2)
        case .waiting:
            return keyframes([(0, Pose(rotation: -5)), (0.72, Pose(rotation: -5)), (0.82, Pose(dy: -6, rotation: -5)), (1, Pose(rotation: -5))], at: loop(2.4, elapsed)!)
        case .straining: return keyframes([(0, Pose()), (0.5, Pose(dx: 0.7)), (1, Pose())], at: loop(0.12, elapsed)!, linear: true)
        case .sad: return Pose(dy: 3, rotation: 4)
        case .oops: return loop(0.5, elapsed, times: 2).map { keyframes(nod, at: $0) } ?? Pose()
        case .sleepy: return Pose(dy: 3, rotation: -5)
        case .dizzy: return keyframes([(0, Pose(rotation: -8)), (0.5, Pose(rotation: 8)), (1, Pose(rotation: -8))], at: loop(0.5, elapsed)!)
        case .love: return keyframes([(0, Pose()), (0.5, Pose(sx: 1.05, sy: 1.05)), (1, Pose())], at: loop(0.7, elapsed)!)
        case .surprised: return loop(0.4, elapsed, times: 1).map { keyframes(hop, at: $0) } ?? Pose()
        case .wink: return Pose(rotation: 3)
        case .wave: return keyframes(nod, at: loop(0.9, elapsed)!)
        case .laugh: return keyframes([(0, Pose(rotation: -3)), (0.5, Pose(dy: -2, rotation: 3)), (1, Pose(rotation: -3))], at: loop(0.28, elapsed)!)
        case .shy: return Pose(dy: 2, rotation: -7)
        case .bored: return float(7, elapsed)
        case .yawn:
            return keyframes([(0, Pose()), (0.45, Pose(dy: -2, sx: 0.97, sy: 1.07)), (0.7, Pose(sx: 1.03, sy: 0.96)), (1, Pose())], at: loop(2.3, elapsed)!)
        case .cool: return Pose(rotation: -3)
        case .starstruck: return keyframes(hop, at: loop(0.6, elapsed)!)
        case .music: return keyframes([(0, Pose(rotation: -4)), (0.5, Pose(dy: -3, rotation: 4)), (1, Pose(rotation: -4))], at: loop(0.84, elapsed)!)
        case .reading: return Pose(dy: 1, rotation: 2)
        case .skeptical: return Pose(rotation: 5)
        case .nervous: return keyframes([(0, Pose()), (0.5, Pose(dx: 0.7)), (1, Pose())], at: loop(0.09, elapsed)!, linear: true)
        case .celebrate: return keyframes(hop, at: loop(0.45, elapsed)!)
        case .kiss: return keyframes([(0, Pose()), (0.5, Pose(sx: 1.05, sy: 1.05)), (1, Pose())], at: loop(1, elapsed)!)
        case .pout: return Pose(dy: 2, rotation: -3)
        case .sneeze:
            return keyframes([(0, Pose()), (0.6, Pose()), (0.7, Pose(dy: -2, rotation: -6)), (0.78, Pose(dy: 2, rotation: 8)), (0.9, Pose()), (1, Pose())], at: loop(1.98, elapsed)!)
        case .determined: return Pose(dy: -2)
        case .idle, .thinking, .working: return float(4.5, elapsed)
        }
    }

    /// Whether the pose changes over time, so a still mood need not redraw.
    static func moves(_ mood: Mood) -> Bool {
        switch mood {
        case .curious, .listening, .sad, .sleepy, .wink, .shy, .cool, .reading, .skeptical, .pout, .determined: return false
        default: return true
        }
    }

    /// The bell's slow pulse: quicker while working, slower asleep.
    static func ledOpacity(_ mood: Mood, elapsed: Double) -> Double {
        let period: Double = mood == .working || mood == .straining ? 0.5 : mood == .sleepy ? 4 : 2.4
        let phase = (elapsed / period).truncatingRemainder(dividingBy: 1)
        let k = phase < 0.5 ? easeInOut(phase * 2) : easeInOut((1 - phase) * 2)
        return 0.35 + 0.65 * k
    }

    static func smooth(_ x: Double) -> Double { easeInOut(min(1, max(0, x))) }
}

/// Merry itself: a small lamb, drawn in a
/// 120 × 112 box and scaled to `size` points wide.
public struct SpriteView: View {
    public var state: PetState
    public var mood: Mood?
    public var size: CGFloat
    public var look: Look
    /// No bobbing, no blinking, no floor glow: for small, still uses like the menu.
    public var quiet: Bool
    public var timer: SpriteTimer?

    @State private var moodSince = Date()
    @State private var shownMood: Mood?
    @State private var blinking = false
    @State private var blinkTask: Task<Void, Never>?
    /// When the clock last switched on or off, to fade between face and clock.
    @State private var tvChanged = Date.distantPast
    @State private var tvOn = false
    @State private var lastTimer: SpriteTimer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowVisible) private var windowVisible

    public init(state: PetState, mood: Mood? = nil, size: CGFloat = 116, look: Look = Look(), quiet: Bool = false, timer: SpriteTimer? = nil) {
        self.state = state; self.mood = mood; self.size = size; self.look = look; self.quiet = quiet; self.timer = timer
        // A sprite that starts life with a timer starts as the clock, with no fade.
        _tvOn = State(initialValue: timer != nil)
        _lastTimer = State(initialValue: timer)
    }

    private var current: Mood { mood ?? Mood.forState(state) }

    public var body: some View {
        let mood = current
        let still = quiet || reduceMotion
        // A mood that neither moves nor changes frames only needs to redraw for the bell.
        // Slow movements (the idle float) need few frames; quick ones (a buzz, a
        // hop) and the clock's fade need more. Redrawing a blurred canvas sixty
        // times a second for a pet that is barely moving costs real CPU.
        let quick: Set<Mood> = [.straining, .nervous, .laugh, .dizzy, .excited, .celebrate, .starstruck, .surprised, .oops]
        let changing = Date().timeIntervalSince(tvChanged) < 1
        let interval: Double = still ? 1 : (changing || quick.contains(mood)) ? 1.0 / 30 : BodyMotion.moves(mood) || timer != nil ? 1.0 / 15 : 1.0 / 6
        TimelineView(.animation(minimumInterval: interval, paused: !windowVisible || (still && PetFace.frameMs(mood) == nil && timer == nil))) { context in
            Canvas { ctx, canvasSize in
                draw(&ctx, canvasSize, mood: mood, now: context.date, still: still)
            }
        }
        .frame(width: size, height: size * 112 / 120)
        .accessibilityElement()
        .accessibilityLabel(timer.map { "Merry timer \(DotText.clock($0.remainingMs)), \($0.status)" } ?? "Merry is \(state.rawValue)")
        .onChange(of: mood) { _, _ in moodSince = Date() }
        .onChange(of: timer != nil) { _, on in
            tvOn = on
            tvChanged = Date()
        }
        .onChange(of: timer) { _, value in if let value { lastTimer = value } }
        .onAppear {
            moodSince = Date()
            startBlinking()
        }
        .onDisappear { blinkTask?.cancel() }
    }

    /// Blinks at a human rhythm: irregular, occasionally twice.
    private func startBlinking() {
        blinkTask?.cancel()
        guard !quiet else { return }
        blinkTask = Task { @MainActor in
            func pause(_ ms: Double) async -> Bool { (try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))) != nil }
            while !Task.isCancelled {
                guard await pause(2200 + Double.random(in: 0..<4200)) else { return }
                blinking = true
                guard await pause(120) else { return }
                blinking = false
                if Double.random(in: 0..<1) < 0.2 {
                    guard await pause(150) else { return }
                    blinking = true
                    guard await pause(110) else { return }
                    blinking = false
                }
            }
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ canvasSize: CGSize, mood: Mood, now: Date, still: Bool) {
        let scale = canvasSize.width / 120
        ctx.scaleBy(x: scale, y: scale)
        let elapsed = now.timeIntervalSince(moodSince)
        let accent = Color(hex: PetFace.accent(mood))
        let frame = PetFace.frameMs(mood).map { still ? 0 : Int(elapsed * 1000 / Double($0)) } ?? 0

        // How far the clock has taken over from the face, 0...1.
        let since = now.timeIntervalSince(tvChanged)
        let tv = reduceMotion ? (tvOn ? 1.0 : 0.0) : (tvOn ? BodyMotion.smooth(since / 0.5) : 1 - BodyMotion.smooth(since / 0.35))
        let showTV = tv > 0.001 && (timer ?? lastTimer) != nil

        if !quiet {
            let breath = still ? 0 : (elapsed / 4.5).truncatingRemainder(dividingBy: 1)
            let k = breath < 0.5 ? BodyMotion.smooth(breath * 2) : BodyMotion.smooth((1 - breath) * 2)
            let rx = 40 * (1 - 0.1 * k)
            let glow = Path(ellipseIn: CGRect(x: 60 - rx, y: 98, width: rx * 2, height: 12))
            ctx.drawLayer { layer in
                layer.opacity = 0.9 - 0.3 * k
                layer.fill(glow, with: .radialGradient(Gradient(colors: [accent.opacity(0.55), accent.opacity(0)]), center: CGPoint(x: 60, y: 104), startRadius: 0, endRadius: rx))
            }
        }

        if tv < 0.999 {
            ctx.drawLayer { layer in
                let pose = still || showTV ? Pose() : BodyMotion.pose(mood, elapsed: elapsed)
                // Everything turns and squashes about the feet.
                layer.translateBy(x: 60 + pose.dx, y: 96 + pose.dy)
                layer.rotate(by: .degrees(pose.rotation))
                layer.scaleBy(x: pose.sx * (1 - 0.1 * tv), y: pose.sy * (1 - 0.25 * tv))
                layer.translateBy(x: -60, y: -96)
                layer.opacity = 1 - tv
                drawLamb(&layer, mood: mood, frame: frame, accent: accent, bell: still ? 1 : BodyMotion.ledOpacity(mood, elapsed: elapsed))
            }
        }

        if showTV, let timer = timer ?? lastTimer {
            ctx.drawLayer { layer in
                layer.translateBy(x: 60, y: 96)
                layer.scaleBy(x: 0.84 + 0.16 * tv, y: 0.7 + 0.3 * tv)
                layer.translateBy(x: -60, y: -96 + 5 * (1 - tv))
                layer.opacity = tv
                drawClock(&layer, timer: timer, now: now)
            }
        }
    }

    // MARK: The lamb

    private static let hide = Color(hex: "#3b2e2a")
    private static let cream = Color(hex: "#fffdf6")
    private static let horn = Color(hex: "#f0b548")

    /// A cloud: an oval ringed with round tufts.
    static func cloud(center: CGPoint, rx: Double, ry: Double, tuft: Double, count: Int) -> SwiftUI.Path {
        var path = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
            let x = center.x + cos(angle) * rx, y = center.y + sin(angle) * ry
            path.addEllipse(in: CGRect(x: x - tuft, y: y - tuft, width: tuft * 2, height: tuft * 2))
        }
        return path
    }

    private func tilted(_ rect: CGRect, degrees: Double) -> SwiftUI.Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let turn = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: degrees * .pi / 180).translatedBy(x: -centre.x, y: -centre.y)
        return Path(ellipseIn: rect).applying(turn)
    }

    private func line(_ points: [(Double, Double)]) -> SwiftUI.Path {
        var path = Path()
        for (i, p) in points.enumerated() {
            if i == 0 { path.move(to: CGPoint(x: p.0, y: p.1)) } else { path.addLine(to: CGPoint(x: p.0, y: p.1)) }
        }
        return path
    }

    private func curve(_ from: (Double, Double), _ control: (Double, Double), _ to: (Double, Double)) -> SwiftUI.Path {
        var path = Path()
        path.move(to: CGPoint(x: from.0, y: from.1))
        path.addQuadCurve(to: CGPoint(x: to.0, y: to.1), control: CGPoint(x: control.0, y: control.1))
        return path
    }

    private func glyph(_ ctx: inout GraphicsContext, _ text: String, _ size: Double, _ color: Color, at point: CGPoint) {
        ctx.draw(Text(text).font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(color), at: point)
    }

    /// Wool, legs, ears, horns and bell: everything but what is on the face.
    private func drawBody(_ ctx: inout GraphicsContext, accent: Color, bell: Double, faceRect: CGRect) {
        for x in [45.0, 67.0] {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: 82, width: 8, height: 17), cornerRadius: 3.5), with: .color(Self.hide))
        }
        let wool = Self.cloud(center: CGPoint(x: 60, y: 56), rx: 33, ry: 24, tuft: 13, count: 11)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 5))
            layer.fill(wool, with: .linearGradient(
                Gradient(stops: [.init(color: Self.cream, location: 0), .init(color: Color(hex: "#f3ead9"), location: 0.6), .init(color: Color(hex: "#d9cbb4"), location: 1)]),
                startPoint: CGPoint(x: 60, y: 19), endPoint: CGPoint(x: 60, y: 93)))
        }

        // Ears droop out from behind the face; horns curl above them.
        for (x, degrees) in [(27.0, -24.0), (75.0, 24.0)] {
            ctx.fill(tilted(CGRect(x: x, y: 47, width: 18, height: 10), degrees: degrees), with: .color(Self.hide))
            ctx.fill(tilted(CGRect(x: x + 4, y: 49.5, width: 10, height: 5), degrees: degrees), with: .color(Color(hex: "#e89aa0")))
        }
        for side in [-1.0, 1.0] {
            var outer = Path()
            outer.addArc(center: CGPoint(x: 60 + side * 24, y: 33), radius: 8.5, startAngle: .degrees(side < 0 ? 20 : 160), endAngle: .degrees(side < 0 ? 250 : -70), clockwise: side > 0)
            ctx.stroke(outer, with: .color(Self.horn), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            var inner = Path()
            inner.addArc(center: CGPoint(x: 60 + side * 24, y: 33), radius: 8.5, startAngle: .degrees(side < 0 ? 60 : 120), endAngle: .degrees(side < 0 ? 200 : -20), clockwise: side > 0)
            ctx.stroke(inner, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }

        ctx.fill(Path(ellipseIn: faceRect), with: .linearGradient(
            Gradient(colors: [Color(hex: "#4a3a35"), Color(hex: "#2c211e")]),
            startPoint: CGPoint(x: 60, y: faceRect.minY), endPoint: CGPoint(x: 60, y: faceRect.maxY)))

        // A fringe of wool over the forehead.
        var fringe = Path()
        for (x, y, r) in [(49.0, 39.0, 8.0), (60, 36, 9.5), (71, 39, 8)] { fringe.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
        ctx.fill(fringe, with: .color(Self.cream))

        // The bell glows in the colour of the mood.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.5))
            layer.fill(Path(ellipseIn: CGRect(x: 54, y: 79, width: 12, height: 12)), with: .color(accent.opacity(0.6 * bell)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: 55, y: 80, width: 10, height: 10)), with: .color(accent))
        ctx.fill(Path(ellipseIn: CGRect(x: 57, y: 81.5, width: 3, height: 2.4)), with: .color(.white.opacity(0.7)))
        ctx.fill(Path(roundedRect: CGRect(x: 57.5, y: 86, width: 5, height: 1.6), cornerRadius: 0.8), with: .color(Self.hide.opacity(0.75)))
    }

    private func drawEye(_ ctx: inout GraphicsContext, _ eye: PetFace.Eye, at c: CGPoint, left: Bool, accent: Color) {
        let stroke = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        let x = Double(c.x), y = Double(c.y)
        switch eye {
        case .open: ctx.fill(Path(ellipseIn: CGRect(x: x - 3.3, y: y - 4.4, width: 6.6, height: 8.8)), with: .color(Self.cream))
        case .wide:
            ctx.fill(Path(ellipseIn: CGRect(x: x - 4.8, y: y - 5.4, width: 9.6, height: 10.8)), with: .color(Self.cream))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Self.hide))
        case .narrow: ctx.fill(Path(roundedRect: CGRect(x: x - 4, y: y - 2, width: 8, height: 4.4), cornerRadius: 2.2), with: .color(Self.cream))
        case .shut: ctx.stroke(line([(x - 4, y + 1), (x + 4, y + 1)]), with: .color(Self.cream), style: stroke)
        case .happy: ctx.stroke(curve((x - 4.2, y + 2), (x, y - 5.5), (x + 4.2, y + 2)), with: .color(Self.cream), style: stroke)
        case .droop:
            ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 2.5, width: 6, height: 7)), with: .color(Self.cream))
            let inner = left ? 1.0 : -1.0
            ctx.stroke(line([(x - inner * 5, y - 4), (x + inner * 4.5, y - 8)]), with: .color(Self.cream), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        case .squeezeLeft: ctx.stroke(line([(x - 3.5, y - 3.5), (x + 3, y), (x - 3.5, y + 3.5)]), with: .color(Self.cream), style: stroke)
        case .squeezeRight: ctx.stroke(line([(x + 3.5, y - 3.5), (x - 3, y), (x + 3.5, y + 3.5)]), with: .color(Self.cream), style: stroke)
        case .cross:
            ctx.stroke(line([(x - 3.5, y - 3.5), (x + 3.5, y + 3.5)]), with: .color(Self.cream), style: stroke)
            ctx.stroke(line([(x + 3.5, y - 3.5), (x - 3.5, y + 3.5)]), with: .color(Self.cream), style: stroke)
        case .heart: glyph(&ctx, "♥", 12, accent, at: c)
        case .star: glyph(&ctx, "★", 11, accent, at: c)
        case .half:
            var lid = Path()
            lid.move(to: CGPoint(x: x + 3.6, y: y))
            lid.addArc(center: CGPoint(x: x, y: y), radius: 3.6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            lid.closeSubpath()
            ctx.fill(lid, with: .color(Self.cream))
            ctx.stroke(line([(x - 4.4, y), (x + 4.4, y)]), with: .color(Self.cream), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        case .hidden: break
        }
    }

    private func drawMouth(_ ctx: inout GraphicsContext, _ mouth: PetFace.Mouth, at c: CGPoint, accent: Color) {
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        let x = Double(c.x), y = Double(c.y)
        switch mouth {
        case .smile: ctx.stroke(curve((x - 5, y - 1), (x, y + 4.5), (x + 5, y - 1)), with: .color(Self.cream), style: stroke)
        case .grin:
            var path = curve((x - 6, y - 1.5), (x, y + 9.5), (x + 6, y - 1.5))
            path.closeSubpath()
            ctx.fill(path, with: .color(Self.cream))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.4, y: y + 1.2, width: 4.8, height: 2.6)), with: .color(Color(hex: "#e89aa0")))
        case .small: ctx.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: y - 1, width: 3.6, height: 3.6)), with: .color(Self.cream))
        case .round: ctx.fill(Path(ellipseIn: CGRect(x: x - 3.6, y: y - 3, width: 7.2, height: 8.4)), with: .color(Self.cream))
        case .flat: ctx.stroke(line([(x - 4, y + 1), (x + 4, y + 1)]), with: .color(Self.cream), style: stroke)
        case .frown: ctx.stroke(curve((x - 5, y + 3), (x, y - 2.5), (x + 5, y + 3)), with: .color(Self.cream), style: stroke)
        case .wobble: ctx.stroke(line([(x - 6, y + 2), (x - 3, y - 1), (x, y + 2), (x + 3, y - 1), (x + 6, y + 2)]), with: .color(Self.cream), style: stroke)
        case .smirk: ctx.stroke(curve((x - 4, y + 1), (x + 2, y + 4), (x + 6, y - 2)), with: .color(Self.cream), style: stroke)
        case .kiss:
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 1.2, width: 4.4, height: 4.4)), with: .color(accent))
        case .none: break
        }
    }

    private func drawLamb(_ ctx: inout GraphicsContext, mood: Mood, frame: Int, accent: Color, bell: Double) {
        drawBody(&ctx, accent: accent, bell: bell, faceRect: CGRect(x: 36, y: 40, width: 48, height: 39))
        let f = PetFace.features(mood, t: frame, blinking: blinking)
        let gaze = f.tracks ? look : f.gaze
        let dx = max(-1, min(1, gaze.x)) * 2.2, dy = max(-1, min(1, gaze.y)) * 1.6
        let cream = Self.cream

        if f.blush {
            for x in [41.0, 72.0] { ctx.fill(Path(ellipseIn: CGRect(x: x, y: 63, width: 7, height: 4)), with: .color(Color(hex: PetFace.pink).opacity(0.75))) }
        }
        drawEye(&ctx, f.left, at: CGPoint(x: 50 + dx, y: 57 + dy), left: true, accent: accent)
        drawEye(&ctx, f.right, at: CGPoint(x: 70 + dx, y: 57 + dy), left: false, accent: accent)
        drawMouth(&ctx, f.mouth, at: CGPoint(x: 60 + (f.tracks ? dx * 0.5 : 0), y: 68), accent: accent)

        let brow = StrokeStyle(lineWidth: 1.8, lineCap: .round)
        switch f.brows {
        case .set:
            ctx.stroke(line([(45, 48.5), (54, 51)]), with: .color(cream), style: brow)
            ctx.stroke(line([(75, 48.5), (66, 51)]), with: .color(cream), style: brow)
        case .cross:
            ctx.stroke(line([(45, 47), (54, 51.5)]), with: .color(cream), style: brow)
            ctx.stroke(line([(75, 47), (66, 51.5)]), with: .color(cream), style: brow)
        case .raised: ctx.stroke(curve((65.5, 49), (70, 45), (75, 47.5)), with: .color(cream), style: brow)
        case .none: break
        }
        if f.shades {
            var lenses = Path(roundedRect: CGRect(x: 42, y: 52, width: 15, height: 9), cornerRadius: 3.5)
            lenses.addRoundedRect(in: CGRect(x: 63, y: 52, width: 15, height: 9), cornerSize: CGSize(width: 3.5, height: 3.5))
            ctx.fill(lenses, with: .color(Color(hex: "#0c0c10")))
            ctx.stroke(lenses, with: .color(accent), lineWidth: 1.2)
            ctx.stroke(line([(57, 55), (63, 55)]), with: .color(accent), lineWidth: 1.2)
            ctx.stroke(line([(45, 55), (48, 54)]), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        if f.tears {
            let drop = Double(frame % 3) * 2
            for x in [46.0, 74.0] { ctx.fill(Path(ellipseIn: CGRect(x: x - 1.4, y: 63 + drop, width: 2.8, height: 4)), with: .color(Color(hex: PetFace.sky))) }
        }
        if f.sweat {
            let drop = Double(frame % 3) * 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: 86, y: 34 + drop, width: 4, height: 6)), with: .color(Color(hex: PetFace.sky)))
        }
        if let lit = f.dots {
            for i in 0..<3 {
                ctx.fill(Path(ellipseIn: CGRect(x: 51.6 + Double(i) * 7, y: 6.6, width: 4.8, height: 4.8)), with: .color(i < lit ? accent : Color.white.opacity(0.18)))
            }
        }
        if let mark = f.mark { glyph(&ctx, mark, 17, accent, at: CGPoint(x: 103, y: 22 - f.markRise * 9)) }
        if f.confetti {
            let colours = [PetFace.gold, PetFace.pink, PetFace.sky, PetFace.coral, PetFace.gold, PetFace.sky]
            for (i, x) in [10.0, 26, 48, 74, 94, 110].enumerated() {
                let y = Double((frame * 7 + i * 17) % 60) + 2
                ctx.fill(Path(roundedRect: CGRect(x: x - 1.6, y: y, width: 3.2, height: 3.2), cornerRadius: 0.8), with: .color(Color(hex: colours[i])))
            }
        }
    }

    /// Timer mode. Merry's face becomes a clock: the time left in the middle
    /// and a bar under it that empties. When time is up it flips between
    /// 00:00 and its own face, and shakes its bell at you.
    private func drawClock(_ ctx: inout GraphicsContext, timer: SpriteTimer, now: Date) {
        let ringing = timer.status == "ringing"
        let seconds = now.timeIntervalSinceReferenceDate
        let colour = Color(hex: timer.status == "running" ? PetFace.gold : PetFace.amber)
        let pulse: (Double) -> Double = { period in
            let phase = (seconds / period).truncatingRemainder(dividingBy: 1)
            return 0.35 + 0.65 * (phase < 0.5 ? BodyMotion.smooth(phase * 2) : BodyMotion.smooth((1 - phase) * 2))
        }
        if ringing && !reduceMotion {
            ctx.translateBy(x: 60, y: 96)
            ctx.rotate(by: .degrees(sin(seconds / 0.35 * 2 * .pi) * 4))
            ctx.translateBy(x: -60, y: -96)
        }
        if ringing && Int(seconds / 0.7) % 2 == 1 {
            drawLamb(&ctx, mood: .excited, frame: Int(seconds / 0.7), accent: colour, bell: 1)
            return
        }
        drawBody(&ctx, accent: colour, bell: ringing ? pulse(0.35) : 1, faceRect: CGRect(x: 29, y: 42, width: 62, height: 36))
        let fade = timer.status == "paused" ? pulse(1.8) : 1
        glyph(&ctx, DotText.clock(timer.remainingMs), 17, Self.cream.opacity(fade), at: CGPoint(x: 60, y: 57))
        let track = CGRect(x: 40, y: 68.5, width: 40, height: 3)
        ctx.fill(Path(roundedRect: track, cornerRadius: 1.5), with: .color(.white.opacity(0.14)))
        let left = max(0, min(1, timer.progress))
        if left > 0 {
            ctx.fill(Path(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(3, track.width * left), height: 3), cornerRadius: 1.5), with: .color(colour.opacity(fade)))
        }
    }
}
