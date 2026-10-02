import Foundation
import MerryCore

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
