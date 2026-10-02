import AppKit

/// The global shortcut as it is stored ("Command+Shift+Space": modifier names
/// joined by "+", then the key) and as it is shown and captured.
public enum Accelerator {
    /// Symbol and name together: "⌥" alone is easy to misread as ⌘, Spotlight's key.
    static let symbols: [String: String] = [
        "CommandOrControl": "⌘ Command", "CmdOrCtrl": "⌘ Command", "Command": "⌘ Command", "Cmd": "⌘ Command", "Super": "⌘ Command",
        "Alt": "⌥ Option", "Option": "⌥ Option", "Shift": "⇧ Shift", "Control": "⌃ Control", "Ctrl": "⌃ Control"
    ]

    /// "Alt+Space" → ["⌥ Option", "Space"]: the keys as a Mac keyboard labels them.
    public static func display(_ accelerator: String) -> [String] {
        accelerator.components(separatedBy: "+").map { part in
            symbols[part] ?? (part.utf16.count == 1 ? part.uppercased() : part)
        }
    }

    public static let spotlightMessage = "⌘ Command + Space opens Spotlight. Pick another. ⌘ Command + ⇧ Shift + Space is the default."

    private static let letters: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
    ]
    private static let digits: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    static let escapeKeyCode: UInt16 = 53

    /// The key a key press names, in the stored spelling, or nil for a key a
    /// shortcut cannot end in. It goes by the key's place on the keyboard, not
    /// the character it types, so ⌥K is "K" and not "˚".
    public static func key(forKeyCode code: UInt16) -> String? {
        if code == 49 { return "Space" }
        return letters[code] ?? digits[code] ?? functionKeys[code]
    }

    /// A chord needs ⌘, ⌥ or ⌃, so ordinary typing can never be taken over.
    /// Returns nil for a bare key, a bare modifier, and ⌘Space.
    public static func from(modifiers: NSEvent.ModifierFlags, key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let command = modifiers.contains(.command), control = modifiers.contains(.control)
        let option = modifiers.contains(.option), shift = modifiers.contains(.shift)
        guard command || option || control else { return nil }
        // ⌘Space belongs to Spotlight: pressing it here opens Spotlight, not this.
        if command && !control && !option && !shift && key == "Space" { return nil }
        var parts: [String] = []
        if command { parts.append("Command") }
        if control { parts.append("Control") }
        if option { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public static func from(event: NSEvent) -> String? {
        from(modifiers: event.modifierFlags, key: key(forKeyCode: event.keyCode))
    }

    /// What one key press means while a new shortcut is being recorded.
    public enum Capture: Equatable, Sendable {
        /// Escape: keep the shortcut there was.
        case cancelled
        /// Not a chord yet; keep listening.
        case ignored
        case refused(String)
        case accepted(String)
    }

    public static func capture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Capture {
        if keyCode == escapeKeyCode { return .cancelled }
        let key = key(forKeyCode: keyCode)
        if let accelerator = from(modifiers: modifiers, key: key) { return .accepted(accelerator) }
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if key == "Space" && held == .command { return .refused(spotlightMessage) }
        return .ignored
    }
}
