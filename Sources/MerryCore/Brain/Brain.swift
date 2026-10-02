import Foundation

// Merry's own workspace: what the person keeps with it, and the focus timer.

public struct BrainSource: Codable, Equatable, Sendable {
    /// path | url
    public var kind: String
    public var label: String
    public var value: String
    public init(kind: String, label: String, value: String) { self.kind = kind; self.label = label; self.value = value }
}

public struct BrainItem: Codable, Equatable, Sendable, Identifiable {
    /// note | task | reminder | project | bookmark | session | tracker
    public var kind: String
    public var title: String
    public var body: String
    public var projectId: String?
    public var dueAt: Double?
    /// none | daily | weekly
    public var `repeat`: String
    public var estimateMinutes: Int?
    public var sources: [BrainSource]
    public var id: String
    /// open | done | archived
    public var status: String
    public var createdAt: Double
    public var updatedAt: Double
    public var notifiedAt: Double?
    public var acknowledgedAt: Double?
    /// Days a tracker was checked in on, as yyyy-mm-dd.
    public var checks: [String]

    enum CodingKeys: String, CodingKey {
        case kind, title, body, projectId, dueAt, `repeat`, estimateMinutes, sources, id, status, createdAt, updatedAt, notifiedAt, acknowledgedAt, checks
    }

    // The nullable fields are written as null, not left out: stored rows are
    // queried with json_extract(...) IS NULL, and an update of {dueAt: null}
    // has to be told apart from no update.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title); try c.encode(body, forKey: .body)
        try c.encode(projectId, forKey: .projectId); try c.encode(dueAt, forKey: .dueAt); try c.encode(`repeat`, forKey: .repeat)
        try c.encode(estimateMinutes, forKey: .estimateMinutes); try c.encode(sources, forKey: .sources); try c.encode(id, forKey: .id)
        try c.encode(status, forKey: .status); try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(notifiedAt, forKey: .notifiedAt); try c.encode(acknowledgedAt, forKey: .acknowledgedAt); try c.encode(checks, forKey: .checks)
    }
}

public struct BrainTimer: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var durationMs: Double
    public var remainingMs: Double
    public var endsAt: Double?
    /// running | paused | ringing
    public var status: String
    public var notifiedAt: Double?

    public init(id: String, label: String, durationMs: Double, remainingMs: Double, endsAt: Double?, status: String, notifiedAt: Double?) {
        self.id = id; self.label = label; self.durationMs = durationMs; self.remainingMs = remainingMs
        self.endsAt = endsAt; self.status = status; self.notifiedAt = notifiedAt
    }

    enum CodingKeys: String, CodingKey { case id, label, durationMs, remainingMs, endsAt, status, notifiedAt }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label); try c.encode(durationMs, forKey: .durationMs)
        try c.encode(remainingMs, forKey: .remainingMs); try c.encode(endsAt, forKey: .endsAt); try c.encode(status, forKey: .status)
        try c.encode(notifiedAt, forKey: .notifiedAt)
    }

    /// Milliseconds left, whatever state the timer is in.
    public func remaining(now: Double = nowMs()) -> Double {
        switch status {
        case "running": return min(durationMs, max(0, (endsAt ?? now) - now))
        case "ringing": return 0
        default: return remainingMs
        }
    }

    /// The time left as mm:ss.
    public func label(now: Double = nowMs()) -> String {
        let seconds = Int((remaining(now: now) / 1000).rounded(.up))
        return "\(String(seconds / 60).jsPadStart(2, "0")):\(String(seconds % 60).jsPadStart(2, "0"))"
    }
}

public struct BrainSnapshot: Codable, Equatable, Sendable {
    public var items: [BrainItem]
    public var timer: BrainTimer?

    public init(items: [BrainItem] = [], timer: BrainTimer? = nil) { self.items = items; self.timer = timer }

    enum CodingKeys: String, CodingKey { case items, timer }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items); try c.encode(timer, forKey: .timer)
    }

    /// Open reminders whose time has come and that nobody has acknowledged, soonest first.
    public func dueItems(now: Double = nowMs()) -> [BrainItem] {
        items.filter { $0.status == "open" && $0.dueAt != nil && $0.dueAt! <= now && $0.acknowledgedAt == nil }
            .sorted { $0.dueAt! < $1.dueAt! }
    }
}

/// A local calendar day as yyyy-mm-dd.
public func dayKey(_ now: Double = nowMs()) -> String {
    let parts = LocalTime.calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: now / 1000))
    return "\(parts.year ?? 0)-\(String(parts.month ?? 0).jsPadStart(2, "0"))-\(String(parts.day ?? 0).jsPadStart(2, "0"))"
}
