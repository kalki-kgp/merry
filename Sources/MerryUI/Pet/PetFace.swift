import Foundation
import MerryCore

// Merry is a small lamb: a cloud of wool, a dark face, two curled horns and a
// bell. The face carries the feeling and the bell carries the colour of it.

/// Everything Merry can show. Runtime state picks a default (see `Mood.forState`);
/// the pet window layers the moment-to-moment ones (being hovered, dragged,
/// fed a file, left alone) on top.
public enum Mood: String, CaseIterable, Sendable {
    case idle, happy, excited, listening, curious, thinking, working, straining
    case waiting, proud, sad, oops, sleepy, dizzy, love, surprised, wink
    case wave, laugh, shy, bored, yawn, cool, starstruck, music, reading
    case skeptical, nervous, celebrate, kiss, pout, sneeze, determined

    public static func forState(_ state: PetState) -> Mood {
        switch state {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .working: return .working
        case .waiting: return .waiting
        case .finished: return .proud
        case .failed: return .sad
        }
    }
}

/// Where the eyes are looking, each axis from -1 to 1.
public struct Look: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
}

public enum PetFace {
    public static let gold = "#ffc94d"
    public static let amber = "#ff9f43"
    public static let coral = "#ff6b5e"
    public static let pink = "#ff8fb8"
    public static let sky = "#7cc4ff"

    public enum Eye: Sendable {
        case open, shut, happy, wide, narrow, droop, squeezeLeft, squeezeRight, cross, heart, star, half, hidden
    }

    public enum Mouth: Sendable {
        case smile, grin, small, round, flat, frown, wobble, smirk, kiss, none
    }

    public enum Brows: Sendable { case none, set, cross, raised }

    /// One frame of a face.
    public struct Features: Sendable {
        public var left = Eye.open
        public var right = Eye.open
        public var mouth = Mouth.smile
        /// A small sign floating by the head: "?", "!", "z", a heart, a note, a spark.
        public var mark: String?
        /// How far the mark has drifted upward, 0...1.
        public var markRise = 0.0
        public var brows = Brows.none
        public var blush = false
        public var sweat = false
        public var tears = false
        public var shades = false
        public var confetti = false
        /// Dots above the head while it thinks or works: how many are lit.
        public var dots: Int?
        /// Whether the eyes follow the pointer.
        public var tracks = false
        /// A fixed gaze for moods that do not follow the pointer.
        public var gaze = Look()
    }

    /// The colour of a mood's bell, glow and marks.
    public static func accent(_ mood: Mood) -> String {
        switch mood {
        case .listening, .curious, .thinking, .sleepy, .laugh, .bored, .yawn, .reading, .skeptical, .sneeze: return sky
        case .straining, .waiting, .oops, .dizzy, .surprised, .nervous: return amber
        case .sad, .pout: return coral
        case .love, .shy, .kiss: return pink
        default: return gold
        }
    }

    /// Moods whose picture changes over time, and how fast, in milliseconds.
    public static func frameMs(_ mood: Mood) -> Int? {
        switch mood {
        case .working: return 220
        case .straining: return 160
        case .thinking: return 380
        case .waiting, .music, .kiss, .love: return 420
        case .excited, .proud, .starstruck: return 300
        case .sad, .cool: return 500
        case .oops, .wave: return 260
        case .sleepy, .bored: return 900
        case .dizzy, .celebrate: return 160
        case .laugh: return 140
        case .yawn: return 380
        case .reading: return 520
        case .nervous: return 180
        case .sneeze: return 330
        default: return nil
        }
    }

    /// What the face looks like for a mood at frame `t`.
    public static func features(_ mood: Mood, t: Int = 0, blinking: Bool = false) -> Features {
        var f = Features()
        switch mood {
        case .idle: f.tracks = true
        case .happy: f.left = .happy; f.right = .happy; f.mouth = .grin
        case .excited: f.left = .wide; f.right = .wide; f.mouth = .round; f.mark = t % 2 == 0 ? "✦" : nil
        case .listening: f.mouth = .small; f.tracks = true
        case .curious: f.left = .wide; f.mouth = .smirk; f.tracks = true; f.brows = .raised
        case .thinking: f.mouth = .none; f.gaze = Look(x: 0.8, y: -0.8); f.dots = t % 4
        case .working: f.left = .narrow; f.right = .narrow; f.mouth = .flat; f.tracks = true; f.dots = t % 4
        case .straining: f.left = .narrow; f.right = .narrow; f.mouth = .wobble; f.sweat = true; f.dots = t % 4
        case .waiting: f.left = .wide; f.right = .wide; f.mouth = .small; f.tracks = true; f.mark = t % 4 == 3 ? nil : "?"
        case .proud: f.left = .happy; f.right = .happy; f.mouth = .grin; f.mark = t % 2 == 0 ? "✦" : nil
        case .sad: f.left = .droop; f.right = .droop; f.mouth = .frown; f.tears = true
        case .oops: f.left = .squeezeLeft; f.right = .squeezeRight; f.mouth = .wobble; f.sweat = true
        case .sleepy: f.left = .shut; f.right = .shut; f.mouth = t % 2 == 0 ? .small : .flat; f.mark = "z"; f.markRise = Double(t % 3) / 2
        case .dizzy: f.left = .cross; f.right = .cross; f.mouth = .wobble
        case .love: f.left = .heart; f.right = .heart; f.mouth = .grin; f.mark = t % 2 == 0 ? nil : "♥"
        case .surprised: f.left = .wide; f.right = .wide; f.mouth = .round; f.mark = "!"
        case .wink: f.right = .shut; f.mouth = .smirk
        case .wave: f.left = .happy; f.right = .happy; f.mouth = .grin
        case .laugh: f.left = .squeezeLeft; f.right = .squeezeRight; f.mouth = t % 2 == 0 ? .grin : .round; f.tears = true
        case .shy: f.left = .half; f.right = .half; f.mouth = .small; f.blush = true; f.gaze = Look(x: -0.8, y: 0.6)
        case .bored: f.left = .half; f.right = .half; f.mouth = .flat; f.gaze = Look(x: [0, -1, 0, 1][t % 4], y: 0)
        case .yawn:
            let wide = t % 6 >= 1 && t % 6 <= 3
            f.left = t % 6 < 4 ? .squeezeLeft : .shut; f.right = t % 6 < 4 ? .squeezeRight : .shut
            f.mouth = wide ? .round : t % 6 == 5 ? .flat : .small
        case .cool: f.shades = true; f.left = .hidden; f.right = .hidden; f.mouth = .smirk
        case .starstruck: f.left = .star; f.right = .star; f.mouth = .round; f.mark = t % 2 == 0 ? "✦" : nil
        case .music: f.left = .happy; f.right = .happy; f.mark = "♪"; f.markRise = Double(t % 4) / 3
        case .reading: f.left = .narrow; f.right = .narrow; f.mouth = .flat; f.gaze = Look(x: [-1, 0, 1, 1][t % 4], y: 0.6)
        case .skeptical: f.right = .narrow; f.mouth = .smirk; f.brows = .raised
        case .nervous: f.left = .wide; f.right = .wide; f.mouth = .wobble; f.sweat = true; f.gaze = Look(x: t % 2 == 0 ? 0 : -1, y: 0)
        case .celebrate: f.left = .happy; f.right = .happy; f.mouth = .grin; f.confetti = true
        case .kiss: f.right = .happy; f.mouth = .kiss; f.mark = t % 2 == 0 ? nil : "♥"
        case .pout: f.mouth = .frown; f.brows = .cross; f.gaze = Look(x: 0.8, y: 0)
        case .sneeze:
            let phase = t % 6
            f.left = phase < 3 ? .narrow : phase < 5 ? .squeezeLeft : .shut
            f.right = phase < 3 ? .narrow : phase < 5 ? .squeezeRight : .shut
            f.mouth = phase < 3 ? .small : phase < 5 ? .round : .flat
            f.mark = phase == 4 ? "!" : nil
        case .determined: f.left = .narrow; f.right = .narrow; f.mouth = .smirk; f.brows = .set; f.tracks = true
        }
        if blinking {
            if [.open, .wide, .narrow].contains(f.left) { f.left = .shut }
            if [.open, .wide, .narrow].contains(f.right) { f.right = .shut }
        }
        return f
    }
}

// MARK: - Dot text

// Merry's one glyph language, outside the face: the same dots spell out a
// clock on its TV screen and in the workspace, and a status in 5 × 5.

public enum DotText {
    /// 3 × 5 digits, as on a cheap LED clock.
    static let digits: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", ".##", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
        ":": [".", "#", ".", "#", "."],
        "h": ["#..", "#..", "###", "#.#", "#.#"]
    ]

    public struct Cell: Equatable, Sendable {
        public var col: Int
        public var row: Int
        public var on: Bool
        public var colon: Bool
    }

    /// A clock string laid out on a 5-row dot grid, one blank column between glyphs.
    public static func layout(_ text: String) -> (cols: Int, cells: [Cell]) {
        var cells: [Cell] = []
        var col = 0
        for ch in text {
            guard let glyph = digits[ch] else { continue }
            let width = glyph[0].count
            for r in 0..<5 {
                let line = Array(glyph[r])
                for c in 0..<width { cells.append(Cell(col: col + c, row: r, on: line[c] == "#", colon: ch == ":")) }
            }
            col += width + 1
        }
        return (max(0, col - 1), cells)
    }

    /// Minutes and seconds under an hour; hours and minutes above, so it always fits.
    public static func clock(_ ms: Double) -> String {
        let s = max(0, Int((ms / 1000).rounded(.up)))
        if s >= 3600 { return "\(s / 3600)h\(String((s % 3600) / 60).jsPadStart(2, "0"))" }
        return "\(String(s / 60).jsPadStart(2, "0")):\(String(s % 60).jsPadStart(2, "0"))"
    }
}

public enum StatusKind: String, Sendable { case ready, working, ask, paused, done, failed, stopped }

public enum StatusMark {
    /// 5 × 5 status marks. "working" is drawn as a sweeping scanner.
    public static func glyph(_ kind: StatusKind) -> [String] {
        switch kind {
        case .ready: return [".....", ".#.#.", ".....", "#...#", ".###."]
        case .working: return ["#####", "#####", "#####", "#####", "#####"]
        case .ask: return [".###.", "#...#", "..##.", ".....", "..#.."]
        case .paused: return [".#.#.", ".#.#.", ".#.#.", ".#.#.", ".#.#."]
        case .done: return [".....", "....#", "...#.", "#.#..", ".#..."]
        case .failed: return ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
        case .stopped: return [".....", ".###.", ".###.", ".###.", "....."]
        }
    }

    /// What a task's runtime status looks like to a person.
    public static func forTask(_ status: TaskStatus) -> (kind: StatusKind, label: String) {
        switch status {
        case .pending: return (.working, "Starting")
        case .observing: return (.working, "Looking")
        case .planning: return (.working, "Thinking")
        case .verifying: return (.working, "Checking")
        case .awaitingUser: return (.ask, "Needs you")
        case .paused: return (.paused, "Paused")
        case .succeeded: return (.done, "Done")
        case .failed: return (.failed, "Didn’t finish")
        case .cancelled: return (.stopped, "Stopped")
        case .executing: return (.working, "Working")
        }
    }
}
