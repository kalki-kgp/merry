import Combine
import Foundation
import MerryCore

/// The pet window's fixed geometry. The window is mostly empty air: wide
/// enough for the creature to speak in whole words.
public enum PetLayout {
    public static let width: CGFloat = 260
    public static let height: CGFloat = 190
    public static let spriteSize: CGFloat = 92
    public static var spriteHeight: CGFloat { spriteSize * 112 / 120 }
    /// The creature, in window coordinates with a top-left origin: bottom-centre, 4 points off the floor.
    public static var creature: CGRect {
        CGRect(x: (width - spriteSize) / 2, y: height - 4 - spriteHeight, width: spriteSize, height: spriteHeight)
    }
    /// Where bursts of hearts and sparks start.
    public static let burstOrigin = CGPoint(x: width / 2, y: height - 46)
}

/// A short-lived feeling that overrides the runtime's mood, e.g. surprise at
/// being woken or embarrassment after an undo.
public struct PetFlash: Equatable, Sendable {
    public var mood: Mood
    public var until: Double
    public init(mood: Mood, until: Double) { self.mood = mood; self.until = until }
}

/// A little burst of hearts or sparkles, like the website's playground.
public struct PetBurst: Identifiable, Equatable {
    public enum Kind: String, Sendable { case hearts, sparks }
    public var id: Double
    public var kind: Kind
    public var count: Int
    /// "#rrggbb"
    public var color: String
    public var started: Date
}

/// What the speech bubble shows.
public struct PetBubble: Equatable {
    public enum Tone: String, Sendable { case plain, chat, ask, bad, good, reminder, peek }
    public enum Button: Equatable, Sendable {
        case done, snooze, answer, undo
        /// The spoken line's own button.
        case line(String)

        public var label: String {
            switch self {
            case .done: return "Done"
            case .snooze: return "10 min"
            case .answer: return "Answer"
            case .undo: return "Undo"
            case .line(let label): return label
            }
        }
    }

    public var text: String
    public var tone: Tone
    /// The lime dot while working.
    public var pulse: Bool
    public var buttons: [Button]
    /// A change of key replays the bubble's entrance.
    public var key: String
}

/// Cubic bezier easing, as CSS's `cubic-bezier(x1, y1, x2, y2)`.
public struct CubicBezier: Sendable {
    public var x1, y1, x2, y2: Double
    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2 }

    private func curve(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    public func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            let at = curve(x1, x2, t)
            if abs(at - x) < 1e-7 { break }
            if at < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return curve(y1, y2, t)
    }
}

/// Back-and-forth passes over the pet, within a window, count as petting.
public struct RubDetector: Equatable, Sendable {
    public static let rubs = 4
    public static let windowMs: Double = 1400

    public var x: Double = 0
    public var dir = 0
    public var turns: [Double] = []
    public var lastPetted: Double = 0

    public init() {}

    /// Notes the cursor's x; true when that pass makes it petting.
    public mutating func notice(x clientX: Double, now: Double) -> Bool {
        let dx = clientX - x
        x = clientX
        if abs(dx) < 3 { return false }
        let direction = dx > 0 ? 1 : -1
        if dir != 0 && direction != dir { turns = turns.filter { now - $0 < Self.windowMs } + [now] }
        dir = direction
        if turns.count >= Self.rubs && now - lastPetted > 4000 {
            turns = []
            lastPetted = now
            return true
        }
        return false
    }
}

/// The parts of the pet's behaviour that are plain functions of its state.
public enum PetLogic {
    /// Distance in points beyond which a mouse-down becomes a drag, not a click.
    public static let dragThreshold: Double = 4
    /// Left alone this long with nothing to do, Merry dozes off.
    public static let sleepAfterMs: Double = 3 * 60 * 1000
    /// A task running longer than this starts to look like hard work.
    public static let strainAfterMs: Double = 25 * 1000
    /// How often, at most, it speaks up unprompted while idle.
    public static let remarkGapMs: (Double, Double) = (6 * 60 * 1000, 12 * 60 * 1000)

    public static func mood(dropping: Bool, dragging: Bool, dancing: Bool, flash: PetFlash?, now: Double, asleep: Bool,
                            state: PetState, straining: Bool, settled: Bool, hovered: Bool) -> Mood {
        if dropping { return .excited }
        if dragging { return .dizzy }
        if dancing { return .music }
        if let flash, flash.until > now { return flash.mood }
        if asleep && state == .idle { return .sleepy }
        if state == .working && straining { return .straining }
        let resting = settled && (state == .finished || state == .failed)
        if hovered && (state == .idle || state == .finished || resting) { return .happy }
        return resting ? .idle : Mood.forState(state)
    }

    /// Eyes follow the mouse anywhere on screen, easing off with distance so a
    /// far-away cursor gets a glance rather than a stare.
    public static func look(dx: Double, dy: Double) -> Look {
        let dist = (dx * dx + dy * dy).squareRoot()
        let reach = min(1, dist / 140)
        return Look(x: dist != 0 ? dx / dist * reach : 0, y: dist != 0 ? dy / dist * reach : 0)
    }

    public struct BubbleInput {
        public var alertError: String?
        public var timer: BrainTimer?
        public var due: BrainItem?
        public var hovered = false
        public var now: Double = 0
        public var taskStatus: TaskStatus?
        public var undoable = false
        public var undoNote: String?
        public var chat: Line?
        public var bubble: String?
        public var working = false
        public var dropping = false
        public init() {}
    }

    /// Text precedence: alert error, alert, timer peek, undo note, what Merry chose to say, the status line.
    public static func bubble(_ i: BubbleInput) -> PetBubble? {
        let awaiting = i.taskStatus == .awaitingUser
        let done = i.taskStatus?.isTerminal ?? false
        let ringing = i.timer?.status == "ringing"
        let tone: PetBubble.Tone = i.chat != nil && i.undoNote == nil ? .chat
            : !done ? (awaiting ? .ask : .plain)
            : i.taskStatus == .failed ? .bad : i.taskStatus == .succeeded ? .good : .plain
        let canUndo = done && i.undoable
        let alert: String? = awaiting ? nil : ringing ? "Time’s up: \(i.timer!.label)." : i.due?.title
        // Hovering the TV says what the time is for, without opening anything.
        var peek: String?
        if i.hovered, let timer = i.timer, !ringing {
            peek = "\(timer.label) · \(timer.status == "paused" ? "paused" : "\(DotText.clock(timer.remaining(now: i.now))) left")"
        }
        guard let text = i.alertError ?? alert ?? peek ?? i.undoNote ?? i.chat?.text ?? i.bubble, !text.isEmpty, !i.dropping else { return nil }

        var buttons: [PetBubble.Button] = []
        if alert != nil {
            buttons.append(.done)
            if !ringing { buttons.append(.snooze) }
        }
        if alert == nil && i.undoNote == nil, let action = i.chat?.action { buttons.append(.line(action.label)) }
        if alert == nil && peek == nil && i.undoNote == nil && i.chat == nil && (canUndo || awaiting) {
            if awaiting { buttons.append(.answer) }
            if canUndo { buttons.append(.undo) }
        }
        return PetBubble(text: text, tone: alert != nil ? .reminder : peek != nil ? .peek : tone,
                         pulse: i.working && i.chat == nil && peek == nil && alert == nil,
                         buttons: buttons, key: i.chat?.text ?? "status")
    }

    public enum Click: Equatable, Sendable {
        /// A flurry of taps.
        case tickled
        /// A few quick taps.
        case petted
        /// A click wakes a nap, without also opening the panel.
        case wake
        /// The second tap of a run: neither affection yet nor a request.
        case ignored
        case open
    }

    /// A few quick taps is affection; a flurry of them tickles. Neither is a
    /// request to open the panel.
    public static func click(_ clicks: inout [Double], now: Double, asleep: Bool) -> Click {
        clicks = clicks.filter { now - $0 < 1500 } + [now]
        if clicks.count >= 6 { clicks = []; return .tickled }
        if clicks.count == 3 { return .petted }
        if asleep { return .wake }
        if clicks.count > 1 { return .ignored }
        return .open
    }

    /// Where the pet catches the mouse: the creature padded by 14, the bubble by 4.
    public static func hitRects(creature: CGRect?, bubble: CGRect?) -> [CGRect] {
        [creature.map { $0.insetBy(dx: -14, dy: -14) }, bubble.map { $0.insetBy(dx: -4, dy: -4) }].compactMap { $0 }
    }

    /// The rounded rectangles as text, to tell when they have really changed.
    public static func rectsKey(_ rects: [CGRect]) -> String {
        func round(_ v: CGFloat) -> Int { Int((Double(v) + 0.5).rounded(.down)) }
        return rects.map { "\(round($0.minX)),\(round($0.minY)),\(round($0.width)),\(round($0.height))" }.joined(separator: ";")
    }

    public struct Particle: Equatable, Sendable {
        public var dx: Double
        public var dy: Double
        /// Degrees.
        public var spin: Double
        public var delayMs: Double
    }

    /// Where particle `index` of a burst of `count` flies to.
    public static func particle(_ index: Int, of count: Int) -> Particle {
        let angle = Double.pi * 2 * Double(index) / Double(count) - Double.pi / 2
        let dist = Double(34 + (index * 37) % 30)
        return Particle(dx: cos(angle) * dist, dy: sin(angle) * dist - 14, spin: Double((index * 47) % 160), delayMs: Double((index % 3) * 30))
    }
}

/// The pet's state and every timer behind it; `PetView` only draws this and
/// passes the mouse along.
@MainActor
public final class PetModel: ObservableObject {
    public enum Presence: Sendable { case arriving, leaving }
    public enum AlertAction: Sendable { case done, snooze }

    @Published public private(set) var presence: Presence?
    @Published public private(set) var brain = BrainSnapshot()
    @Published public private(set) var now: Double
    @Published public private(set) var alertError: String?
    @Published public private(set) var state: PetState = .idle
    @Published public private(set) var task: TaskState?
    @Published public private(set) var bubble: String?
    /// Something Merry chose to say, as opposed to a status line.
    @Published public private(set) var chat: Line?
    @Published public private(set) var dropping = false
    @Published public private(set) var desktopActive = false
    @Published public private(set) var hovered = false
    @Published public private(set) var dragging = false
    @Published public private(set) var asleep = false
    @Published public private(set) var straining = false
    @Published public private(set) var flash: PetFlash?
    @Published public private(set) var look = Look()
    @Published public private(set) var undoNote: String?
    @Published public private(set) var bursts: [PetBurst] = []
    @Published public private(set) var dancing = false
    /// Celebration and sulking both wear off; the pet goes back to being itself.
    @Published public private(set) var settled = false
    /// Goes up by one for every hop, restarted even if one is already playing.
    @Published public private(set) var hops = 0
    /// The bubble button the mouse went down on and is still over.
    @Published public private(set) var pressedButton: Int?

    /// Set by the view; with it on there are no hops and no bursts.
    public var reduceMotion = false

    private let bridge: MerryBridge
    private let clock: PetClock
    private let random: () -> Double
    private let hour: () -> Int

    private struct Drag { var startX: Double; var startY: Double; var moved = false; var speed = 0.0; var pressedAt: Date }
    private struct Seen { var id: String; var status: TaskStatus; var nudged: Bool }
    private struct Effect { var deps: [AnyHashable]; var cleanup: (() -> Void)? }
    private final class Repeating { var cancelled = false; var timer: PetTimer? }

    private var rub = RubDetector()
    private var surpriseTurn = 0
    /// A nap the person asked for lasts until they wake it, not until the cursor wanders by.
    private var chosenNap = false
    private var drag: Drag?
    private var dragWatchdog: PetTimer?
    private var bubbleTimer: PetTimer?
    private var chatTimer: PetTimer?
    private var later: [PetTimer] = []
    private var lastPoke: Double
    private var lastMove: Double
    private var activeSince: Double
    private var lastRemark: Double
    private var remarkGap = PetLogic.remarkGapMs.0
    private var remarkTurn: Int
    private var lastHoverHello: Double = 0
    private var chatty = true
    private var seen: Seen?
    private var clicks: [Double] = []
    private var solid = false
    private var lastAt = ""
    private var lastRects: String?
    private var bubbleFrame: CGRect?
    private var buttonFrames: [Int: CGRect] = [:]
    private var armedButton: Int?
    private var brainChanged = false
    private var started = false
    private var flushing = false
    private var effects: [String: Effect] = [:]
    private var chatSeq = 0
    private var flashSeq = 0
    private var cancellables = Set<AnyCancellable>()

    public init(bridge: MerryBridge, clock: PetClock? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) },
                hour: (() -> Int)? = nil) {
        let clock = clock ?? SystemPetClock()
        self.bridge = bridge
        self.clock = clock
        self.random = random
        self.hour = hour ?? { LocalTime.calendar.component(.hour, from: Date(timeIntervalSince1970: clock.now / 1000)) }
        let t = clock.now
        now = t; lastPoke = t; lastMove = t; activeSince = t; lastRemark = t
        remarkTurn = Int(random() * 10)
    }

    // MARK: Derived

    public var working: Bool { state == .working || state == .thinking }
    public var due: BrainItem? { brain.dueItems(now: now).first }

    public var mood: Mood {
        PetLogic.mood(dropping: dropping, dragging: dragging, dancing: dancing, flash: flash, now: clock.now, asleep: asleep,
                      state: state, straining: straining, settled: settled, hovered: hovered)
    }

    public var bubbleContent: PetBubble? {
        var i = PetLogic.BubbleInput()
        i.alertError = alertError; i.timer = brain.timer; i.due = due; i.hovered = hovered; i.now = now
        i.taskStatus = task?.status; i.undoable = task?.summary?.undoable ?? false; i.undoNote = undoNote
        i.chat = chat; i.bubble = bubble; i.working = working; i.dropping = dropping
        return PetLogic.bubble(i)
    }

    public var spriteTimer: SpriteTimer? {
        brain.timer.map { SpriteTimer(remainingMs: $0.remaining(now: now), progress: $0.remaining(now: now) / $0.durationMs, status: $0.status) }
    }

    // MARK: Small helpers

    private func setChat(_ line: Line?) {
        if line == nil && chat == nil { return }
        chat = line
        chatSeq += 1
    }

    private func feel(_ mood: Mood, _ ms: Double) {
        flash = PetFlash(mood: mood, until: clock.now + ms)
        flashSeq += 1
    }

    /// Say something, with the face to match. Optional remarks respect the "chatty" setting.
    func say(_ line: Line, _ ms: Double = 4500, optional: Bool = true) {
        if optional && (brain.timer != nil || !chatty) { feel(line.mood, min(ms, 2500)); return }
        chatTimer?.cancel()
        setChat(line)
        feel(line.mood, min(ms, 3200))
        chatTimer = timer(ms) { [weak self] in self?.setChat(nil) }
    }

    /// A timer whose work is followed by the effects it may have set off.
    private func timer(_ ms: Double, _ work: @escaping () -> Void) -> PetTimer {
        clock.after(ms) { [weak self] in
            work()
            self?.flush()
        }
    }

    private func after(_ ms: Double, _ work: @escaping () -> Void) {
        later.removeAll { !$0.isPending }
        later.append(timer(ms, work))
    }

    private func every(_ ms: Double, _ work: @escaping () -> Void) -> () -> Void {
        let box = Repeating()
        @MainActor func arm() {
            box.timer = clock.after(ms) { [weak self] in
                guard let self, !box.cancelled else { return }
                arm()
                work()
                self.flush()
            }
        }
        arm()
        return { box.cancelled = true; box.timer?.cancel() }
    }

    /// A little hop.
    private func hop() {
        if reduceMotion { return }
        hops += 1
    }

    private func burst(_ kind: PetBurst.Kind, _ count: Int, _ color: String = PetFace.gold) {
        if reduceMotion { return }
        let id = clock.now + random()
        bursts = Array(bursts.suffix(3)) + [PetBurst(id: id, kind: kind, count: count, color: color, started: Date())]
        after(1300) { [weak self] in self?.bursts.removeAll { $0.id == id } }
    }

    /// Any sign of the person resets the doze timer, and wakes Merry with a start.
    private func poke() {
        lastPoke = clock.now
        if asleep && !chosenNap {
            asleep = false
            feel(.surprised, 700)
            after(700) { [weak self] in self?.say(Personality.woke(), 2600) }
        }
    }

    private func hold(_ on: Bool) {
        if on == solid { return }
        solid = on
        bridge.setPetInteractive(on)
    }

    // MARK: Lifecycle

    /// Subscribes to the bridge and starts the timers. Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        let events = bridge.events
        chatty = bridge.getSettings().chatty
        events.settingsChanged.sink { [weak self] in self?.chatty = $0.chatty }.store(in: &cancellables)
        // A hello when it arrives on the desktop.
        after(1400) { [weak self] in
            guard let self else { return }
            self.say(Personality.hello(hour: self.hour()), 4200)
        }

        events.historyDeleted.sink { [weak self] _ in
            guard let self else { return }
            self.bubble = nil; self.task = nil
            self.flush()
        }.store(in: &cancellables)
        events.petState.sink { [weak self] s in
            guard let self else { return }
            self.state = s; self.poke()
            self.flush()
        }.store(in: &cancellables)
        events.taskUpdate.sink { [weak self] t in
            self?.taskUpdated(t)
            self?.flush()
        }.store(in: &cancellables)
        events.desktopSession.sink { [weak self] in self?.desktopActive = $0 }.store(in: &cancellables)
        events.petPlay.sink { [weak self] action in
            self?.play(action)
            self?.flush()
        }.store(in: &cancellables)
        // Out of sight until there is something to see: slide up on arrival, down on leaving.
        events.petPresence.sink { [weak self] visible in self?.presence = visible ? .arriving : .leaving }.store(in: &cancellables)
        events.cursor.sink { [weak self] at in
            self?.cursorMoved(dx: Double(at.x), dy: Double(at.y))
            self?.flush()
        }.store(in: &cancellables)

        events.brainChanged.sink { [weak self] s in
            guard let self else { return }
            self.brainChanged = true
            self.brain = s
        }.store(in: &cancellables)
        Task { [weak self, bridge] in
            let snapshot = await bridge.getBrain()
            guard let self, !self.brainChanged else { return }
            self.brain = snapshot
        }
        // The clock the timer and due reminders are read against.
        _ = every(1000) { [weak self] in
            guard let self else { return }
            self.now = self.clock.now
        }
        flush()
        reportRects()
    }

    private func taskUpdated(_ t: TaskState) {
        let before = seen
        let fresh = before == nil || before?.id != t.id
        task = t
        undoNote = nil
        bubbleTimer?.cancel()
        let terminal = t.status.isTerminal

        // A new job: acknowledge it like a person would, before the status lines take over.
        if fresh && !terminal { say(Personality.onStart(t.request), 2000) }

        // The bubble always reflects real runtime state, never a canned line.
        if terminal {
            let undoable = t.summary?.undoable ?? false
            bubble = Markdown.plainText(t.summary?.headline ?? t.statusLine)
            // A result with an undo stays up longer: that button is the safety net.
            bubbleTimer = timer(undoable ? 12000 : 7000) { [weak self] in self?.bubble = nil }
            if before?.status != t.status {
                setChat(nil)
                if t.status == .succeeded {
                    let secs = (t.updatedAt - t.createdAt) / 1000
                    let won = Personality.successMood(actions: t.actions.count, seconds: secs)
                    feel(won, 3600)
                    if won == .celebrate { burst(.sparks, 18) }
                    else if won == .starstruck { burst(.sparks, 12, "#ffe066") }
                    else if !t.actions.isEmpty { burst(.sparks, 8) }
                    after(undoable ? 12500 : 7500) { [weak self] in
                        if let line = Personality.afterSuccess() { self?.say(line, 6000) }
                    }
                } else if t.status == .failed {
                    after(3500) { [weak self] in self?.say(Personality.afterFailure(), 7000, optional: false) }
                }
            }
        } else {
            bubble = t.statusLine.isEmpty ? nil : t.statusLine
        }
        seen = Seen(id: t.id, status: t.status, nudged: fresh ? false : (before?.nudged ?? false))
    }

    private func cursorMoved(dx: Double, dy: Double) {
        look = PetLogic.look(dx: dx, dy: dy)
        let at = "\(dx),\(dy)"
        if at != lastAt {
            let now = clock.now
            // A long gap means they stepped away; a new stretch of activity starts.
            if now - lastMove > 5 * 60 * 1000 { activeSince = now }
            lastMove = now
            lastAt = at
        }
        if (dx * dx + dy * dy).squareRoot() < 90 { poke() }
    }

    func play(_ action: PetPlay) {
        lastPoke = clock.now
        switch action {
        case .dance:
            chosenNap = false
            asleep = false
            dancing = true
            say(Personality.danceStart(), 4300)
            feel(.music, 4300)
            burst(.sparks, 16)
            after(2100) { [weak self] in self?.burst(.sparks, 12, "#e1ff77") }
            after(4300) { [weak self] in
                guard let self else { return }
                self.dancing = false; self.say(Personality.danceEnd(), 2600); self.hop()
            }
        case .nap:
            chosenNap = true
            say(Personality.nap(), 2400)
            after(900) { [weak self] in self?.asleep = true }
        case .wake:
            chosenNap = false
            asleep = false
            say(Personality.napWake(), 2600)
        case .surprise:
            let line = Personality.surprises[surpriseTurn % Personality.surprises.count]
            surpriseTurn += 1
            say(line, 3200)
            hop()
            if line.mood == .starstruck { burst(.sparks, 12, "#ffe066") }
            if line.mood == .kiss { burst(.hearts, 7, "#ff6fa8") }
        }
    }

    // MARK: Effects

    /// Runs `body` when `deps` differ from last time, after undoing what it set up before.
    private func effect(_ key: String, _ deps: [AnyHashable], _ body: () -> (() -> Void)?) -> Bool {
        if let existing = effects[key], existing.deps == deps { return false }
        effects[key]?.cleanup?()
        effects[key] = Effect(deps: deps, cleanup: nil)
        effects[key]?.cleanup = body()
        return true
    }

    /// Brings the timers that depend on state in line with it.
    private func flush() {
        guard started, !flushing else { return }
        flushing = true
        defer { flushing = false }
        // An effect can change state another one depends on; settle in a few passes.
        for _ in 0..<6 { if !runEffects() { break } }
    }

    private func runEffects() -> Bool {
        var ran = false
        let taskId = task?.id as AnyHashable
        let status = task?.status as AnyHashable

        // Doze off when nothing has happened for a while, with a yawn first.
        ran = effect("doze", [state, hovered]) {
            let state = self.state, hovered = self.hovered
            return self.every(5000) { [weak self] in
                guard let self else { return }
                if state == .idle && !hovered && !self.asleep && self.clock.now - self.lastPoke > PetLogic.sleepAfterMs {
                    self.say(Personality.yawn(), 2600)
                    // Nobody stirred during the yawn: asleep. Otherwise it tries again in a little while.
                    let mark = self.clock.now - PetLogic.sleepAfterMs + 10_000
                    self.lastPoke = mark
                    self.after(2600) { [weak self] in
                        if let self, self.lastPoke == mark { self.asleep = true }
                    }
                }
            }
        } || ran

        // The odd unprompted remark: only while idle, awake, and the person is around.
        ran = effect("remark", [state, chatSeq]) {
            guard self.state == .idle else { return nil }
            let speaking = self.chat != nil
            return self.every(20_000) { [weak self] in
                guard let self else { return }
                let now = self.clock.now
                if self.asleep || speaking || now - self.lastRemark < self.remarkGap || now - self.lastMove > 2 * 60 * 1000 { return }
                self.lastRemark = now
                self.remarkGap = PetLogic.remarkGapMs.0 + self.random() * (PetLogic.remarkGapMs.1 - PetLogic.remarkGapMs.0)
                self.say(Personality.idleRemark(hour: self.hour(), activeMinutes: (now - self.activeSince) / 60000, turn: self.remarkTurn), 7000)
                self.remarkTurn += 1
            }
        } || ran

        // During a long job, a kind word every so often, built from the task's real state.
        ran = effect("checkIn", [taskId, status]) {
            guard let task = self.task, !task.status.isTerminal, task.status != .awaitingUser else { return nil }
            var turn = 0
            return self.every(24_000) { [weak self] in
                guard let self else { return }
                let done = task.plan.filter { $0.status == "done" }.count
                self.say(Personality.checkIn(seconds: (self.clock.now - task.createdAt) / 1000, done: done, total: task.plan.count, turn: turn), 4200)
                turn += 1
            }
        } || ran

        // Waiting on an answer for a while: a gentle nudge, once.
        ran = effect("nudge", [status, task?.question?.id as AnyHashable]) {
            guard self.task?.status == .awaitingUser else { return nil }
            let t = self.timer(30_000) { [weak self] in
                guard let self, let seen = self.seen, !seen.nudged else { return }
                self.seen?.nudged = true
                self.say(Personality.nudge(), 6000)
            }
            return { t.cancel() }
        } || ran

        // Hovering for a moment without clicking gets a shy hello.
        ran = effect("hoverHello", [hovered, state, chatSeq]) {
            guard self.hovered, self.state == .idle else { return nil }
            let speaking = self.chat != nil
            let t = self.timer(2500) { [weak self] in
                guard let self else { return }
                if self.clock.now - self.lastHoverHello > 5 * 60 * 1000 && !speaking {
                    self.lastHoverHello = self.clock.now
                    self.say(Personality.hovered(), 2200)
                }
            }
            return { t.cancel() }
        } || ran

        ran = effect("settle", [state, taskId]) {
            self.settled = false
            guard self.state == .finished || self.state == .failed else { return nil }
            let t = self.timer(6000) { [weak self] in self?.settled = true }
            return { t.cancel() }
        } || ran

        // Long jobs show effort.
        ran = effect("strain", [state, taskId]) {
            guard self.state == .working else { self.straining = false; return nil }
            let t = self.timer(PetLogic.strainAfterMs) { [weak self] in self?.straining = true }
            return { t.cancel() }
        } || ran

        // Now and then, while idle, a little flicker of personality.
        ran = effect("quirks", [state]) {
            guard self.state == .idle else { return nil }
            let quirks: [(Mood, Double)] = [(.wink, 700), (.music, 3200), (.curious, 1400), (.bored, 2600), (.skeptical, 1200)]
            let box = Repeating()
            @MainActor func next() {
                box.timer = self.timer(22000 + self.random() * 30000) { [weak self] in
                    guard let self, !box.cancelled else { return }
                    if !self.asleep {
                        let (mood, ms) = quirks[min(quirks.count - 1, Int(self.random() * Double(quirks.count)))]
                        self.feel(mood, ms)
                    }
                    next()
                }
            }
            next()
            return { box.cancelled = true; box.timer?.cancel() }
        } || ran

        // Expire flashes.
        ran = effect("flash", [flashSeq]) {
            guard let flash = self.flash else { return nil }
            let t = self.timer(max(0, flash.until - self.clock.now)) { [weak self] in self?.flash = nil; self?.flashSeq += 1 }
            return { t.cancel() }
        } || ran

        return ran
    }

    // MARK: The mouse

    /// The bubble's frame in window coordinates (top-left origin), or nil when there is none.
    ///
    /// The window is mostly empty air. It is made solid only while the cursor
    /// is over the creature or its bubble, from the real cursor position, so
    /// the rest stays click-through and a quick click is never lost. This says
    /// where those are, whenever they move or change size.
    public func layout(bubble: CGRect?, buttons: [Int: CGRect] = [:]) {
        bubbleFrame = bubble
        buttonFrames = bubble == nil ? [:] : buttons
        reportRects()
    }

    private func reportRects() {
        guard started else { return }
        let rects = PetLogic.hitRects(creature: PetLayout.creature, bubble: bubbleFrame)
        let key = PetLogic.rectsKey(rects)
        if key == lastRects { return }
        lastRects = key
        bridge.setPetHitRects(rects)
    }

    private func updateHover(_ local: CGPoint) {
        let box = PetLayout.creature
        hovered = local.x >= box.minX && local.x <= box.maxX && local.y >= box.minY && local.y <= box.maxY
    }

    /// The left button went down at `local` (window) / `screen` (top-left origin).
    public func mouseDown(local: CGPoint, screen: CGPoint, pressedAt: Date = Date()) {
        defer { flush() }
        // A press on the bubble is for its buttons, never a grab.
        if let bubbleFrame, bubbleFrame.contains(local) {
            armedButton = buttonFrames.first { $0.value.contains(local) }?.key
            pressedButton = armedButton
            return
        }
        // When the button went down, in wall-clock time, so the app can ask what
        // the panel was doing *before* this click changed anything.
        drag = Drag(startX: Double(screen.x), startY: Double(screen.y), pressedAt: pressedAt)
        armDragWatchdog()
        // A fast drag can outrun the window; stay solid until the button is up.
        hold(true)
    }

    public func mouseMoved(local: CGPoint, screen: CGPoint, primaryDown: Bool) {
        defer { flush() }
        let wasHovered = hovered
        updateHover(local)
        if let armedButton { pressedButton = buttonFrames[armedButton]?.contains(local) == true ? armedButton : nil }
        // The button came up somewhere this window never heard about: a fast
        // drag easily leaves the little window behind. Finish the drag now, or
        // Merry stays dizzy and keeps swallowing clicks on that patch of screen.
        if drag != nil && !primaryDown { endDrag(); return }
        if drag != nil { armDragWatchdog() }
        guard var drag else {
            if wasHovered && rub.notice(x: Double(local.x), now: clock.now) {
                poke()
                say(Personality.petted(), 2600)
                burst(.hearts, 9, "#ff6fa8")
                hop()
            }
            return
        }
        let dx = Double(screen.x) - drag.startX
        let dy = Double(screen.y) - drag.startY
        let moved = (dx * dx + dy * dy).squareRoot()
        if !drag.moved && moved < PetLogic.dragThreshold { return }
        if !drag.moved { say(Personality.picked(), 1800) }
        drag.moved = true
        // Only a real shake makes it dizzy; a gentle carry is fine.
        drag.speed = drag.speed * 0.8 + moved * 0.2
        if drag.speed > 9 { dragging = true }
        drag.startX = Double(screen.x)
        drag.startY = Double(screen.y)
        self.drag = drag
        bridge.dragPet(dx: CGFloat(dx), dy: CGFloat(dy))
    }

    /// A drag that goes quiet for a while has ended, whether or not the release was seen.
    private func armDragWatchdog() {
        dragWatchdog?.cancel()
        dragWatchdog = timer(2500) { [weak self] in
            if let self, self.drag != nil { self.endDrag() }
        }
    }

    /// Ends a drag whose release happened outside the window: no click, just a landing.
    private func endDrag() {
        let ended = drag
        drag = nil
        dragWatchdog?.cancel()
        hold(false)
        if ended?.moved == true {
            let shaken = dragging
            dragging = false
            say(Personality.landed(shaken: shaken), 2400)
            hop()
        } else {
            dragging = false
        }
    }

    public func mouseUp(local: CGPoint) {
        defer { flush() }
        dragWatchdog?.cancel()
        let ended = drag
        drag = nil
        if ended?.moved == true {
            let shaken = dragging
            dragging = false
            say(Personality.landed(shaken: shaken), 2400)
            hop()
        }
        hold(false)
        updateHover(local)
        if let armed = armedButton {
            armedButton = nil
            pressedButton = nil
            if buttonFrames[armed]?.contains(local) == true, let buttons = bubbleContent?.buttons, buttons.indices.contains(armed) { press(buttons[armed]) }
        }
        guard let ended, !ended.moved else { return }
        poke()
        switch PetLogic.click(&clicks, now: clock.now, asleep: asleep) {
        case .tickled: say(Personality.tickled(), 2600); burst(.sparks, 10); hop()
        case .petted: say(Personality.petted(), 2200); burst(.hearts, 9, "#ff6fa8"); hop()
        case .wake: chosenNap = false; asleep = false; say(Personality.napWake(), 2400)
        case .ignored: break
        case .open:
            if brain.timer != nil { bridge.openBrain() } else { bridge.petClicked(pressedAt: ended.pressedAt) }
        }
    }

    /// The cursor left the window.
    public func mouseLeft(primaryDown: Bool) {
        defer { flush() }
        hovered = false
        if drag == nil { hold(false) }
        // Left the window with the button already up: that drag is over.
        else if !primaryDown { endDrag() }
    }

    /// Right-click opens the menu; only the left button picks it up.
    public func contextMenu() {
        hold(false)
        bridge.showPetMenu(napping: asleep)
    }

    public func dragEntered() { hold(true) }
    public func dragOver() { dropping = true }
    public func dragLeft() { dropping = false; hold(false) }

    public func drop(_ paths: [String]) {
        defer { flush() }
        dropping = false
        hold(false)
        let paths = paths.filter { !$0.isEmpty }
        if paths.isEmpty { return }
        say(Personality.fed(paths.count), 1200)
        after(900) { [weak self] in
            guard let self else { return }
            self.say(Personality.ate(paths.count), 2600); self.burst(.sparks, paths.count >= 3 ? 16 : 10); self.hop()
        }
        bridge.reportDroppedPaths(paths)
    }

    // MARK: The bubble's buttons

    public func undo() async {
        guard let task else { return }
        do {
            let report = try await bridge.undoTask(task.id)
            feel(.oops, 2600)
            undoNote = Personality.undone(report.reversed).text
            var updated = task
            updated.summary?.undoable = false
            self.task = updated
            bubbleTimer?.cancel()
            bubbleTimer = timer(3500) { [weak self] in self?.bubble = nil; self?.undoNote = nil }
        } catch {
            let message = messageOf(error)
            undoNote = message.isEmpty ? "Couldn’t undo that" : message
        }
        flush()
    }

    /// The spoken line's button: an offer only ever puts words in the composer.
    public func act(_ line: Line) {
        setChat(nil)
        bridge.petCompose(line.action?.compose ?? "")
        flush()
    }

    public func answer() { bridge.petCompose("") }

    public func alertAction(_ action: AlertAction) async {
        alertError = nil
        do {
            if brain.timer?.status == "ringing" {
                _ = try await bridge.brainRequest(["op": "timer", "action": "cancel"])
            } else if let due {
                _ = try await bridge.brainRequest(action == .done ? ["op": "complete", "id": .string(due.id)] : ["op": "snooze", "id": .string(due.id), "minutes": 10])
            }
        } catch {
            let message = messageOf(error)
            alertError = message.isEmpty ? "Could not update reminder." : message
        }
    }

    public func press(_ button: PetBubble.Button) {
        switch button {
        case .done: Task { await alertAction(.done) }
        case .snooze: Task { await alertAction(.snooze) }
        case .answer: answer()
        case .undo: Task { await undo() }
        case .line: if let chat { act(chat) }
        }
    }

    // MARK: For previews

    /// Puts the cursor on the creature, as a preview has no mouse.
    func previewHover(_ on: Bool) { hovered = on; flush() }

    /// Skips past whatever it is saying, to show the status line underneath.
    func previewQuiet() { setChat(nil); flush() }
}
