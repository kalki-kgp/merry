import Foundation

/// Node's `path` module for POSIX, which the reference's file logic is written
/// against. These are pure string operations: nothing here touches the disk or
/// follows a symlink, exactly like the functions they replace.
public enum Path {
    /// The real home folder, not a sandbox container's.
    public static var home: String {
        if let scoped = scopedHome { return scoped }
        if let override = homeOverride { return override }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Lets tests run against a scratch home folder.
    nonisolated(unsafe) public static var homeOverride: String?

    /// A home folder for the current task only: `Path.$scopedHome.withValue(dir) { ... }`.
    /// Tests run in parallel, and a process-wide override set by one leaks into the others.
    @TaskLocal public static var scopedHome: String?

    public static var tmp: String {
        let t = NSTemporaryDirectory()
        return t.count > 1 && t.hasSuffix("/") ? String(t.dropLast()) : t
    }

    public static var cwd: String { FileManager.default.currentDirectoryPath }

    /// `path.normalize`: collapses `.`, `..` and repeated slashes.
    public static func normalize(_ path: String) -> String {
        if path.isEmpty { return "." }
        let absolute = path.hasPrefix("/")
        let trailing = path.hasSuffix("/")
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if !absolute { out.append(part) }
                continue
            }
            out.append(part)
        }
        var joined = out.joined(separator: "/")
        if joined.isEmpty && !absolute { joined = "." }
        if trailing && !joined.isEmpty && joined != "." { joined += "/" }
        return absolute ? "/" + joined : joined
    }

    /// `path.resolve(...parts)`: an absolute path, later absolute parts winning.
    public static func resolve(_ parts: String...) -> String { resolve(parts) }

    public static func resolve(_ parts: [String]) -> String {
        var resolved = ""
        for part in parts.reversed() where !part.isEmpty {
            resolved = resolved.isEmpty ? part : part + "/" + resolved
            if part.hasPrefix("/") { break }
        }
        if !resolved.hasPrefix("/") { resolved = resolved.isEmpty ? cwd : cwd + "/" + resolved }
        let normal = normalize(resolved)
        return normal.count > 1 && normal.hasSuffix("/") ? String(normal.dropLast()) : normal
    }

    /// `path.join(...parts)`.
    public static func join(_ parts: String...) -> String { join(parts) }

    public static func join(_ parts: [String]) -> String {
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "." : normalize(joined)
    }

    /// `path.dirname`.
    public static func dirname(_ path: String) -> String {
        let chars = Array(path.utf8)
        if chars.isEmpty { return "." }
        let slash = UInt8(ascii: "/")
        let hasRoot = chars[0] == slash
        var end = -1
        var matchedSlash = true
        var i = chars.count - 1
        while i >= 1 {
            if chars[i] == slash {
                if !matchedSlash { end = i; break }
            } else {
                matchedSlash = false
            }
            i -= 1
        }
        if end == -1 { return hasRoot ? "/" : "." }
        if hasRoot && end == 1 { return "//" }
        return String(decoding: chars[0..<end], as: UTF8.self)
    }

    /// `path.basename(path, suffix)`.
    public static func basename(_ path: String, _ suffix: String? = nil) -> String {
        var end = path.endIndex
        while end > path.startIndex, path[path.index(before: end)] == "/" { end = path.index(before: end) }
        let trimmed = path[..<end]
        let base = trimmed.lastIndex(of: "/").map { String(trimmed[trimmed.index(after: $0)...]) } ?? String(trimmed)
        if let suffix, !suffix.isEmpty, base != suffix, base.hasSuffix(suffix) { return String(base.dropLast(suffix.count)) }
        return base
    }

    /// `path.extname`: the last dot onwards, or "" for none and for dotfiles.
    public static func extname(_ path: String) -> String {
        let base = basename(path)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        // ".." and "name." follow Node: ".." has no extension, "name." has ".".
        if base == ".." { return "" }
        return String(base[dot...])
    }

    public static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

    /// `path.relative(from, to)`.
    public static func relative(_ from: String, _ to: String) -> String {
        let a = resolve(from).split(separator: "/")
        let b = resolve(to).split(separator: "/")
        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] { shared += 1 }
        let up = Array(repeating: "..", count: a.count - shared)
        return (up + b[shared...].map(String.init)).joined(separator: "/")
    }
}
