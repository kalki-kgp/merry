import Foundation

/// The calendar all local-time arithmetic goes through. Tests pin its time
/// zone so date logic gives the same answers on any machine.
public enum LocalTime {
    nonisolated(unsafe) public static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    public static func use(timeZone identifier: String) {
        if let zone = TimeZone(identifier: identifier) { calendar.timeZone = zone }
    }
}

/// JavaScript's `Date`: an instant in milliseconds, read and changed in local
/// time. Setters overflow the way JavaScript's do (`setDate(32)` rolls into
/// the next month), which the reference's date arithmetic relies on.
public struct JSDate: Equatable, Comparable, Sendable {
    /// Milliseconds since 1970, like `getTime()`.
    public var time: Double

    public init() { time = nowMs() }
    public init(_ ms: Double) { time = ms }
    public init(_ date: Date) { time = (date.timeIntervalSince1970 * 1000).rounded() }

    /// `new Date(year, monthIndex, day, hours, minutes, seconds)` in local time.
    public init(year: Int, month: Int, day: Int = 1, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, ms: Int = 0) {
        var parts = DateComponents()
        parts.year = year; parts.month = month + 1; parts.day = day
        parts.hour = hours; parts.minute = minutes; parts.second = seconds
        let date = LocalTime.calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        time = (date.timeIntervalSince1970 * 1000).rounded() + Double(ms)
    }

    /// `new Date(isoString)`. Returns nil for text that does not parse.
    public init?(iso text: String) {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { self.init(d); return }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { self.init(d); return }
        // A date with no time is UTC midnight; a date-time with no zone is local.
        if let m = Rx("^(\\d{4})-(\\d{2})-(\\d{2})$").exec(text) {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            guard let d = utc.date(from: DateComponents(year: Int(m[1]!), month: Int(m[2]!), day: Int(m[3]!))) else { return nil }
            self.init(d); return
        }
        if let m = Rx("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.(\\d{1,3}))?)?$").exec(text) {
            let fraction = m[7].map { Int($0.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0 } ?? 0
            self.init(year: Int(m[1]!)!, month: Int(m[2]!)! - 1, day: Int(m[3]!)!, hours: Int(m[4]!)!, minutes: Int(m[5]!)!, seconds: Int(m[6] ?? "0") ?? 0, ms: fraction)
            return
        }
        return nil
    }

    public var date: Date { Date(timeIntervalSince1970: time / 1000) }
    public static func < (a: JSDate, b: JSDate) -> Bool { a.time < b.time }

    private var parts: DateComponents {
        LocalTime.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }

    public var fullYear: Int { parts.year ?? 1970 }
    /// 0 for January, like `getMonth()`.
    public var month: Int { (parts.month ?? 1) - 1 }
    /// Day of the month, like `getDate()`.
    public var day: Int { parts.day ?? 1 }
    /// 0 for Sunday, like `getDay()`.
    public var weekday: Int { (parts.weekday ?? 1) - 1 }
    public var hours: Int { parts.hour ?? 0 }
    public var minutes: Int { parts.minute ?? 0 }
    public var seconds: Int { parts.second ?? 0 }
    public var milliseconds: Int { Int(time.truncatingRemainder(dividingBy: 1000) + 1000) % 1000 }

    private mutating func rebuild(year: Int? = nil, month: Int? = nil, day: Int? = nil, hours: Int? = nil, minutes: Int? = nil, seconds: Int? = nil, ms: Int? = nil) {
        self = JSDate(year: year ?? fullYear, month: month ?? self.month, day: day ?? self.day, hours: hours ?? self.hours,
                      minutes: minutes ?? self.minutes, seconds: seconds ?? self.seconds, ms: ms ?? milliseconds)
    }

    public mutating func setFullYear(_ y: Int) { rebuild(year: y) }
    public mutating func setMonth(_ m: Int, _ d: Int? = nil) { rebuild(month: m, day: d) }
    public mutating func setDate(_ d: Int) { rebuild(day: d) }
    public mutating func setHours(_ h: Int, _ m: Int? = nil, _ s: Int? = nil, _ ms: Int? = nil) { rebuild(hours: h, minutes: m, seconds: s, ms: ms) }
    public mutating func setMinutes(_ m: Int, _ s: Int? = nil, _ ms: Int? = nil) { rebuild(minutes: m, seconds: s, ms: ms) }
    public mutating func setSeconds(_ s: Int, _ ms: Int? = nil) { rebuild(seconds: s, ms: ms) }

    /// A copy changed by `change`, for the common "clone then set" pattern.
    public func with(_ change: (inout JSDate) -> Void) -> JSDate { var copy = self; change(&copy); return copy }

    /// `toISOString()`: UTC, with milliseconds.
    public func toISOString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// `toDateString()`: "Fri Oct 02 2026".
    public func toDateString() -> String { format("EEE MMM dd yyyy") }

    /// Local time through a fixed `DateFormatter` pattern, in English.
    public func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.calendar = LocalTime.calendar
        f.timeZone = LocalTime.calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
