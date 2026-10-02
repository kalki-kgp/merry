import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import MerryCore

/// What macOS itself says, for the adapter's answers to be checked against.
/// Everything here only reads: nothing is pressed, posted or prompted for.
/// (It lives apart from the tests because a file cannot import both Testing
/// and Foundation when building with the Command Line Tools alone.)
enum MacProbe {
    struct Screen {
        var id: Int
        var x: Double
        /// Converted from AppKit's bottom-left origin, the way the reference helper did.
        var topLeftY: Double
        var width: Double
        var height: Double
        var scale: Double
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    static var screenCaptureAllowed: Bool { CGPreflightScreenCaptureAccess() }
    static var mainDisplayId: Int { Int(CGMainDisplayID()) }
    static var uptimeMs: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    static func sleep(ms: Int) { usleep(UInt32(ms) * 1000) }

    /// A process id that is not in use.
    static func unusedPid() -> Int {
        var pid: pid_t = 99_990
        while pid > 1_000, kill(pid, 0) == 0 || errno != ESRCH { pid -= 1 }
        return Int(pid)
    }

    static func regularAppPids() -> Set<Int> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { Int($0.processIdentifier) })
    }

    static func runningApp(_ bundleId: String) -> (pid: Int, name: String)? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first.map { (Int($0.processIdentifier), $0.localizedName ?? "app") }
    }

    /// An installed app that is not open right now.
    static func closedApp() -> String? {
        ["com.apple.Chess", "com.apple.Stickies", "com.apple.FontBook"].first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil && runningApp($0) == nil
        }
    }

    static func screens() -> [Screen] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            Screen(
                id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0,
                x: Double(screen.frame.origin.x),
                topLeftY: Double(primary.frame.height - (screen.frame.origin.y + screen.frame.height)),
                width: Double(screen.frame.width),
                height: Double(screen.frame.height),
                scale: Double(screen.backingScaleFactor)
            )
        }
    }

    /// A parsed shortcut as a key code and the modifiers it holds, by name.
    static func shortcut(_ spec: String) throws -> (key: Int, modifiers: [String]) {
        let parsed = try MacOsAdapter.parseShortcut(spec)
        let names: [(CGEventFlags, String)] = [(.maskCommand, "cmd"), (.maskShift, "shift"), (.maskAlternate, "alt"), (.maskControl, "ctrl"), (.maskSecondaryFn, "fn")]
        let known = names.reduce(CGEventFlags()) { $0.union($1.0) }
        precondition(parsed.flags.subtracting(known).isEmpty)
        return (Int(parsed.key), names.filter { parsed.flags.contains($0.0) }.map(\.1))
    }
}
