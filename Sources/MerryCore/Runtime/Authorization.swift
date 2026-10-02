import Foundation

/// Directories Merry never touches, whatever the model proposes.
private var forbiddenPrefixes: [String] {
    [
        "/System",
        "/Library/LaunchDaemons",
        "/Library/LaunchAgents",
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/sbin",
        "/private/var/db",
        Path.resolve(Path.home, "Library/Keychains"),
        Path.resolve(Path.home, ".ssh"),
        Path.resolve(Path.home, ".aws"),
        Path.resolve(Path.home, ".gnupg")
    ]
}

/// A scope a tool needs before it may run, checked against task authorization.
public enum ScopeRequest: Equatable, Sendable {
    case read(path: String)
    case write(path: String)
    case app(name: String)
    case origin(url: String)
    case capability(name: String)
}

public struct ScopeDecision: Equatable, Sendable {
    public var allowed: Bool
    /// Populated when `allowed` is false: what to ask the user to grant.
    public var missing: [ScopeRequest]
    /// Set when the request must be refused outright rather than escalated.
    public var refused: String?
}

/// An absolute path with `~` expanded and `.`/`..` collapsed. Symlinks are not followed.
public func normalizePath(_ p: String) -> String {
    guard p.hasPrefix("~") else { return Path.resolve(p) }
    var rest = String(p.dropFirst())
    if rest.hasPrefix("/") || rest.hasPrefix("\\") { rest.removeFirst() }
    return Path.resolve(Path.home, rest)
}

/// True when `child` is `parent` or sits underneath it.
public func isWithin(_ parent: String, _ child: String) -> Bool {
    let p = normalizePath(parent)
    let c = normalizePath(child)
    if p == c { return true }
    return c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
}

public func isForbidden(_ path: String) -> Bool {
    let p = normalizePath(path)
    return forbiddenPrefixes.contains { isWithin($0, p) }
}

/// The origin of a URL the way `new URL(url).origin` gives it, or `nil` when it does not parse.
public func originOf(_ url: String) -> String? {
    guard Schema.isURL(url), let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else { return nil }
    guard ["http", "https", "ftp", "ws", "wss"].contains(scheme) else { return "null" }
    guard let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
    let defaults = ["http": 80, "https": 443, "ftp": 21, "ws": 80, "wss": 443]
    if let port = parts.port, port != defaults[scheme] { return "\(scheme)://\(host):\(port)" }
    return "\(scheme)://\(host)"
}

/// Decides whether the requested scopes fall inside the task's authorization.
///
/// This is deliberately local, deterministic code. No model output, including
/// a confident Jev classification, can stand in for this check.
public func checkScopes(_ auth: Authorization, _ requests: [ScopeRequest]) -> ScopeDecision {
    var missing: [ScopeRequest] = []

    for req in requests {
        switch req {
        case .read(let path), .write(let path):
            if isForbidden(path) {
                return ScopeDecision(allowed: false, missing: [], refused: "\(path) is in a protected system location Merry will not modify.")
            }
            // A write root implies the right to read the same tree.
            let roots: [String]
            if case .read = req { roots = auth.readRoots + auth.writeRoots } else { roots = auth.writeRoots }
            if !roots.contains(where: { isWithin($0, path) }) { missing.append(req) }
        case .app(let name):
            let wanted = name.lowercased()
            if !auth.apps.contains(where: { $0.lowercased() == wanted }) { missing.append(req) }
        case .origin(let url):
            if auth.origins.contains("*") { break }
            guard let origin = originOf(url) else {
                return ScopeDecision(allowed: false, missing: [], refused: "\"\(url)\" is not a valid URL.")
            }
            if !auth.origins.contains(origin) { missing.append(.origin(url: origin)) }
        case .capability(let name):
            if !auth.capabilities.contains(name) { missing.append(req) }
        }
    }

    return ScopeDecision(allowed: missing.isEmpty, missing: missing, refused: nil)
}

/// Folds a user-approved grant into the task's authorization.
public func extendAuthorization(_ auth: Authorization, _ grant: AuthorizationGrant) -> Authorization {
    func merge(_ a: [String], _ b: [String]?) -> [String] { (a + (b ?? [])).unique }
    return Authorization(
        readRoots: merge(auth.readRoots, grant.readRoots?.map(normalizePath)),
        writeRoots: merge(auth.writeRoots, grant.writeRoots?.map(normalizePath)),
        apps: merge(auth.apps, grant.apps),
        origins: merge(auth.origins, grant.origins),
        capabilities: merge(auth.capabilities, grant.capabilities)
    )
}

/// The folder a "yes" covers: a folder itself, or the folder a file sits in.
///
/// Granting only the exact file meant the next file in the same folder asked
/// again: tidying a Desktop once took fifty separate "Allow" clicks. The home
/// folder and the disk root are never widened to: a file sitting directly in
/// either is granted on its own.
public func grantRoot(_ path: String) -> String {
    let p = normalizePath(path)
    var isDir: ObjCBool = false
    // Not there yet means it is about to be created, inside its parent.
    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
    let parent = Path.dirname(p)
    return parent == normalizePath(Path.home) || parent == Path.dirname(parent) ? p : parent
}

/// A folder the way a person names it: "Desktop", "Downloads/Invoices".
private func folderLabel(_ path: String) -> String {
    let home = normalizePath(Path.home)
    if path.hasPrefix(home + "/") { return String(path.dropFirst(home.count + 1)) }
    if path == home { return "your home folder" }
    let base = Path.basename(path)
    return base.isEmpty ? path : base
}

/// Turns missing scopes into a sentence the user can act on.
public func describeMissing(_ missing: [ScopeRequest]) -> String {
    var parts: [String] = []
    var paths: [String] = []
    var writes = false
    for m in missing {
        if case .read(let p) = m { paths.append(p) }
        if case .write(let p) = m { paths.append(p); writes = true }
    }
    if !paths.isEmpty {
        let verb = writes ? "change files in" : "look in"
        let unique = paths.map { folderLabel(grantRoot($0)) }.unique
        parts.append("\(verb) \(unique.prefix(3).joined(separator: ", "))\(unique.count > 3 ? " and \(unique.count - 3) more" : "")")
    }
    for m in missing {
        if case .app(let name) = m { parts.append("control \(name)") }
        if case .origin(let url) = m { parts.append("visit \(url)") }
        if case .capability(let name) = m { parts.append("use \(name)") }
    }
    return parts.joined(separator: ", ")
}

/// Converts missing scopes into the grant that would satisfy them.
public func grantFor(_ missing: [ScopeRequest]) -> AuthorizationGrant {
    var grant = AuthorizationGrant(readRoots: [], writeRoots: [], apps: [], origins: [], capabilities: [])
    for m in missing {
        switch m {
        case .read(let path): grant.readRoots!.append(grantRoot(path))
        case .write(let path): grant.writeRoots!.append(grantRoot(path))
        case .app(let name): grant.apps!.append(name)
        case .origin(let url): grant.origins!.append(url)
        case .capability(let name): grant.capabilities!.append(name)
        }
    }
    return grant
}
