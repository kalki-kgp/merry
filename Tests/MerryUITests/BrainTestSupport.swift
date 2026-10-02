import Foundation
import MerryCore
@testable import MerryUI

// Foundation-using helpers for the workspace tests, kept apart from the file
// that imports Testing.

enum BrainSupport {
    static func snapshot(_ json: JSON) -> BrainSnapshot {
        try! JSONDecoder().decode(BrainSnapshot.self, from: Data(json.stringify().utf8))
    }

    static func timer(_ json: JSON) -> BrainTimer {
        try! JSONDecoder().decode(BrainTimer.self, from: Data(json.stringify().utf8))
    }

    /// The zone and locale the fixtures were recorded in.
    @MainActor static func pin() {
        LocalTime.use(timeZone: "Asia/Kolkata")
        BrainModel.locale = Locale(identifier: "en_US")
    }

    static func isoUTC(_ ms: Double) -> String { JSDate(ms).toISOString() }

    /// Lets work queued on the main actor run.
    static func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }
}
