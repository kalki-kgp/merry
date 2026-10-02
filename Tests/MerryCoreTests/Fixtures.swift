import Foundation
@testable import MerryCore

/// Golden outputs recorded from a reference run.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func load(_ name: String) -> JSON {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data) else {
            fatalError("missing fixture \(name).json")
        }
        return json
    }
}

extension JSON {
    /// Where two values first differ, as a path, for a readable failure.
    func firstDifference(from other: JSON, at path: String = "$") -> String? {
        switch (self, other) {
        case (.object(let a), .object(let b)):
            for key in Set(a.keys).union(b.keys).sorted() {
                guard let x = a[key] else { return "\(path).\(key): missing, expected \(b[key]!.stringify().prefix(200))" }
                guard let y = b[key] else { return "\(path).\(key): unexpected \(x.stringify().prefix(200))" }
                if let d = x.firstDifference(from: y, at: "\(path).\(key)") { return d }
            }
            return nil
        case (.array(let a), .array(let b)):
            if a.count != b.count { return "\(path): \(a.count) items, expected \(b.count)" }
            for (i, (x, y)) in zip(a, b).enumerated() {
                if let d = x.firstDifference(from: y, at: "\(path)[\(i)]") { return d }
            }
            return nil
        default:
            return self == other ? nil : "\(path): \(stringify().prefix(200)), expected \(other.stringify().prefix(200))"
        }
    }
}
