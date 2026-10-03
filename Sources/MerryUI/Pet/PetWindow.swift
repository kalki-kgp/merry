import AppKit
import SwiftUI
import MerryCore

/// The pet thinks in screen coordinates with a top-left origin, as the
/// reference does; AppKit's origin is the bottom-left of the primary display.
/// This is the one place the two are converted. Each function is its own inverse.
public enum PetScreenSpace {
    @MainActor public static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    public static func point(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    public static func rect(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    @MainActor public static func point(_ p: CGPoint) -> CGPoint { point(p, primaryHeight: primaryHeight) }
    @MainActor public static func rect(_ r: CGRect) -> CGRect { rect(r, primaryHeight: primaryHeight) }

    /// The bounds of the display nearest a point, both with a top-left origin.
    public static func displayNearest(_ p: CGPoint, displays: [CGRect]) -> CGRect {
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx * dx + dy * dy
        }
        return displays.min { distance($0) < distance($1) } ?? .zero
    }
}

/// Whether the pet catches the mouse is decided here, from the real cursor
/// position, rather than by the view reacting to mouse moves: a window that
/// only turns solid once it hears about the mouse loses a quick move-and-click
/// to the desktop behind it.
public struct PetHitTest: Equatable, Sendable {
    /// The creature and bubble, in window coordinates, already padded by the view.
    public private(set) var rects: [CGRect] = []
    /// True while a drag or a file drop is holding the pet solid.
    public private(set) var held = false
    public private(set) var solid = false

    public init() {}

    public mutating func setRects(_ rects: [CGRect]) {
        self.rects = Array(rects.filter { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) && !$0.isNull }.prefix(4))
    }

    /// Holds the pet solid through a drag or a file drop, whatever the cursor
    /// does. Returns whether the window should catch the mouse now.
    @discardableResult
    public mutating func setInteractive(_ interactive: Bool) -> Bool {
        held = interactive
        solid = held || solid
        return solid
    }

    /// Called on every cursor sample: solid exactly while the cursor is over
    /// the creature. `cursor` and `frame` are in top-left screen coordinates.
    @discardableResult
    public mutating func update(cursor: CGPoint, frame: CGRect) -> Bool {
        let x = cursor.x - frame.minX
        let y = cursor.y - frame.minY
        let over = rects.contains { x >= $0.minX && x <= $0.minX + $0.width && y >= $0.minY && y <= $0.minY + $0.height }
        solid = held || over
        return solid
    }

    /// Where the cursor is relative to the pet's face, in whole points.
    public static func cursorOffset(cursor: CGPoint, frame: CGRect) -> CGPoint {
        func round(_ v: CGFloat) -> CGFloat { (v + 0.5).rounded(.down) }
        return CGPoint(x: round(cursor.x - (frame.minX + frame.width / 2)), y: round(cursor.y - (frame.minY + frame.height * 0.62)))
    }
}

/// Where the pet's window goes, in top-left screen coordinates.
public enum PetPlacement {
    /// Where it was left, or the bottom-right of the work area when it has never been placed.
    public static func initial(savedX: Double, savedY: Double, workArea: CGRect) -> CGPoint {
        CGPoint(x: savedX >= 0 ? CGFloat(savedX) : workArea.minX + workArea.width - PetLayout.width - 40,
                y: savedY >= 0 ? CGFloat(savedY) : workArea.minY + workArea.height - PetLayout.height - 40)
    }

    /// Somewhere visible, for when it has been dragged off-screen.
    public static func recentred(workArea: CGRect) -> CGPoint {
        CGPoint(x: workArea.minX + workArea.width - 200, y: workArea.minY + workArea.height - 230)
    }
}

/// Accepts clicks and file drops, but never becomes the key window.
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PetMenuItem: NSMenuItem {
    private var run: (() -> Void)?

    convenience init(_ title: String, _ run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.run = run
        target = self
    }

    @objc private func fire() { run?() }
}

/// The pet window.
///
/// It sits above other windows without ever taking focus, so it cannot steal
/// the user's typing. It is transparent and frameless: the visible pet is just
/// what the view paints.
@MainActor
public final class PetWindowController: PresenceWindow {
    public let panel: NSPanel
    /// Decides when the pet is on screen.
    public private(set) var presence: PetPresence!
    /// The window was moved; `x`, `y` are its top-left corner, to be remembered.
    public var onMoved: ((Double, Double) -> Void)?

    private let bridge: MerryBridge
    private let mode: () -> PetMode
    private var hitTest = PetHitTest()
    private let activity = WindowActivity()
    private let edge = PetEdge()
    private var cursorTimer: Timer?
    private var lastOffset: CGPoint?
    private var moveObserver: NSObjectProtocol?
    private var moveReport: DispatchWorkItem?

    /// `savedX`/`savedY` are where it was left (top-left origin), negative when it never was.
    public init(bridge: MerryBridge, savedX: Double = -1, savedY: Double = -1, mode: @escaping () -> PetMode, showAtStart: Bool = false) {
        self.bridge = bridge
        self.mode = mode
        let size = NSSize(width: PetLayout.width, height: PetLayout.height)
        let panel = PetPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        // A transparent window still swallows every click inside its bounds. Merry
        // sits on top of everything, so by default it lets the mouse straight
        // through and only becomes solid when the pointer is actually on the
        // creature. Without this, a desktop pet is a dead patch of your screen.
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ActivityRoot(activity: activity, content: PetView(bridge: bridge).environment(\.petEdge, edge)))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel

        presence = PetPresence(.init(
            window: { [weak self] in self },
            mode: mode,
            presence: { [weak bridge] visible in bridge?.events.petPresence.send(visible) },
            displayAt: { point in PetScreenSpace.displayNearest(point, displays: NSScreen.screens.map { PetScreenSpace.rect($0.frame) }) },
            held: { [weak self] in self?.hitTest.held ?? false },
            clock: SystemPetClock()))

        setPosition(PetPlacement.initial(savedX: savedX, savedY: savedY, workArea: Self.workArea))
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        followCursor()
        if showAtStart { showInactive() }
    }

    /// The primary display's visible area, top-left origin.
    private static var workArea: CGRect {
        NSScreen.screens.first.map { PetScreenSpace.rect($0.visibleFrame) } ?? .zero
    }

    // MARK: Showing

    public var isVisible: Bool { panel.isVisible }
    /// In screen coordinates with a top-left origin.
    public var frame: CGRect { PetScreenSpace.rect(panel.frame) }

    public func show() { showInactive() }
    public func showInactive() { activity.visible = true; panel.orderFrontRegardless(); measureEdge() }
    public func hide() { panel.orderOut(nil); activity.visible = false }

    /// Stops the cursor sampling and closes the window for good.
    public func close() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        moveReport?.cancel()
        panel.close()
    }

    // MARK: Catching the mouse

    private func apply(_ solid: Bool) {
        if panel.ignoresMouseEvents == solid { panel.ignoresMouseEvents = !solid }
    }

    /// The creature and bubble, in window coordinates with a top-left origin.
    public func setHitRects(_ rects: [CGRect]) { hitTest.setRects(rects) }

    /// Holds the pet solid through a drag or a file drop, whatever the cursor does.
    public func setInteractive(_ interactive: Bool) { apply(hitTest.setInteractive(interactive)) }

    /// The pet's eyes follow the mouse across the whole screen, not just while
    /// it is over the pet: being noticed is most of what makes it feel alive.
    /// The view cannot see the global cursor, so it is sampled here and only
    /// changes are sent, and only while the pet is on screen.
    private func followCursor() {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func sampleCursor() {
        if !panel.isVisible && mode() != .peek { return }
        let at = PetScreenSpace.point(NSEvent.mouseLocation)
        // Resting the pointer at the screen's right edge calls a tucked-away pet.
        presence.sample(at)
        if !panel.isVisible { return }
        // The same sample decides whether the pet catches the mouse, so it is
        // already solid by the time the pointer reaches it.
        let frame = self.frame
        apply(hitTest.update(cursor: at, frame: frame))
        let offset = PetHitTest.cursorOffset(cursor: at, frame: frame)
        if offset == lastOffset { return }
        lastOffset = offset
        bridge.events.cursor.send(offset)
    }

    // MARK: Moving

    private func setPosition(_ topLeft: CGPoint) {
        let rect = PetScreenSpace.rect(CGRect(origin: topLeft, size: panel.frame.size))
        panel.setFrameOrigin(rect.origin)
    }

    /// Moves the window by a delta in top-left terms: `dy` grows downwards.
    public func drag(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        let at = frame.origin
        setPosition(CGPoint(x: (at.x + dx).rounded(), y: (at.y + dy).rounded()))
    }

    /// Puts the pet somewhere visible, for when it has been dragged off-screen.
    public func recentre() {
        setPosition(PetPlacement.recentred(workArea: Self.workArea))
        if mode() != .menubar { showInactive() }
        reportMoved()
    }

    /// How far the window hangs off its screen, so the bubble can lean back in.
    private func measureEdge() {
        guard let screen = panel.screen ?? NSScreen.screens.first else { return }
        let over = panel.frame.maxX - screen.frame.maxX, under = screen.frame.minX - panel.frame.minX
        let shift = over > 0 ? -over : under > 0 ? under : 0
        if edge.shift != shift { edge.shift = shift }
    }

    private func moved() {
        measureEdge()
        // A drag moves the window many times a second; remember where it came to rest.
        moveReport?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reportMoved() }
        moveReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reportMoved() {
        moveReport?.cancel()
        moveReport = nil
        let at = frame.origin
        onMoved?(Double(at.x), Double(at.y))
    }

    // MARK: The menu

    /// The pet's own menu: open Merry, or play with it the way the website does.
    public func showMenu(napping: Bool, onOpen: @escaping () -> Void, onHide: @escaping () -> Void) {
        let events = bridge.events
        let play: (PetPlay) -> () -> Void = { action in { events.petPlay.send(action) } }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(PetMenuItem("Open Merry", onOpen))
        menu.addItem(PetMenuItem("Hide Merry", onHide))
        menu.addItem(.separator())
        menu.addItem(PetMenuItem("Dance break", play(.dance)))
        menu.addItem(napping ? PetMenuItem("Wake up", play(.wake)) : PetMenuItem("Little nap", play(.nap)))
        menu.addItem(PetMenuItem("Surprise me", play(.surprise)))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// How far the speech bubble has to lean to stay on screen when the pet sits at an edge.
@MainActor
final class PetEdge: ObservableObject {
    @Published var shift: CGFloat = 0
}

private struct PetEdgeKey: EnvironmentKey {
    static let defaultValue: PetEdge? = nil
}

extension EnvironmentValues {
    var petEdge: PetEdge? {
        get { self[PetEdgeKey.self] }
        set { self[PetEdgeKey.self] = newValue }
    }
}

/// Moves its content sideways by the edge's shift, following it as the pet is dragged.
struct PetEdgeShift<Content: View>: View {
    @ObservedObject var edge: PetEdge
    @ViewBuilder var content: Content
    var body: some View {
        // The window is clipped by the screen on one side, so the bubble gets
        // the part that is left: narrower, and centred in it.
        content.frame(maxWidth: PetLayout.width - abs(edge.shift) - 8).offset(x: edge.shift / 2)
    }
}
