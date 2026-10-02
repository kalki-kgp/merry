import Foundation

/// Retired defaults; Option+Space also opens ChatGPT's floating pet.
private let oldDefaultShortcuts = ["CommandOrControl+Shift+K", "Alt+Space"]

/// What JavaScript's `!value` would call false.
private func isFalsy(_ value: JSON?) -> Bool {
    switch value {
    case nil, .null?: return true
    case .bool(let b)?: return !b
    case .number(let n)?: return n == 0 || n.isNaN
    case .string(let s)?: return s.isEmpty
    default: return false
    }
}

/// Apply new defaults without replacing a person's chosen mode or shortcut.
public func settingsFromSaved(_ raw: String?) -> Settings {
    guard let raw, !raw.isEmpty, let parsed = try? JSON.parse(raw), case .object(var saved) = parsed else { return Settings() }
    if isFalsy(saved["shortcutChosen"]), oldDefaultShortcuts.contains(saved["shortcut"]?.stringValue ?? "") { saved["shortcut"] = nil }
    if isFalsy(saved["petModeChosen"]) { saved["petMode"] = nil }
    // Decoding fills whatever the saved copy lacks from the defaults.
    return (try? JSON.object(saved).decode(Settings.self)) ?? Settings()
}

/// The setting the whole `Settings` value is kept under.
private let settingsKey = "settings"

extension Store {
    public func loadSettings() -> Settings {
        settingsFromSaved(try? getSetting(settingsKey))
    }

    public func saveSettings(_ settings: Settings) throws {
        try setSetting(settingsKey, try StoredJSON.encode(settings))
    }
}
