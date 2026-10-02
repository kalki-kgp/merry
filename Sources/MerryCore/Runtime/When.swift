import Foundation

// Reads times out of everyday phrasing ("tomorrow at 5", "next friday 3pm",
// "in 20 minutes", "tonight") with no model involved.
//
// The one genuinely ambiguous case, an hour with no am/pm ("at 5"), is not
// guessed here: both readings come back as candidates, so a caller can let
// Jev pick between them using the rest of the sentence, and fall back to the
// plain default (the next one to come round) when Jev is unavailable.

public struct TimeReading: Equatable, Sendable {
    /// Candidate moments, most likely first. Always at least one.
    public var candidates: [JSDate]
    /// True when only a day was named ("on friday"), with no time of day.
    public var dateOnly: Bool
    /// The phrase that was read, so it can be removed from a title.
    public var matched: [String]
    /// An explicit duration ("for 30 minutes"), in minutes.
    public var durationMin: Double?

    public init(candidates: [JSDate], dateOnly: Bool, matched: [String], durationMin: Double? = nil) {
        self.candidates = candidates; self.dateOnly = dateOnly; self.matched = matched; self.durationMin = durationMin
    }
}

private let WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
private let MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
private let PARTS: [String: Int] = ["morning": 9, "noon": 12, "midday": 12, "afternoon": 15, "evening": 18, "tonight": 20, "night": 20, "midnight": 0]
private let UNIT_MIN: [String: Double] = ["min": 1, "minute": 1, "minutes": 1, "mins": 1, "hour": 60, "hours": 60, "hr": 60, "hrs": 60, "h": 60, "day": 1440, "days": 1440, "week": 10080, "weeks": 10080]

private func atDay(_ base: JSDate, _ offsetDays: Int) -> JSDate {
    var d = base
    d.setHours(0, 0, 0, 0)
    d.setDate(d.day + offsetDays)
    return d
}

private func withTime(_ day: JSDate, _ h: Int, _ m: Int) -> JSDate {
    var d = day
    d.setHours(h, m, 0, 0)
    return d
}

private enum Clock {
    static let duration = Rx.ecma("\\bfor (?:an? |(\\d+(?:\\.\\d+)?) ?)(min(?:ute)?s?|hours?|hrs?|h)\\b")
    static let relative = Rx.ecma("\\bin (?:an? |(\\d+(?:\\.\\d+)?) ?)(min(?:ute)?s?|hours?|hrs?|h|days?|weeks?)\\b")
    static let dayAfter = Rx.ecma("\\bday after tomorrow\\b")
    static let tomorrow = Rx.ecma("\\b(?:tomorrow|tmrw|tmr)\\b")
    static let today = Rx.ecma("\\btoday\\b")
    static let weekday = Rx.ecma("\\b(?:(next|this|on|coming) )?(\(WEEKDAYS.joined(separator: "|")))\\b")
    static let monthDay = Rx.ecma("\\b(?:(\\d{1,2})(?:st|nd|rd|th)? (\(MONTHS.joined(separator: "|")))[a-z]*|(\(MONTHS.joined(separator: "|")))[a-z]* (\\d{1,2})(?:st|nd|rd|th)?)\\b")
    static let time = Rx.ecma("\\b(?:at |@ ?|by )?(\\d{1,2})(?::(\\d{2}))? ?(am|pm|a\\.m\\.|p\\.m\\.)?(?= |$)")
    static let introduced = Rx.ecma("^(at|@|by)")
    static let morning = Rx.ecma("\\b(morning|am)\\b")
    static let later = Rx.ecma("\\b(afternoon|evening|tonight|night|pm)\\b")
    static let part = Rx.ecma("\\b(?:this |tomorrow )?(morning|noon|midday|afternoon|evening|tonight|night|midnight)\\b")
}

/// `new Date(ms)`: whole milliseconds, and no date at all beyond the range JavaScript allows.
private func dateAt(_ ms: Double) -> JSDate {
    JSDate(ms.isFinite && abs(ms) <= 8.64e15 ? ms.rounded(.towardZero) : .nan)
}

public func readTime(_ text: String, now: JSDate = JSDate()) -> TimeReading? {
    let t = " \(text.lowercased().replacingOccurrences(of: ",", with: " ")) "
    var matched: [String] = []
    func take(_ re: Rx) -> Rx.Match? {
        let m = re.exec(t)
        if let m { matched.append(m.text.ecmaTrimmed) }
        return m
    }

    var durationMin: Double?
    if let dur = take(Clock.duration) {
        durationMin = (dur[1].map { Double($0) ?? .nan } ?? 1) * (UNIT_MIN[dur[2]!] ?? 60)
    }

    // "in 20 minutes", "in an hour", "in 2 days"
    if let rel = take(Clock.relative) {
        let mins = (rel[1].map { Double($0) ?? .nan } ?? 1) * (UNIT_MIN[rel[2]!] ?? 1)
        return TimeReading(candidates: [dateAt(now.time + mins * 60_000)], dateOnly: false, matched: matched, durationMin: durationMin)
    }

    // Which day.
    var day: JSDate?
    var dayNamed = false
    /// "friday" said on a Friday: today if the time is still ahead, else next week.
    var weekdayIsToday = false
    if take(Clock.dayAfter) != nil { day = atDay(now, 2); dayNamed = true }
    else if take(Clock.tomorrow) != nil { day = atDay(now, 1); dayNamed = true }
    else if take(Clock.today) != nil { day = atDay(now, 0); dayNamed = true }
    if day == nil, let wd = take(Clock.weekday) {
        let target = WEEKDAYS.firstIndex(of: wd[2]!)!
        var diff = (target - now.weekday + 7) % 7
        // "next friday" is read as the coming friday, which is what people usually mean.
        if diff == 0 {
            if wd[1] == "next" { diff = 7 } else { weekdayIsToday = true }
        }
        day = atDay(now, diff)
        dayNamed = true
    }
    if day == nil, let md = take(Clock.monthDay) {
        // "sep 30", "30 sep", "september 30th"
        let month = MONTHS.firstIndex(of: (md[2] ?? md[3])!)!
        let date = Int((md[1] ?? md[4])!)!
        var d = JSDate(year: now.fullYear, month: month, day: date)
        if d.time < atDay(now, 0).time { d.setFullYear(d.fullYear + 1) }
        day = d
        dayNamed = true
    }

    // Which time.
    var hours: [Int]?
    var minutes = 0
    let clock = take(Clock.time)
    // A bare number only counts as a time when "at"/"by" introduced it or it
    // has minutes or am/pm; "call 3 people" is not about 3 o'clock.
    let clockCounts = clock.map { Clock.introduced.test($0.text) || $0[2] != nil || $0[3] != nil } ?? false
    if clock != nil && !clockCounts { matched.removeLast() }
    if let clock, clockCounts {
        var h = Int(clock[1]!)!
        minutes = clock[2].map { Int($0)! } ?? 0
        let mer = clock[3]?.replacingOccurrences(of: ".", with: "")
        if h > 23 || minutes > 59 { return nil }
        if mer == "pm" && h < 12 { h += 12 }
        if mer == "am" && h == 12 { h = 0 }
        if mer != nil || h > 12 || h == 0 { hours = [h] }
        else if Clock.morning.test(t) { hours = [h == 12 ? 0 : h] }
        else if Clock.later.test(t) { hours = [h == 12 ? 12 : h + 12] }
        // "at 5" with nothing else: both readings, the one people usually mean first.
        // 8–11 lean morning; 1–7 lean afternoon or evening ("call mom at 7").
        else { hours = h >= 8 && h <= 11 ? [h, h + 12] : h == 12 ? [12, 0] : [h + 12, h] }
    } else if let part = take(Clock.part) {
        hours = [PARTS[part[1]!]!]
        if part[1] == "tonight" && day == nil { day = atDay(now, 0); dayNamed = true }
    }

    if !dayNamed && hours == nil { return nil }

    var candidates: [JSDate] = []
    if let hours {
        for h in hours {
            var d = withTime(day ?? atDay(now, 0), h, minutes)
            // No day named and that time has passed today: the next one.
            if !dayNamed && d.time <= now.time { d = withTime(atDay(now, 1), h, minutes) }
            if weekdayIsToday && d.time <= now.time { d = withTime(atDay(now, 7), h, minutes) }
            candidates.append(d)
        }
        // Without a named day, the soonest reading is the likeliest.
        if !dayNamed { candidates.sort { $0.time < $1.time } }
    } else {
        candidates.append(day!)
    }
    return TimeReading(candidates: candidates, dateOnly: hours == nil, matched: matched, durationMin: durationMin)
}

private let NUMBER_WORDS: [(String, Int)] = [
    ("a", 1), ("an", 1), ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10),
    ("eleven", 11), ("twelve", 12), ("fifteen", 15), ("twenty", 20), ("twenty-five", 25), ("thirty", 30), ("forty", 40), ("forty-five", 45),
    ("fifty", 50), ("sixty", 60), ("ninety", 90)
]
private let NUMBER_VALUES = Dictionary(uniqueKeysWithValues: NUMBER_WORDS)
private let SPELLED = Rx.ecma("\\b(\(NUMBER_WORDS.map(\.0).joined(separator: "|")))(?=[ -](?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\\b)", "i")

/// Spelled-out durations as digits: "one minute" → "1 minute", "an hour" →
/// "1 hour", "half an hour" → "30 minutes". Only a number directly in front
/// of a unit is touched, so "someone" and "a timer" stay as they are.
public func spelledDurations(_ text: String) -> String {
    SPELLED.replaceAll(Rx.ecma("\\bhalf an? hour\\b", "i").replaceAll(text, "30 minutes")) { String(NUMBER_VALUES[$0.text.lowercased()]!) }
}

/// Removes the time phrases (and the glue words around them) from a title.
public func stripTime(_ text: String, _ reading: TimeReading?) -> String {
    var out = " \(text) "
    for phrase in reading?.matched ?? [] {
        // Compiled directly: a pattern made from what someone typed has no place in the pattern cache.
        let pattern = Rx.ecmaSource("\\s\(Rx.ecmaEscape(phrase))(?=[\\s,.!?])", "i")
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
        let ns = out as NSString
        if let m = re.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) {
            out = ns.replacingCharacters(in: m.range, with: " ")
        }
    }
    out = Rx.ecma("\\s+(?:on|at|by|for|in)\\s*$", "i").replaceFirst(out, "")
    out = Rx.ecma("\\s{2,}").replaceAll(out, " ")
    return Rx.ecma("^[\\s,.:;-]+|[\\s,.:;!-]+$").replaceAll(out, "")
}

/// "Tue 30 Sep, 5:00 pm": how a time is shown back to the person.
public func describeTime(_ d: JSDate, dateOnly: Bool = false, now: JSDate = JSDate()) -> String {
    let today = atDay(now, 0).time
    let day = atDay(d, 0).time
    let dayLabel = day == today ? "today" : day == today + 86_400_000 ? "tomorrow" : d.format("EEE, MMM d")
    if dateOnly { return dayLabel }
    let h = d.hours
    let time = "\(h % 12 == 0 ? 12 : h % 12):\(String(d.minutes).jsPadStart(2, "0")) \(h < 12 ? "am" : "pm")"
    return "\(dayLabel) at \(time)"
}
