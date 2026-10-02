import AppKit
import MerryCore
@testable import MerryUI

// Helpers for SettingsTests that need AppKit, kept out of the file that imports Testing.

enum Chord {
    /// Modifier flags from letters: c ⌘, t ⌃, o ⌥, s ⇧.
    static func flags(_ letters: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if letters.contains("c") { flags.insert(.command) }
        if letters.contains("t") { flags.insert(.control) }
        if letters.contains("o") { flags.insert(.option) }
        if letters.contains("s") { flags.insert(.shift) }
        return flags
    }

    static func accelerator(_ letters: String, key: String?) -> String? {
        Accelerator.from(modifiers: flags(letters), key: key)
    }

    static func capture(_ letters: String, keyCode: UInt16) -> Accelerator.Capture {
        // Caps Lock and the function flag ride along on real events and must not matter.
        Accelerator.capture(keyCode: keyCode, modifiers: flags(letters).union([.capsLock, .function]))
    }
}

/// Holds a model check open until the test lets it answer.
@MainActor
final class CheckGate {
    private var continuation: CheckedContinuation<CodingModelCheck, Never>?
    private(set) var entered = false
    private(set) var asked: [String] = []

    func wait(_ model: String) async -> CodingModelCheck {
        asked.append(model)
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ result: CodingModelCheck) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func untilEntered() async {
        while !entered { await Task.yield() }
    }
}

@MainActor
enum SettingsFixtures {
    static func catalog() -> CodingModelCatalog {
        var best = CodingModel(id: "prov/best", label: "Best")
        best.recommended = true
        best.recommendation = "Best for your plan."
        var free = CodingModel(id: "prov/free", label: "Free One")
        free.free = true
        var locked = CodingModel(id: "prov/locked", label: "Locked")
        locked.access = "unavailable"
        locked.reason = "Your plan does not include this model."
        let plain = CodingModel(id: "other/plain", label: "Plain")
        return CodingModelCatalog(models: [best, free, locked, plain], note: "", connection: "pro plan", defaultModel: "prov/best")
    }

    /// A Mac with Claude Code and Codex installed, OpenCode not.
    static func bridge() -> PreviewBridge {
        let bridge = PreviewBridge()
        bridge.apps = [
            CodingAppStatus(id: .claudeCode, label: "Claude Code", available: true),
            CodingAppStatus(id: .codex, label: "Codex", available: true),
            CodingAppStatus(id: .opencode, label: "OpenCode", available: false)
        ]
        bridge.catalog = catalog()
        bridge.setup = SettingsScreens.setupItems()
        return bridge
    }

    static func picker(_ bridge: PreviewBridge, app: CodingApp, value: String = "") -> ModelPickerModel {
        ModelPickerModel(bridge: bridge, app: app, value: value) { model in
            _ = try await bridge.setSettings { $0[keyPath: codingModelSetting(app)] = model }
        }
    }
}
