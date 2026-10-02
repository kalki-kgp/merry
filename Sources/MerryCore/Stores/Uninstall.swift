import Foundation

/// Derive only the running app's bundle, never a path supplied by the interface.
public func installedAppBundle(executable: String, packaged: Bool) -> String? {
    if !packaged || !Path.isAbsolute(executable) { return nil }
    let macos = Path.dirname(executable)
    let contents = Path.dirname(macos)
    let bundle = Path.dirname(contents)
    if Path.basename(macos) != "MacOS" || Path.basename(contents) != "Contents" || !bundle.hasSuffix(".app") || Path.basename(bundle) == ".app" { return nil }
    return bundle
}

public struct UninstallDeps: Sendable {
    public var executable: @Sendable () -> String
    public var packaged: @Sendable () -> Bool
    public var confirm: @Sendable () async -> Bool
    public var loginEnabled: @Sendable () -> Bool
    public var setLoginEnabled: @Sendable (Bool) -> Void
    public var stopWork: @Sendable () async throws -> Void
    public var trash: @Sendable (String) async throws -> Void
    public var quit: @Sendable () -> Void

    public init(
        executable: @escaping @Sendable () -> String,
        packaged: @escaping @Sendable () -> Bool,
        confirm: @escaping @Sendable () async -> Bool,
        loginEnabled: @escaping @Sendable () -> Bool,
        setLoginEnabled: @escaping @Sendable (Bool) -> Void,
        stopWork: @escaping @Sendable () async throws -> Void,
        trash: @escaping @Sendable (String) async throws -> Void,
        quit: @escaping @Sendable () -> Void
    ) {
        self.executable = executable; self.packaged = packaged; self.confirm = confirm; self.loginEnabled = loginEnabled
        self.setLoginEnabled = setLoginEnabled; self.stopWork = stopWork; self.trash = trash; self.quit = quit
    }
}

public final class AppUninstaller: @unchecked Sendable {
    private let deps: UninstallDeps
    private let lock = NSLock()
    private var running = false

    public init(deps: UninstallDeps) { self.deps = deps }

    public var inProgress: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public var available: Bool {
        installedAppBundle(executable: deps.executable(), packaged: deps.packaged()) != nil
    }

    /// Claims the one uninstall that may run. False when one already is.
    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func end() { lock.lock(); running = false; lock.unlock() }

    /// Use macOS Trash so removing the app remains recoverable. Keep user data.
    @discardableResult
    public func uninstall() async throws -> Bool {
        if inProgress { throw MerryError("Merry is already being uninstalled.") }
        guard let bundle = installedAppBundle(executable: deps.executable(), packaged: deps.packaged()) else {
            throw MerryError("Uninstall is available in the installed Merry app.")
        }
        if !begin() { throw MerryError("Merry is already being uninstalled.") }
        defer { end() }
        if !(await deps.confirm()) { return false }
        let openedAtLogin = deps.loginEnabled()
        deps.setLoginEnabled(false)
        do {
            try await deps.stopWork()
            try await deps.trash(bundle)
        } catch {
            deps.setLoginEnabled(openedAtLogin)
            throw error
        }
        deps.quit()
        return true
    }
}
