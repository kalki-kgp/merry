import Foundation

/// The exclusive desktop-control session.
///
/// File work can happen quietly in the background, but driving the GUI means
/// borrowing the user's actual keyboard, mouse and focus. When that is
/// happening it must be visible, interruptible, and held by exactly one task.
///
/// This is the state only. The indicator window and the global stop shortcut
/// belong to the interface, which supplies them as hooks.
public final class DesktopSession: @unchecked Sendable {
    /// What the interface does when a session starts and ends.
    public struct Hooks: Sendable {
        /// Shows the "Merry is using your screen" indicator, or updates its text.
        public var showIndicator: @Sendable (String) -> Void
        public var hideIndicator: @Sendable () -> Void
        /// Registers the global panic stop, which must call `requestStop()`.
        public var registerStopShortcut: @Sendable () -> Void
        public var unregisterStopShortcut: @Sendable () -> Void

        public init(
            showIndicator: @escaping @Sendable (String) -> Void = { _ in },
            hideIndicator: @escaping @Sendable () -> Void = {},
            registerStopShortcut: @escaping @Sendable () -> Void = {},
            unregisterStopShortcut: @escaping @Sendable () -> Void = {}
        ) {
            self.showIndicator = showIndicator; self.hideIndicator = hideIndicator
            self.registerStopShortcut = registerStopShortcut; self.unregisterStopShortcut = unregisterStopShortcut
        }
    }

    /// The global panic stop, in the reference's accelerator notation.
    public static let stopAccelerator = "CommandOrControl+Shift+Escape"

    private let lock = NSLock()
    private var holder: String?
    private var hooks: Hooks
    private var changed: (@Sendable (Bool) -> Void)?
    private var stopRequested: (@Sendable (String?) -> Void)?

    public init(hooks: Hooks = Hooks()) { self.hooks = hooks }

    /// Called with true when a task takes the desktop and false when it lets go.
    public var onChanged: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changed }
        set { lock.lock(); changed = newValue; lock.unlock() }
    }

    /// Called with the holding task's id when the person hits the panic stop.
    public var onStopRequested: (@Sendable (String?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopRequested }
        set { lock.lock(); stopRequested = newValue; lock.unlock() }
    }

    public var activeTaskId: String? { lock.lock(); defer { lock.unlock() }; return holder }

    public var isActive: Bool { activeTaskId != nil }

    /// Grants control to one task, or rejects if another already holds it.
    public func claim(_ taskId: String, reason: String) throws {
        lock.lock()
        if let holder, holder != taskId {
            lock.unlock()
            throw MerryError("another task is already controlling the desktop")
        }
        if holder == taskId { lock.unlock(); return }
        holder = taskId
        let hooks = self.hooks, changed = self.changed
        lock.unlock()
        hooks.showIndicator(reason)
        hooks.registerStopShortcut()
        changed?(true)
    }

    public func release(_ taskId: String) {
        lock.lock()
        if holder != taskId { lock.unlock(); return }
        holder = nil
        let hooks = self.hooks, changed = self.changed
        lock.unlock()
        hooks.hideIndicator()
        hooks.unregisterStopShortcut()
        changed?(false)
    }

    /// The global panic stop. Always available while a session is active; the
    /// interface calls this when its shortcut fires.
    public func requestStop() {
        lock.lock()
        let holder = self.holder, stopRequested = self.stopRequested
        lock.unlock()
        stopRequested?(holder)
    }

    public func dispose() {
        lock.lock()
        holder = nil
        let hooks = self.hooks
        lock.unlock()
        hooks.hideIndicator()
        hooks.unregisterStopShortcut()
    }
}
