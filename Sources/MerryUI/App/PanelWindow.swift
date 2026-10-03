import AppKit
import SwiftUI
import MerryCore

/// A borderless panel that can take the keyboard without making Merry the
/// active application, the way Spotlight does. Whatever the person was in
/// stays frontmost, which is also what lets "the previous app" be known.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The companion workspace window.
///
/// It is an ordinary window in every way that matters to the user: it can be
/// dragged by any empty part of it, it stays where it is put, and whether it
/// floats above other applications is the user's choice, not the window's.
@MainActor
public final class PanelWindowController: NSObject, NSWindowDelegate {
    public static let width: CGFloat = 640
    /// Spotlight-shaped: the panel can be as short as its command bar plus a
    /// few rows, and grows with what it has to show.
    public static let minHeight: CGFloat = 120
    public static let maxHeight: CGFloat = 660 + PanelView.titleStrip
    /// Minimized, the panel becomes an island: a small pill at the top centre
    /// of the screen, where the eye already goes for status.
    public static let islandWidth: CGFloat = 300
    public static let islandHeight: CGFloat = 46

    let window: KeyablePanel
    private let activity = WindowActivity()

    public private(set) var isDocked = false
    public private(set) var isPinned = false
    /// Where the panel returns to when it is opened back up.
    private var expanded: CGRect?

    public var onFocusChange: ((Bool) -> Void)?
    public var onShow: (() -> Void)?
    public var onHide: (() -> Void)?
    /// The user dragged the panel somewhere; the position is worth remembering.
    public var onMoved: ((CGPoint) -> Void)?

    public init<Content: View>(content: Content, savedPosition: CGPoint?, pinned: Bool) {
        let height = min(300, ScreenSpace.primaryWorkArea.height - 48)
        window = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        // The glass draws its own edge; the window's shadow is a rectangle and shows at the corners.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The panel is always dark glass, whatever the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let host = NSHostingView(rootView: ActivityRoot(activity: activity, content: content))
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        setPinned(pinned)
        if let savedPosition, savedPosition.x >= 0, savedPosition.y >= 0 {
            setBounds(ScreenSpace.onScreen(CGRect(origin: savedPosition, size: bounds.size)))
        }
    }

    // MARK: State

    public var isVisible: Bool { window.isVisible }
    public var isFocused: Bool { window.isKeyWindow }
    /// True while the window is gliding between sizes under its own steam.
    public var isAnimating: Bool { animation != nil }
    /// The window's frame, top-left origin.
    public var bounds: CGRect { ScreenSpace.fromAppKit(window.frame) }

    private func setBounds(_ rect: CGRect) {
        placing = true
        window.setFrame(ScreenSpace.toAppKit(rect), display: true)
        placing = false
    }

    /// Floats the panel above other applications, or lets them cover it.
    ///
    /// Unpinned is the default: a window that insists on being frontmost is in
    /// the way the moment you want to read anything underneath it.
    public func setPinned(_ value: Bool) {
        isPinned = value
        applyLevel()
    }

    /// Keeps the panel above other applications regardless of the pin, for
    /// setup: granting a permission means a trip to System Settings and back.
    public var floatsForSetup = false { didSet { applyLevel() } }

    private func applyLevel() {
        // While docked the island is a few pixels of screen; it has to stay
        // visible or there is nothing left to click.
        window.level = isPinned || isDocked || floatsForSetup ? .floating : .normal
    }

    // MARK: Showing

    private var fade: Timer?

    /// Shows the panel with a quick fade, so it arrives rather than blinks in,
    /// and gives it the keyboard.
    public func show() {
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        fade?.invalidate()
        window.alphaValue = 0
        activity.visible = true
        window.makeKeyAndOrderFront(nil)
        onShow?()
        let started = Date()
        fade = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(started) / 0.11)
                self.window.alphaValue = Self.easeOutCubic(t)
                if t >= 1 { timer.invalidate(); self.fade = nil }
            }
        }
    }

    /// Puts the panel away. A hidden panel is never a docked one.
    public func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        activity.visible = false
        resetDock()
        onHide?()
    }

    public func focus() { window.makeKeyAndOrderFront(nil) }

    // MARK: Motion

    private var animation: Timer?
    /// Where the running animation will end, so a resize mid-flight aims there.
    private var animTarget: CGRect?
    /// True while morphing between panel and island; resizes wait for it.
    private var morphing = false
    /// A content height that arrived mid-morph, applied once the morph lands.
    private var pendingHeight: CGFloat?
    /// Set while the controller itself is moving the window, so its own moves
    /// are not mistaken for the user's.
    private var placing = false

    nonisolated private static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    nonisolated private static func easeInOutCubic(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    /// A soft spring: a hair past the target, then settle.
    nonisolated private static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.1, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    /// Glides the window to new bounds instead of teleporting it there.
    private func animate(to target: CGRect, duration: Double, ease: @escaping (Double) -> Double = PanelWindowController.easeOutCubic, done: (() -> Void)? = nil) {
        animation?.invalidate()
        animTarget = target
        let from = bounds
        let started = Date()
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.animation?.invalidate()
            self.animation = nil
            self.animTarget = nil
            self.setBounds(target)
            done?()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish(); return }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, Date().timeIntervalSince(started) / duration)
                let k = ease(t)
                self.setBounds(CGRect(
                    x: (from.minX + (target.minX - from.minX) * k).rounded(), y: (from.minY + (target.minY - from.minY) * k).rounded(),
                    width: (from.width + (target.width - from.width) * k).rounded(), height: (from.height + (target.height - from.height) * k).rounded()))
                if t >= 1 { finish() }
            }
        }
    }

    // MARK: Docking

    /// The island: top centre of the display the panel is on, just under the menu bar.
    private func islandBounds() -> CGRect {
        let b = bounds
        let area = ScreenSpace.workArea(nearest: CGPoint(x: b.midX, y: b.midY))
        return CGRect(x: area.minX + ((area.width - Self.islandWidth) / 2).rounded(), y: area.minY + 8, width: Self.islandWidth, height: Self.islandHeight)
    }

    /// Shrinks the panel into the island.
    public func dock() {
        guard !isDocked else { return }
        // If a resize was in flight, the panel's real size is where it was going.
        expanded = animTarget ?? bounds
        isDocked = true
        morphing = true
        applyLevel()
        animate(to: islandBounds(), duration: 0.34, ease: Self.easeInOutCubic) { [weak self] in self?.morphing = false }
    }

    /// Opens the island back into the panel, exactly where it was, at the size
    /// its content now needs.
    public func undock() {
        guard isDocked else { return }
        isDocked = false
        morphing = true
        applyLevel()
        var base = expanded ?? CGRect(origin: bounds.origin, size: CGSize(width: Self.width, height: 300))
        base.size.width = Self.width
        base.size.height = pendingHeight ?? base.height
        pendingHeight = nil
        expanded = nil
        animate(to: ScreenSpace.onScreen(base), duration: 0.38, ease: Self.easeOutBack) { [weak self] in
            guard let self else { return }
            self.morphing = false
            // Content that changed size during the morph gets its size now.
            if let h = self.pendingHeight { self.pendingHeight = nil; self.resize(height: h) }
        }
    }

    public func toggleDock() { if isDocked { undock() } else { dock() } }

    /// Drops the docked state without any motion.
    ///
    /// Used when the panel is hidden outright: it should come back as a panel,
    /// not as an island the user has to find and click.
    public func resetDock() {
        guard isDocked else { return }
        animation?.invalidate()
        animation = nil
        animTarget = nil
        morphing = false
        isDocked = false
        applyLevel()
        if let expanded { setBounds(ScreenSpace.onScreen(expanded)) }
        expanded = nil
    }

    // MARK: Size and position

    /// Grows or shrinks the panel in place, without moving it out from under the cursor.
    public func resize(height: CGFloat) {
        let clamped = max(Self.minHeight, min(Self.maxHeight, height.rounded()))
        // Docked, the request describes a panel nobody can see. Remember it for
        // the moment the island opens back out.
        if isDocked {
            if var e = expanded { e.size.height = clamped; expanded = ScreenSpace.onScreen(e) }
            return
        }
        // Never interrupt the morph: a resize measured mid-flight would restart
        // the animation from a half-open window and leave it stuck small.
        if morphing { pendingHeight = clamped; return }
        var target = animTarget ?? bounds
        // Already there, or already on the way there: nothing to do.
        if target.height == clamped { return }
        target.size.height = clamped
        animate(to: ScreenSpace.onScreen(target), duration: 0.18)
    }

    /// Places the panel for its first appearance on an empty desk.
    ///
    /// Centred in the upper third of whichever display the pet is on: a
    /// summoned surface belongs where the eyes already are. Once the user has
    /// dragged it somewhere, that position wins and this is never consulted.
    public func positionNear(pet petBounds: CGRect) {
        let area = ScreenSpace.workArea(nearest: CGPoint(x: petBounds.midX, y: petBounds.midY))
        let size = bounds.size
        let x = area.minX + ((area.width - size.width) / 2).rounded()
        var y = area.minY + (area.height * 0.2).rounded()
        y = min(y, area.maxY - size.height - 24)
        y = max(y, area.minY + 24)
        setBounds(CGRect(x: x, y: y.rounded(), width: size.width, height: size.height))
    }

    /// Spotlight behaviour: the panel opens on the display you are working on.
    ///
    /// Where you dragged it is kept as a position *within* a display, so moving
    /// to another monitor brings it to the same spot there instead of leaving
    /// it on a screen you are not looking at.
    public func placeOnActiveDisplay(saved: CGPoint) {
        let active = ScreenSpace.workArea(nearest: ScreenSpace.cursor)
        let size = bounds.size
        let home = ScreenSpace.workArea(nearest: CGPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2))
        if home.minX == active.minX && home.minY == active.minY && home.width == active.width {
            setBounds(ScreenSpace.onScreen(CGRect(origin: saved, size: size)))
            return
        }
        let fx = (saved.x - home.minX) / max(1, home.width - size.width)
        let fy = (saved.y - home.minY) / max(1, home.height - size.height)
        setBounds(ScreenSpace.onScreen(CGRect(
            x: (active.minX + fx * (active.width - size.width)).rounded(), y: (active.minY + fy * (active.height - size.height)).rounded(),
            width: size.width, height: size.height)))
    }

    /// Puts the panel back in the default spot on the display under the cursor.
    public func center() {
        let area = ScreenSpace.workArea(nearest: ScreenSpace.cursor)
        let size = bounds.size
        let x = area.minX + ((area.width - size.width) / 2).rounded()
        let y = max(area.minY + 24, min(area.minY + (area.height * 0.2).rounded(), area.maxY - size.height - 24))
        animate(to: CGRect(x: x, y: y, width: size.width, height: size.height), duration: 0.22)
    }

    // MARK: NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) { onFocusChange?(true) }
    public func windowDidResignKey(_ notification: Notification) { onFocusChange?(false) }

    public func windowDidMove(_ notification: Notification) {
        // Only a panel the user dragged is worth remembering; the island and
        // the open/close animations place themselves.
        guard !placing, !isDocked, !isAnimating, window.isVisible else { return }
        onMoved?(bounds.origin)
    }
}
