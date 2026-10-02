import Foundation
import MerryCore

// What Merry says when nobody asked.
//
// Two rules keep this charming rather than annoying or dishonest:
// - Anything about a task is built from the task's real state. It never
//   claims progress it cannot see: "3 of 5 done" only when the plan says so,
//   otherwise it talks about waiting, not about being nearly finished.
// - An offer only ever puts words in the composer. Nothing runs until the
//   person presses Enter.

public struct Line: Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public var label: String
        /// Types a request into the composer.
        public var compose: String?
        /// Just opens the panel.
        public var open: Bool
        public init(label: String, compose: String? = nil, open: Bool = false) { self.label = label; self.compose = compose; self.open = open }
    }

    public var text: String
    public var mood: Mood
    /// A single button on the bubble.
    public var action: Action?

    public init(_ text: String, _ mood: Mood, action: Action? = nil) { self.text = text; self.mood = mood; self.action = action }
}

public enum Personality {
    /// A random number in 0..<1. Tests replace it to make the choices repeatable.
    nonisolated(unsafe) public static var random: () -> Double = { Double.random(in: 0..<1) }

    static func pick<T>(_ xs: [T]) -> T { xs[Int(random() * Double(xs.count)) % xs.count] }

    public static func hello(hour: Int) -> Line {
        if hour >= 5 && hour < 12 { return Line("Morning. Give me a shout when there’s work.", .wave) }
        if hour >= 12 && hour < 17 { return Line("Afternoon. I’m grazing nearby if you need me.", .wave) }
        if hour >= 17 && hour < 22 { return Line("Evening. Anything left on your plate?", .wave) }
        return Line("Up late? I’ll keep you company.", .wave)
    }

    /// The first thing it says when handed a job: a little acknowledgement, tuned to the kind of job.
    public static func onStart(_ request: String) -> Line {
        let r = request.lowercased()
        if Rx("\\b(find|where|search|locate|look for)\\b").test(r) { return Line(pick(["I’ll sniff it out.", "Searching the field.", "Having a look…"]), .determined) }
        if Rx("\\b(organi[sz]e|tidy|clean|sort)\\b").test(r) { return Line(pick(["Tidying time. I love this bit.", "Herding it all into place."]), .determined) }
        if Rx("\\b(rename)\\b").test(r) { return Line("Fresh names coming up.", .determined) }
        if Rx("\\?\\s*$").test(r) { return Line("Hmm. Let me think.", .thinking) }
        return Line(pick(["Right away.", "Consider it handled.", "I’ve got this one."]), .determined)
    }

    /// A kind word during a long job, grounded in what the task actually knows.
    public static func checkIn(seconds: Double, done: Int, total: Int, turn: Int) -> Line {
        if total > 1 && done > 0 { return Line("\(done) of \(total) steps down. Trotting on.", .working) }
        let lines = [
            Line("Not done yet. Thanks for being patient.", .shy),
            Line("Slow going, but I’m still on it.", .nervous),
            Line("Busy over here. You do you.", .determined),
            Line("Going through it line by line.", .reading)
        ]
        return lines[turn % lines.count]
    }

    /// When it has been waiting on an answer for a while.
    public static func nudge() -> Line {
        Line(pick(["Take your time. I’m not going anywhere.", "Ready when you are."]), .shy, action: .init(label: "Answer", open: true))
    }

    /// How a finished job feels: big jobs get a party, quick ones get sunglasses.
    public static func successMood(actions: Int, seconds: Double) -> Mood {
        if actions >= 8 { return .celebrate }
        if actions > 0 && seconds < 4 { return .cool }
        if actions >= 3 { return .starstruck }
        return .proud
    }

    public static func afterSuccess() -> Line? {
        if random() > 0.45 { return nil }
        return pick([
            Line("Got another one for me?", .happy, action: .init(label: "Yes", open: true)),
            Line("Nice bit of work, that.", .music)
        ])
    }

    public static func afterFailure() -> Line {
        Line("That didn’t go to plan. Want the details?", .nervous, action: .init(label: "Show me", open: true))
    }

    public static func tickled() -> Line { Line(pick(["Ha! Not the wool!", "Stop, stop, I’m ticklish.", "Baa-ha-ha."]), .laugh) }
    public static func loved() -> Line { Line(pick(["Aww.", "Softie.", "I’ll remember that."]), .kiss) }
    /// Rubbing the cursor back and forth over it: being petted.
    public static func petted() -> Line { Line(pick(["Mmm. Right there.", "Wool’s extra fluffy today.", "Best shepherd ever."]), .love) }
    public static func picked() -> Line { Line(pick(["Up we go!", "Hey, where to?"]), .surprised) }
    public static func landed(shaken: Bool) -> Line {
        shaken ? Line(pick(["Oof. Give me a second.", "Everything’s wobbling."]), .dizzy) : Line(pick(["Good pasture.", "I like it here."]), .happy)
    }
    public static func carried() -> Line { Line(pick(["A little warning next time?", "Too fast, too fast…"]), .pout) }
    public static func woke() -> Line { Line(pick(["Oh! You’re back.", "Awake. Totally awake."]), .wave) }
    public static func yawn() -> Line { Line("Counting myself to sleep…", .yawn) }
    public static func undone(_ n: Int) -> Line { Line(n != 0 ? "Sorry. Moved \(n) back where they were." : "Nothing to undo.", .oops) }
    public static func hovered() -> Line { Line(pick(["Hey.", "Oh, it’s you."]), .shy) }
    public static func fed(_ n: Int) -> Line { Line(n == 1 ? "What have you brought me?" : "\(n) of them! What’s the plan?", .excited) }
    /// Just after a drop: crunch.
    public static func ate(_ n: Int) -> Line {
        n >= 3 ? Line("A proper feast. Thank you.", .celebrate) : Line(pick(["Munch. Tasty.", "Better than grass."]), .happy)
    }
    public static func danceStart() -> Line { Line("Hoof it!", .music) }
    public static func danceEnd() -> Line { Line("Smooth as ever.", .cool) }
    public static func nap() -> Line { Line("Nap time. Zzz.", .sleepy) }
    public static func napWake() -> Line { Line("Just a bit longer?", .yawn) }

    /// "Surprise me": the party tricks, in turn.
    public static let surprises: [Line] = [
        Line("Shades on. Work off.", .cool),
        Line("Ah… ah… choo!", .sneeze),
        Line("Honestly, you’re brilliant.", .starstruck),
        Line("That’s for looking after me.", .kiss),
        Line("Sorry, thought of something funny.", .laugh),
        Line("Still here, shepherd.", .wave),
        Line("Our little secret.", .wink)
    ]

    /// The occasional unprompted remark while idle. It depends on the hour and
    /// on how long the person has been at their desk; offers only ever fill in
    /// the composer.
    public static func idleRemark(hour: Int, activeMinutes: Double, turn: Int) -> Line {
        if activeMinutes >= 90 && turn % 3 == 0 { return Line("Long stretch at the desk. Stand up for a bit?", .shy) }
        var timely: [Line] = []
        if hour >= 5 && hour < 11 { timely.append(Line("Where do we start today?", .curious, action: .init(label: "Tell me", open: true))) }
        if hour >= 12 && hour < 14 { timely.append(Line("Go eat. I’ll mind things.", .music)) }
        if hour >= 23 || hour < 4 { timely.append(Line("It’s getting late. Bed soon?", .shy)) }
        let general = [
            Line("Shall I sort out your Downloads?", .curious, action: .init(label: "Sure", compose: "Organize my Downloads folder")),
            Line("Lost a file? I can track it down.", .determined, action: .init(label: "Find", compose: "Find ")),
            Line("La la la. Don’t mind me.", .music),
            Line("Choo! Excuse me. Bit of fluff.", .sneeze),
            Line("Nothing to do over here. Got a job?", .bored, action: .init(label: "Sure", open: true)),
            Line("Nice just sitting here with you.", .shy)
        ]
        let pool = timely + general
        return pool[turn % pool.count]
    }
}
