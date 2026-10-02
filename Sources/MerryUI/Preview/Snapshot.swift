import AppKit
import SwiftUI
import MerryCore

/// Renders a view to a PNG without launching the app, for looking at a screen
/// while building it. Liquid Glass needs a real window to refract, so in a
/// snapshot glass surfaces appear flat; layout, type and colour are faithful.
@MainActor
public enum Snapshot {
    /// Named screens that can be rendered: `Merry --snapshot <name> <file.png>`.
    public static var screens: [String: () -> AnyView] = [
        "sprites": { AnyView(SpriteSheet()) }
    ]

    public static func register<V: View>(_ name: String, _ make: @escaping () -> V) {
        screens[name] = { AnyView(make()) }
    }

    /// Hosts the view in an offscreen window long enough for async loads and
    /// `onAppear` work to land, then captures it.
    public static func write<V: View>(_ view: V, to path: String, size: CGSize? = nil, settle: TimeInterval = 0.6) throws {
        let content = view.environment(\.colorScheme, .dark).background(Color(hex: "#1c1d21"))
        let host = NSHostingView(rootView: AnyView(content))
        let fitted = size ?? host.fittingSize
        let frame = NSRect(origin: .zero, size: fitted)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = frame
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        let until = Date().addingTimeInterval(settle)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw MerryError("could not capture the view") }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw MerryError("could not encode the image") }
        try data.write(to: URL(fileURLWithPath: path))
    }

    public static func write(screen name: String, to path: String) throws {
        PetScreens.register()
        PanelScreens.register()
        SettingsScreens.register()
        BrainScreens.register()
        guard let make = screens[name] else {
            throw MerryError("no screen named \"\(name)\". Known: \(screens.keys.sorted().joined(separator: ", "))")
        }
        try write(make(), to: path)
    }

    /// The app icon: Merry on a night-sea tile, in the shape macOS expects.
    public static func writeIcon(to path: String) throws {
        let tile = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#3a5fa8"), Color(hex: "#1a2550"), Color(hex: "#0e1430")], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 6)
            SpriteView(state: .idle, mood: .happy, size: 680, quiet: true).offset(y: 10)
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw MerryError("could not draw the icon") }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw MerryError("could not encode the image") }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
