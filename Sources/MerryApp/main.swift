import AppKit
import MerryCore
import MerryUI

let arguments = CommandLine.arguments

// Development helper: `Merry --snapshot <screen> <file.png>` renders one screen
// against canned data and exits, instead of launching the app.
if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 2 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            try Snapshot.write(screen: arguments[flag + 1], to: arguments[flag + 2])
            print("wrote \(arguments[flag + 2])")
        } catch {
            FileHandle.standardError.write(Data("\(messageOf(error))\n".utf8))
            exit(1)
        }
    }
    exit(0)
}

// Development helper: `Merry --icon <file.png>` draws the app icon.
if let flag = arguments.firstIndex(of: "--icon"), arguments.count > flag + 1 {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do { try Snapshot.writeIcon(to: arguments[flag + 1]) } catch {
            FileHandle.standardError.write(Data("\(messageOf(error))\n".utf8))
            exit(1)
        }
    }
    exit(0)
}

// Merry lives in the menu bar and on the desktop: no Dock icon, no main window.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { app.run() }
}
