import Foundation
import MerryCore

/// A pending piece of work that can be called off, like a `setTimeout` handle.
@MainActor
public final class PetTimer {
    private var work: (@MainActor () -> Void)?

    public init(_ work: @escaping @MainActor () -> Void) { self.work = work }

    public var isPending: Bool { work != nil }
    public func cancel() { work = nil }

    /// Runs the work once; a cancelled or already fired timer does nothing.
    public func fire() {
        guard let work else { return }
        self.work = nil
        work()
    }
}

/// The time and the timers the pet runs on, so tests can drive both.
@MainActor
public protocol PetClock: AnyObject {
    /// Milliseconds since 1970, as `Date.now()`.
    var now: Double { get }
    @discardableResult func after(_ ms: Double, _ work: @escaping @MainActor () -> Void) -> PetTimer
}

@MainActor
public final class SystemPetClock: PetClock {
    public init() {}
    public var now: Double { nowMs() }

    @discardableResult
    public func after(_ ms: Double, _ work: @escaping @MainActor () -> Void) -> PetTimer {
        let timer = PetTimer(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000) {
            MainActor.assumeIsolated { timer.fire() }
        }
        return timer
    }
}

/// A clock that only moves when told to. Timers fire in order of their time,
/// then in the order they were set.
@MainActor
public final class ManualPetClock: PetClock {
    public private(set) var now: Double
    private var queue: [(at: Double, seq: Int, timer: PetTimer)] = []
    private var seq = 0

    public init(now: Double = 1_750_000_000_000) { self.now = now }

    @discardableResult
    public func after(_ ms: Double, _ work: @escaping @MainActor () -> Void) -> PetTimer {
        let timer = PetTimer(work)
        seq += 1
        queue.append((now + max(0, ms), seq, timer))
        return timer
    }

    public func advance(by ms: Double) {
        let end = now + ms
        while true {
            queue.removeAll { !$0.timer.isPending }
            guard let next = queue.filter({ $0.at <= end }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) else { break }
            queue.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            next.timer.fire()
        }
        now = end
    }

    /// How many timers are still waiting.
    public var pending: Int { queue.filter { $0.timer.isPending }.count }
}
