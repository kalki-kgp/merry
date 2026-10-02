import Foundation

/// External result links may open web pages, never OS protocol handlers.
/// Returns the address in the form `new URL(value).href` gives it.
public func externalWebUrl(_ value: String?) throws -> String {
    guard let value else { throw MerryError("A web address is required.") }
    let trimmed = value.jsTrimmed
    guard Schema.isURL(trimmed), let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased() else {
        throw MerryError("Invalid URL")
    }
    guard scheme == "https" || scheme == "http" else { throw MerryError("Only HTTP and HTTPS links can be opened.") }
    var normal = parts
    normal.scheme = scheme
    normal.host = parts.host?.lowercased()
    if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { normal.port = nil }
    if normal.path.isEmpty { normal.path = "/" }
    return normal.string ?? trimmed
}
