import Foundation

/// Runs programs the way Node's `execFile` does: an executable and an argument
/// array, never a shell string, so nothing in an argument is ever interpreted.
public enum Exec {
    public struct Result: Sendable {
        public var stdout: String
        public var stderr: String
        public var code: Int32
        /// The process was killed for running past its timeout.
        public var timedOut: Bool
        /// Output was cut off at the byte limit.
        public var truncated: Bool
        public var ok: Bool { code == 0 && !timedOut }
    }

    /// Runs `path` with `args` and collects its output. A non-zero exit is
    /// returned, not thrown; only failing to start the program throws.
    public static func run(
        _ path: String,
        _ args: [String] = [],
        cwd: String? = nil,
        env: [String: String]? = nil,
        input: String? = nil,
        timeoutMs: Int? = nil,
        maxBytes: Int = 10 * 1024 * 1024
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        let state = Collector(maxBytes: maxBytes)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; state.close(.out) } else { state.append(data, to: .out) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; state.close(.err) } else { state.append(data, to: .err) }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            state.onFinished = { result in continuation.resume(returning: result) }
            process.terminationHandler = { p in state.exited(code: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: MerryError("could not run \(Path.basename(path)): \(error.localizedDescription)"))
                return
            }
            if let input {
                DispatchQueue.global().async {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            if let timeoutMs {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                    guard process.isRunning else { return }
                    state.markTimedOut()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1500)) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    /// Like `run`, but a non-zero exit or a timeout throws with what the program said.
    public static func checked(
        _ path: String, _ args: [String] = [], cwd: String? = nil, env: [String: String]? = nil,
        input: String? = nil, timeoutMs: Int? = nil, maxBytes: Int = 10 * 1024 * 1024
    ) async throws -> String {
        let r = try await run(path, args, cwd: cwd, env: env, input: input, timeoutMs: timeoutMs, maxBytes: maxBytes)
        if r.timedOut { throw MerryError("\(Path.basename(path)) timed out after \(timeoutMs ?? 0)ms") }
        if r.code != 0 {
            let said = r.stderr.jsTrimmed.isEmpty ? r.stdout.jsTrimmed : r.stderr.jsTrimmed
            throw MerryError(said.isEmpty ? "\(Path.basename(path)) exited with code \(r.code)" : said)
        }
        return r.stdout
    }

    /// Where a program lives, searching the places a login shell would: the
    /// app's own PATH is the bare system one, so Homebrew and per-user installs
    /// have to be looked for by hand.
    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let fromEnv = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = Path.home
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.opencode/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in (fromEnv + extra).unique {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The environment a spawned program should see: this process's, with the
    /// usual install locations added to PATH.
    public static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = Path.home
        let wanted = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (current + wanted).unique.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = home }
        for (k, v) in extra { env[k] = v }
        return env
    }

    private final class Collector: @unchecked Sendable {
        enum Stream { case out, err }
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var outClosed = false, errClosed = false
        private var code: Int32?
        private var timedOut = false
        private var truncated = false
        private var finished = false
        private let maxBytes: Int
        var onFinished: ((Result) -> Void)?

        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func append(_ data: Data, to stream: Stream) {
            lock.lock(); defer { lock.unlock() }
            switch stream {
            case .out:
                if out.count + data.count > maxBytes { out.append(data.prefix(max(0, maxBytes - out.count))); truncated = true } else { out.append(data) }
            case .err:
                if err.count + data.count > maxBytes { err.append(data.prefix(max(0, maxBytes - err.count))); truncated = true } else { err.append(data) }
            }
        }

        func close(_ stream: Stream) {
            lock.lock()
            if stream == .out { outClosed = true } else { errClosed = true }
            let done = finishIfReady()
            lock.unlock()
            done?()
        }

        func exited(code: Int32) {
            lock.lock()
            self.code = code
            let done = finishIfReady()
            lock.unlock()
            done?()
            // A grandchild holding the pipe open must not hold the result hostage.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { [self] in
                lock.lock()
                outClosed = true; errClosed = true
                let late = finishIfReady()
                lock.unlock()
                late?()
            }
        }

        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

        /// Call with the lock held. Returns the completion to run once it is released.
        private func finishIfReady() -> (() -> Void)? {
            guard !finished, let code, outClosed, errClosed else { return nil }
            finished = true
            let result = Result(stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), code: code, timedOut: timedOut, truncated: truncated)
            let callback = onFinished
            return { callback?(result) }
        }
    }
}
