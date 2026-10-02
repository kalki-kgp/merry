import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's hot keys are still the only way
/// to hold a key combination from anywhere without Accessibility permission,
/// and registering one fails cleanly when another app already has it.
@MainActor
public final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Registers the shortcut. Returns nil when the accelerator cannot be
    /// parsed or the system refuses it (usually: another app holds it).
    public init?(accelerator: String, handler: @escaping () -> Void) {
        guard let parsed = HotKey.parse(accelerator) else { return nil }
        HotKey.installHandler()
        id = HotKey.nextId
        HotKey.nextId += 1
        var made: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, EventHotKeyID(signature: OSType(0x4B494255), id: id), GetEventDispatcherTarget(), 0, &made)
        guard status == noErr, let made else { return nil }
        ref = made
        HotKey.handlers[id] = handler
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Reads an accelerator written the way the settings store it:
    /// modifier names joined by "+", then the key ("Command+Shift+Space").
    public static func parse(_ accelerator: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = accelerator.split(separator: "+").map { $0.lowercased() }
        guard let key = parts.last, parts.count >= 2 else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "command", "cmd", "commandorcontrol", "cmdorctrl", "super", "meta": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            default: return nil
            }
        }
        guard let code = keyCodes[key] else { return nil }
        return (UInt32(code), modifiers)
    }

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "enter": kVK_Return, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "minus": kVK_ANSI_Minus, "plus": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
        "backquote": kVK_ANSI_Grave, "bracketleft": kVK_ANSI_LeftBracket, "bracketright": kVK_ANSI_RightBracket
    ]
}
