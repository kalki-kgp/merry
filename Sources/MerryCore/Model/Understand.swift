import Foundation

/// One structured reading of what the user asked for.
///
/// Everything Merry needs to decide (what kind of work this is, what sort of
/// thing it concerns, where, when, how big) in a single shape, produced once
/// per request.
///
/// The reason this exists: understanding used to be a dozen regexes scattered
/// across routing, the find workflow and the command workflow. Every word that
/// was not in a list was a bug: "movie" matched and "movies" did not, "watch"
/// sat in the web list and hijacked every request about films. Lists of words
/// cannot be completed, only extended after each failure.
///
/// Jev is exactly the right instrument for this and was barely being used: it
/// cannot write text, but it maps a messy sentence onto declared alternatives
/// in one round trip. So local rules now keep only the cases they are actually
/// certain about, and everything else is one Jev call that answers every
/// question at once, roughly 450ms, a fraction of a cent, and no vocabulary
/// to maintain.
public struct Understanding: Equatable, Sendable {
    public enum Action: String, Sendable, CaseIterable { case find, organize, rename, make, open, run, web, app, assist, other }
    public enum Kind: String, Sendable, CaseIterable { case any, video, image, audio, document, spreadsheet, slides, archive, code }
    public enum Size: String, Sendable, CaseIterable { case any, big, huge }
    public enum When: String, Sendable, CaseIterable { case any, today, week, month }
    public enum Place: String, Sendable, CaseIterable { case anywhere, downloads, desktop, documents, pictures, movies, music }

    public var action: Action
    public var kind: Kind
    public var size: Size
    public var when: When
    public var place: Place
    /// True when the request cannot be acted on without asking something.
    public var vague: Bool
    public var confidence: Double
    public var source: JevSource

    public init(action: Action, kind: Kind = .any, size: Size = .any, when: When = .any, place: Place = .anywhere, vague: Bool = false, confidence: Double, source: JevSource = .local) {
        self.action = action; self.kind = kind; self.size = size; self.when = when; self.place = place
        self.vague = vague; self.confidence = confidence; self.source = source
    }
}

private let ACTIONS: [(Understanding.Action, String)] = [
    (.find, "Locate something already on this computer and show the user where it is."),
    (.organize, "Tidy a folder by sorting what is in it into groups."),
    (.rename, "Give a group of files consistent names."),
    (.make, "Create a new folder or file."),
    (.open, "Open something in an application."),
    (.run, "Run a specific command the user has dictated."),
    (.web, "Visit a website, search the web, or do something in a browser."),
    (.app, "Read or control a native Mac application that is already open."),
    (.assist, "Use the calendar, reminders, notes, email, a system setting or one of their Shortcuts."),
    (.other, "None of these; this needs general-purpose planning.")
]

private let KINDS: [(Understanding.Kind, String)] = [
    (.any, "No particular kind of file was implied."),
    (.video, "Films, movies, clips, recordings, anything you watch."),
    (.image, "Photos, pictures, screenshots, artwork."),
    (.audio, "Music, songs, recordings, podcasts, anything you listen to."),
    (.document, "Text documents, PDFs, notes, letters, reports."),
    (.spreadsheet, "Spreadsheets, tables, CSVs, financial records."),
    (.slides, "Presentations and slide decks."),
    (.archive, "Zips, disk images and other bundles."),
    (.code, "Source code and project files.")
]

private let SIZES: [(Understanding.Size, String)] = [
    (.any, "Size was not mentioned."),
    (.big, "The user asked for large files, or for what is taking up space."),
    (.huge, "The user emphasised very large files specifically.")
]

private let WHENS: [(Understanding.When, String)] = [
    (.any, "No time was mentioned."),
    (.today, "Today, this morning, or just now."),
    (.week, "Yesterday, or within roughly the past week."),
    (.month, "Within roughly the past month.")
]

private let PLACES: [(Understanding.Place, String)] = [
    (.anywhere, "No particular folder was named; search everywhere sensible."),
    (.downloads, "The Downloads folder."),
    (.desktop, "The Desktop."),
    (.documents, "The Documents folder."),
    (.pictures, "The Pictures folder."),
    (.movies, "The Movies folder."),
    (.music, "The Music folder.")
]

private func criteria<T: RawRepresentable>(_ table: [(T, String)]) -> [(String, String)] where T.RawValue == String {
    table.map { ($0.0.rawValue, $0.1) }
}

/// Reads the request.
///
/// Local rules answer only when they are genuinely certain: a dictated
/// command, files dropped on the pet. Everything else goes to Jev, because a
/// confident regex is exactly how the old version got "movies" wrong.
public func understand(_ request: String, _ jev: Jev, hasDroppedPaths: Bool, now: Double? = nil) async -> Understanding {
    if let certain = readLocally(request, hasDroppedPaths: hasDroppedPaths) { return certain }

    let answers = await jev.ask(
        "understand",
        state: ["userRequest": .string(request), "filesDroppedOntoAssistant": .bool(hasDroppedPaths), "today": .string(JSDate(now ?? nowMs()).toDateString())],
        questions: [
            ("action", .choice("What is the user asking to have done?", criteria(ACTIONS))),
            ("kind", .choice("What sort of thing does the request concern?", criteria(KINDS))),
            ("size", .choice("Did the user say anything about how large the files are?", criteria(SIZES))),
            ("when", .choice("Did the user say anything about when?", criteria(WHENS))),
            ("place", .choice("Did the user name a particular folder?", criteria(PLACES))),
            ("vague", .noul("Is this too vague to act on without asking the user what they mean?", [
                "true": "A reasonable assistant would have to ask before starting.",
                "false": "There is a clear, sensible first step."
            ]))
        ]
    )

    guard let answers else { return fallback(request, hasDroppedPaths: hasDroppedPaths) }

    // Never trust the shape of a reply that came over a network. A missing or
    // unexpected answer falls back to local rules rather than failing in the
    // middle of the user's task.
    let base = fallback(request, hasDroppedPaths: hasDroppedPaths)
    func pick<T: RawRepresentable>(_ name: String, _ ifMissing: T) -> T where T.RawValue == String {
        answers[name]?.choice.flatMap(T.init(rawValue:)) ?? ifMissing
    }

    return Understanding(
        action: pick("action", base.action),
        kind: pick("kind", base.kind),
        size: pick("size", base.size),
        when: pick("when", base.when),
        place: pick("place", base.place),
        vague: answers["vague"]?.noul.map { $0 > 0.5 } ?? base.vague,
        confidence: answers["action"]?.confidence ?? 0.5,
        source: answers["action"]?.choice != nil ? .jev : .local
    )
}

/// Root words that identify each kind, matched with plurals folded in.
private let KIND_WORDS: [(Understanding.Kind, [String])] = [
    (.video, ["movie", "film", "video", "clip", "episode", "series", "recording", "mp4", "mkv"]),
    (.image, ["photo", "picture", "image", "screenshot", "screengrab", "wallpaper", "png", "jpg", "jpeg"]),
    (.audio, ["song", "music", "audio", "track", "album", "podcast", "mp3"]),
    (.document, ["document", "doc", "pdf", "note", "letter", "report", "essay", "book", "invoice", "receipt", "card"]),
    (.spreadsheet, ["spreadsheet", "sheet", "excel", "csv", "table"]),
    (.slides, ["slide", "deck", "presentation", "powerpoint", "keynote"]),
    (.archive, ["zip", "archive", "dmg", "installer", "tarball"]),
    (.code, ["code", "script", "repo", "project", "source"])
]

private let SIZE_WORDS: [(Understanding.Size, [String])] = [
    (.huge, ["huge", "massive", "enormous", "gigantic"]),
    (.big, ["big", "large", "biggest", "largest", "heavy", "space", "storage", "bulky", "hogging"])
]

private let WHEN_WORDS: [(Understanding.When, [String])] = [
    (.today, ["today", "morning", "now"]),
    (.week, ["yesterday", "week", "recent", "recently", "latest", "lately"]),
    (.month, ["month"])
]

private let PLACE_WORDS: [(Understanding.Place, [String])] = [
    (.downloads, ["download", "downloaded", "downloads"]),
    (.desktop, ["desktop"]),
    (.documents, ["documents"]),
    (.pictures, ["pictures"]),
    (.movies, []),
    (.music, [])
]

private let ACTION_WORDS: [(Understanding.Action, [String])] = [
    (.find, ["find", "locate", "search", "where", "show", "look"]),
    (.organize, ["organise", "organize", "tidy", "sort", "clean", "declutter"]),
    (.rename, ["rename", "naming"]),
    (.make, ["create", "make", "mkdir"]),
    (.open, ["open", "launch"]),
    (.web, ["browse", "google", "youtube", "website", "web"])
]

/// Folds a request into the word stems it contains.
///
/// Plurals were a whole class of bug on their own: "movie" was listed and
/// "movies" was not, so asking for movies searched for the literal word. One
/// fold here removes the need to list every form of every word.
private func stems(_ request: String) -> Set<String> {
    var out = Set<String>()
    for raw in Rx.ecma("[^a-z0-9]+").split(request.lowercased()) {
        if raw.isEmpty { continue }
        out.insert(raw)
        if raw.hasSuffix("ies") { out.insert("\(raw.jsSlice(0, -3))y") }
        if raw.hasSuffix("es") { out.insert(raw.jsSlice(0, -2)) }
        if raw.hasSuffix("s") { out.insert(raw.jsSlice(0, -1)) }
    }
    return out
}

private func firstMatch<T>(_ words: Set<String>, _ table: [(T, [String])]) -> T? {
    table.first { $0.1.contains(where: words.contains) }?.0
}

private let ASSIST = Rx.ecma(
    "\\b(remind me|set a reminder|add a reminder|reminders|to-?do list|on my calendar|to my calendar|my (?:calendar|schedule|agenda)|am i (?:free|busy)|when am i free|free (?:hour|slot|time)|what'?s next|schedule (?:a|an|my)|book (?:a|an)|dark mode|light mode|volume|mute|unmute|shortcut|make a note|take a note|jot down|save (?:this|that|it) to notes)\\b|^\\s*note:",
    "i"
)

/// What local code may claim without asking Jev.
///
/// The bar is "certain", not "plausible". A clear action verb plus attributes
/// that map cleanly onto the vocabularies is answerable here for nothing; a
/// request with no recognisable verb, "any movies to watch?", is exactly the
/// ambiguity Jev exists for, and is not guessed at.
func readLocally(_ request: String, hasDroppedPaths: Bool) -> Understanding? {
    // Reminders, calendar, notes, settings and shortcuts are named plainly, and
    // are checked first: "remind me to check youtube" is a reminder, not a
    // website, and "run my Focus shortcut" is not a shell command.
    if ASSIST.test(request) { return Understanding(action: .assist, confidence: 0.9) }
    if Rx.ecma("^\\s*(?:run|execute|exec)\\s+\\S+", "i").test(request) {
        return Understanding(action: .run, confidence: 0.95)
    }
    // A URL is not open to interpretation.
    if Rx.ecma("\\bhttps?:\\/\\/\\S+", "i").test(request) {
        return Understanding(action: .web, confidence: 0.95)
    }

    let words = stems(request)

    // Naming a site, or anything host-shaped, settles it. "open youtube and
    // search for a good video" contains both "open" and "search", and picking
    // whichever verb came first in a list is how this ended up searching the
    // Downloads folder for a YouTube video.
    if isWeb(request, words) { return Understanding(action: .web, confidence: 0.9) }

    let matched = ACTION_WORDS.filter { $0.1.contains(where: words.contains) }.map(\.0)

    var action: Understanding.Action?
    if matched.count == 1 { action = matched[0] }
    // "make a folder and open it in Zed" is one job, not two competing ones.
    else if matched.count > 1 && matched.allSatisfy({ $0 == .make || $0 == .open || $0 == .run }) {
        action = matched.contains(.make) ? .make : matched.contains(.open) ? .open : .run
    }

    guard let action else {
        // Files put in front of Merry with a short instruction are unambiguous.
        if hasDroppedPaths && request.ecmaWordCount < 5 {
            return Understanding(action: .organize, confidence: 0.9)
        }
        // Two verbs pulling different ways, or none at all: ask Jev rather than
        // pick one and be confidently wrong.
        return nil
    }

    return Understanding(
        action: action,
        kind: firstMatch(words, KIND_WORDS) ?? .any,
        size: firstMatch(words, SIZE_WORDS) ?? .any,
        when: firstMatch(words, WHEN_WORDS) ?? .any,
        place: firstMatch(words, PLACE_WORDS) ?? .anywhere,
        vague: false,
        confidence: 0.85,
        source: .local
    )
}

/// Whether this is plainly about the web.
///
/// A shape rule, not a list of sites: listing top-level domains is a losing
/// game, and "bunkr.cr" is as real as "youtube.com". Filenames are excluded,
/// because "report.pdf" is host-shaped and is obviously not a website.
private func isWeb(_ request: String, _ words: Set<String>) -> Bool {
    let r = request.lowercased()
    let named = ["youtube", "netflix", "gmail", "google", "twitter", "reddit", "amazon", "instagram",
                 "facebook", "spotify", "wikipedia", "github", "linkedin", "chatgpt"]
    if named.contains(where: words.contains) { return true }
    if Rx.ecma("\\b(web|internet|online|browser|website)\\b").test(r) { return true }
    return Rx.ecma("\\b[a-z0-9][a-z0-9-]{1,}\\.[a-z]{2,6}\\b").test(r) &&
        !Rx.ecma("\\.(pdf|png|jpe?g|gif|mp4|mov|mkv|mp3|docx?|xlsx?|pptx?|txt|csv|zip|dmg|heic|webp|md|json|ts|js|py)\\b").test(r)
}

/// When Jev is unavailable.
///
/// Coarser than the confident path (it will guess an action where the
/// confident path refuses to), but it reads the same vocabularies rather than
/// keeping a second set of words that drift apart from the first. Two lists
/// meaning the same thing is how "storage" counted as a size in one place and
/// not in the other.
private func fallback(_ request: String, hasDroppedPaths: Bool) -> Understanding {
    let words = stems(request)
    let action = firstMatch(words, ACTION_WORDS) ?? (hasDroppedPaths ? .organize : .other)
    return Understanding(
        action: action,
        kind: firstMatch(words, KIND_WORDS) ?? .any,
        size: firstMatch(words, SIZE_WORDS) ?? .any,
        when: firstMatch(words, WHEN_WORDS) ?? .any,
        place: firstMatch(words, PLACE_WORDS) ?? .anywhere,
        // Unrecognised is not the same as vague: "when is my first free hour
        // tomorrow" is perfectly clear, just not a file task. Only a very short
        // request with nothing recognisable in it is worth a question.
        vague: action == .other && request.ecmaWordCount < 4 && !hasDroppedPaths,
        confidence: 0.4,
        source: .local
    )
}

/// File extensions for a kind, for filtering a search.
public func extensionsFor(_ kind: Understanding.Kind) -> [String] {
    switch kind {
    case .video: return [".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".flv"]
    case .image: return [".png", ".jpg", ".jpeg", ".heic", ".gif", ".webp", ".tiff", ".bmp", ".svg"]
    case .audio: return [".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg", ".aiff"]
    case .document: return [".pdf", ".docx", ".doc", ".pages", ".txt", ".md", ".rtf", ".epub"]
    case .spreadsheet: return [".xlsx", ".xls", ".csv", ".numbers", ".tsv"]
    case .slides: return [".pptx", ".ppt", ".key"]
    case .archive: return [".zip", ".tar", ".gz", ".dmg", ".7z", ".rar", ".iso"]
    case .code: return [".ts", ".js", ".py", ".go", ".rs", ".java", ".c", ".cpp", ".swift", ".rb"]
    case .any: return []
    }
}

/// The smallest size, in bytes, that counts as what the user asked for.
public func bytesFor(_ size: Understanding.Size) -> Int? {
    switch size {
    case .big: return 100 * 1024 * 1024
    case .huge: return 1024 * 1024 * 1024
    case .any: return nil
    }
}

/// Milliseconds of history a timeframe covers.
public func sinceFor(_ when: Understanding.When) -> Double? {
    let day = 86_400_000.0
    switch when {
    case .today: return day
    case .week: return 8 * day
    case .month: return 31 * day
    case .any: return nil
    }
}

/// Which folder a place means, relative to home.
public func folderFor(_ place: Understanding.Place) -> String? {
    switch place {
    case .downloads: return "Downloads"
    case .desktop: return "Desktop"
    case .documents: return "Documents"
    case .pictures: return "Pictures"
    case .movies: return "Movies"
    case .music: return "Music"
    case .anywhere: return nil
    }
}

/// Which toolset a reading implies: files, desktop, browser, apps or unclear.
public struct UnderstoodRoute: Equatable, Sendable {
    public var route: String
    public var reason: String
    public var needsClarification: Bool
}

/// Which toolset a reading implies.
///
/// Derived rather than asked separately: the action already says what kind of
/// work this is, so a second routing question would be the same judgment
/// bought twice.
public func routeFor(_ read: Understanding) -> UnderstoodRoute {
    let route: String
    switch read.action {
    case .web: route = "browser"
    case .app: route = "desktop"
    case .assist: route = "apps"
    case .other: route = "unclear"
    default: route = "files"
    }
    return UnderstoodRoute(route: route, reason: "read as \"\(read.action.rawValue)\" (\(read.source.rawValue))", needsClarification: read.vague)
}

/// A neutral reading, for the paths that never ran understand().
public func fallbackUnderstanding() -> Understanding {
    Understanding(action: .other, kind: .any, size: .any, when: .any, place: .anywhere, vague: false, confidence: 0, source: .local)
}
