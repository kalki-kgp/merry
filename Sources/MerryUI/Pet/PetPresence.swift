import Foundation
import MerryCore

// Where the pet lives (`PetMode`).
//   ondemand: with the open prompt, during work, timers, or due reminders.
//   peek:    out of sight until there is something to see: it slides up
//             while Merry works, needs an answer or runs a timer, stays a few
//             seconds to show how things went, and comes when called by
//             resting the pointer on the right edge near the bottom.
//   menubar: never on the desktop; the menu bar face and notifications.
//   desktop: always on the desktop, wherever it was put.

/// The little of a window this needs, so it can be tested without AppKit.
@MainActor
public protocol PresenceWindow: AnyObject {
    var isVisible: Bool { get }
    func showInactive()
    func hide()
    /// In screen coordinates with a top-left origin.
    var frame: CGRect { get }
}

@MainActor
public final class PetPresence {
    /// How long the pet stays to show how a task went.
    public static let lingerMs: Double = 6000
    /// How long the pointer rests at the edge before the pet comes.
    public static let callDwellMs: Double = 250
    /// How long after the pointer leaves a called pet before it goes.
    public static let leaveMs: Double = 1200
    /// Matches the view's exit animation.
    public static let exitMs: Double = 260

    @MainActor
    public struct Deps {
        public var window: () -> PresenceWindow?
        public var mode: () -> PetMode
        /// Tells the view to slide in (true) or out (false).
        public var presence: (Bool) -> Void
        /// The bounds of the display under a point, top-left origin.
        public var displayAt: (CGPoint) -> CGRect
        /// A drag or drop is holding the pet.
        public var held: () -> Bool
        public var now: () -> Double
        public var after: (Double, @escaping @MainActor () -> Void) -> PetTimer

        public init(window: @escaping () -> PresenceWindow?, mode: @escaping () -> PetMode, presence: @escaping (Bool) -> Void,
                    displayAt: @escaping (CGPoint) -> CGRect, held: @escaping () -> Bool,
                    now: @escaping () -> Double, after: @escaping (Double, @escaping @MainActor () -> Void) -> PetTimer) {
            self.window = window; self.mode = mode; self.presence = presence; self.displayAt = displayAt; self.held = held
            self.now = now; self.after = after
        }

        /// Time and timers both taken from one clock.
        public init(window: @escaping () -> PresenceWindow?, mode: @escaping () -> PetMode, presence: @escaping (Bool) -> Void,
                    displayAt: @escaping (CGPoint) -> CGRect, held: @escaping () -> Bool, clock: PetClock) {
            self.init(window: window, mode: mode, presence: presence, displayAt: displayAt, held: held,
                      now: { clock.now }, after: { clock.after($0, $1) })
        }
    }

    private let deps: Deps
    private var busy = false
    private var attention = false
    private var panelOpen = false
    private var dismissed = false
    private var attentionKeys = Set<String>()
    private var lingerUntil: Double = 0
    private var calledUntil: Double = 0
    private var edgeSince: Double = 0
    private var hideTimer: PetTimer?
    private var recheck: PetTimer?

    public init(_ deps: Deps) { self.deps = deps }

    private func now() -> Double { deps.now() }

    /// Working, thinking and waiting keep it out; a finished task keeps it a moment longer.
    public func setState(_ state: PetState) {
        let wasBusy = busy
        busy = state == .thinking || state == .working || state == .waiting
        if busy && !wasBusy { dismissed = false }
        if !busy && (state == .finished || state == .failed || wasBusy) { lingerUntil = now() + Self.lingerMs }
        update()
    }

    /// A timer is running or a reminder is due: both are shown on the pet.
    public func setAttention(_ value: Bool, wake: Bool = false) {
        if value && (!attention || wake) { dismissed = false }
        if value == attention && !wake { return }
        attention = value
        update()
    }

    /// Countdowns stay visible; a fresh reminder or a timer ringing wakes a hidden pet.
    public func setBrain(_ state: BrainSnapshot) {
        var keys = Set(state.dueItems(now: now()).map { "reminder:\($0.id)" })
        if let timer = state.timer { keys.insert("timer:\(timer.id):\(timer.status == "ringing" ? "due" : "countdown")") }
        let fresh = keys.contains { !attentionKeys.contains($0) }
        attentionKeys = keys
        setAttention(!keys.isEmpty, wake: fresh)
    }

    /// Hide just the pet until called again or a new task/alert needs it.
    public func hide() {
        dismissed = true
        lingerUntil = 0
        calledUntil = 0
        edgeSince = 0
        update()
    }

    public func reveal() {
        dismissed = false
        update()
    }

    /// Closing the prompt dismisses any completed result or explicit pet call.
    public func setPanelOpen(_ value: Bool) {
        if value && !panelOpen { dismissed = false }
        panelOpen = value
        if !value && deps.mode() == .ondemand {
            lingerUntil = 0
            calledUntil = 0
        }
        update()
    }

    /// Shows the pet for a while, e.g. from the menu bar's "Show pet".
    public func showFor(_ ms: Double) {
        dismissed = false
        calledUntil = now() + ms
        update()
    }

    /// Every cursor sample, whether or not the pet is showing.
    public func sample(_ cursor: CGPoint) {
        guard let win = deps.window(), deps.mode() == .peek, !dismissed else { return }
        let now = now()
        let area = deps.displayAt(cursor)
        let atEdge = cursor.x >= area.minX + area.width - 3 && cursor.y >= area.minY + area.height - 260 && cursor.y <= area.minY + area.height - 8
        if atEdge {
            if edgeSince == 0 { edgeSince = now }
            if now - edgeSince >= Self.callDwellMs { calledUntil = now + Self.leaveMs }
        } else {
            edgeSince = 0
        }
        if win.isVisible && calledUntil > now {
            let b = win.frame
            let near = cursor.x >= b.minX - 40 && cursor.x <= b.minX + b.width + 40 && cursor.y >= b.minY - 40 && cursor.y <= b.minY + b.height + 40
            if near || deps.held() { calledUntil = now + Self.leaveMs }
        }
        update()
    }

    public func wanted() -> Bool {
        if dismissed { return false }
        let mode = deps.mode()
        if mode == .desktop { return true }
        if mode == .menubar { return false }
        let now = now()
        return busy || attention || (mode == .ondemand && panelOpen) || deps.held() || now < lingerUntil || now < calledUntil
    }

    public func update() {
        guard let win = deps.window() else { return }
        if wanted() {
            if let timer = hideTimer { timer.cancel(); hideTimer = nil; deps.presence(true) }
            if !win.isVisible { win.showInactive(); deps.presence(true) }
        } else if win.isVisible && hideTimer == nil {
            deps.presence(false)
            hideTimer = deps.after(Self.exitMs) { [weak self, weak win] in
                guard let self else { return }
                self.hideTimer = nil
                if !self.wanted() { win?.hide() }
            }
        }
        // Lingering ends by itself, not only on the next event.
        recheck?.cancel()
        recheck = nil
        let next = max(lingerUntil, calledUntil) - now()
        if next > 0 { recheck = deps.after(next + 20) { [weak self] in self?.update() } }
    }
}
