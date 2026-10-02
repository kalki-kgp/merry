import AppKit
import CoreText
import SwiftUI

/// What ships with the app: the pixel font, and the menu bar face drawn in code.
enum MerryResources {
    /// Where a bundled file is. Inside Merry.app that is Contents/Resources;
    /// run from the build folder it is the package's resource bundle.
    static func url(_ name: String) -> URL? {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for base in [Bundle.main.bundleURL, executable] {
            folders.append(base.appendingPathComponent("Merry_MerryUI.bundle/Resources"))
            folders.append(base.appendingPathComponent("Merry_MerryUI.bundle/Contents/Resources/Resources"))
            folders.append(base.appendingPathComponent("Merry_MerryUI.bundle"))
        }
        // Tests run from the package's own test bundle.
        folders.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        for folder in folders {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static let fontsRegistered: Bool = {
        guard let font = url("PixelifySans.ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
    }()

    /// Pixel lettering, used in exactly one place: the pet's speech bubble. It
    /// is charming there and tiring to read anywhere else.
    ///
    /// The face is drawn on a grid of 11 squares to the em, so it is only
    /// sharp where a square covers whole screen pixels: 11, 16.5 and 22 points.
    static func pixelFont(size: CGFloat = 16.5) -> Font {
        fontsRegistered ? .custom("Pixelify Sans", fixedSize: size) : .system(size: size * 0.8, weight: .medium, design: .monospaced)
    }

    /// Merry's head for the menu bar: a template image macOS recolours for light and dark bars.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(SpriteView.cloud(center: CGPoint(x: 9, y: 9), rx: 5.6, ry: 4.6, tuft: 2.6, count: 9).cgPath)
            ctx.fillPath()
            // The face is cut out of the wool, and the eyes drawn back in.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: 4.6, y: 6.4, width: 8.8, height: 7.2))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: CGRect(x: 6.3, y: 8.4, width: 1.7, height: 2.4))
            ctx.fillEllipse(in: CGRect(x: 10, y: 8.4, width: 1.7, height: 2.4))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The icons the interface uses, by what they mean.
enum Icon: String {
    case expand = "arrow.up.left.and.arrow.down.right"
    case copy = "doc.on.doc"
    case list = "list.bullet"
    case chevron = "chevron.left"
    case spark = "sparkle"
    case folder = "folder"
    case search = "magnifyingglass"
    case rename = "pencil"
    case clock = "clock.arrow.circlepath"
    case settings = "slider.horizontal.3"
    case arrow = "arrow.right"
    case close = "xmark"
    case plus = "plus"
    case screen = "macwindow"
    case check = "checkmark"
    case help = "questionmark.circle"
    case trash = "trash"
    case attach = "paperclip"
    case back = "arrow.left"
    case pin = "pin"
    case minimize = "arrow.up.to.line"
    case up = "arrow.up"
    case compose = "square.and.pencil"
    case archive = "archivebox"

    func image(size: CGFloat = 14, weight: Font.Weight = .medium) -> some View {
        Image(systemName: rawValue).font(.system(size: size, weight: weight))
    }
}
