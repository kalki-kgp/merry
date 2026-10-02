import AppKit
import Foundation
import SwiftUI
import MerryCore
@testable import MerryUI

// Helpers that need Foundation live here, away from the files that import Testing.

@MainActor
final class FakePresenceWindow: PresenceWindow {
    var isVisible: Bool
    var frame = CGRect(x: 1140, y: 670, width: 260, height: 190)
    var events: [String] = []

    init(visible: Bool = false) { isVisible = visible }

    func showInactive() { isVisible = true; events.append("show") }
    func hide() { isVisible = false; events.append("hide") }
}

/// A PetPresence on a fake window, two fake displays and a clock that only moves when told.
@MainActor
final class PresenceRig {
    let clock: ManualPetClock
    let window: FakePresenceWindow
    var mode: PetMode
    var held = false
    var gone = false
    private(set) var presence: PetPresence!

    init(mode: PetMode, visible: Bool = false, start: Double = 1_750_000_000_000) {
        self.mode = mode
        clock = ManualPetClock(now: start)
        window = FakePresenceWindow(visible: visible)
        presence = PetPresence(.init(
            window: { [unowned self] in self.gone ? nil : self.window },
            mode: { [unowned self] in self.mode },
            presence: { [unowned self] visible in self.window.events.append("presence:\(visible)") },
            // The primary display is 1440 x 900; a second one, 1920 x 1080, sits to its right.
            displayAt: { $0.x >= 1440 ? CGRect(x: 1440, y: 0, width: 1920, height: 1080) : CGRect(x: 0, y: 0, width: 1440, height: 900) },
            held: { [unowned self] in self.held },
            clock: clock))
    }

    /// What was asked of the window since the last call.
    func take() -> [String] {
        defer { window.events = [] }
        return window.events
    }

    func sample(_ x: Double, _ y: Double) { presence.sample(CGPoint(x: x, y: y)) }

    /// The pointer resting at one spot, sampled every 30 ms as the app does.
    func dwell(_ x: Double, _ y: Double, _ ms: Double) {
        var t = 0.0
        while t <= ms { sample(x, y); clock.advance(by: 30); t += 30 }
    }

    /// One step of a recorded scenario, as the fixtures hold them.
    func run(_ step: JSON) {
        let op = step[0]?.stringValue ?? ""
        func num(_ i: Int) -> Double { step[i]?.doubleValue ?? 0 }
        func flag(_ i: Int) -> Bool { step[i]?.boolValue ?? false }
        switch op {
        case "wait": clock.advance(by: num(1))
        case "state": presence.setState(PetState(rawValue: step[1]?.stringValue ?? "")!)
        case "attention": presence.setAttention(flag(1), wake: flag(2))
        case "brain": presence.setBrain(petBrain(step[1]!))
        case "hide": presence.hide()
        case "reveal": presence.reveal()
        case "panel": presence.setPanelOpen(flag(1))
        case "showFor": presence.showFor(num(1))
        case "sample": sample(num(1), num(2))
        case "dwell": dwell(num(1), num(2), num(3))
        case "mode": mode = PetMode(rawValue: step[1]?.stringValue ?? "")!
        case "held": held = flag(1)
        case "win": window.frame.origin = CGPoint(x: num(1), y: num(2))
        case "nowin": gone = true
        case "update": presence.update()
        default: fatalError("unknown step \(op)")
        }
    }
}

func petBrain(_ json: JSON) -> BrainSnapshot {
    try! JSONDecoder().decode(BrainSnapshot.self, from: Data(json.stringify().utf8))
}

func petReminder(_ id: String, title: String, dueAt: Double) -> BrainItem {
    let json: JSON = ["kind": "reminder", "title": .string(title), "body": "", "projectId": nil, "dueAt": .number(dueAt), "repeat": "none",
                      "estimateMinutes": nil, "sources": [], "id": .string(id), "status": "open", "createdAt": .number(dueAt - 1000),
                      "updatedAt": .number(dueAt - 1000), "notifiedAt": nil, "acknowledgedAt": nil, "checks": []]
    return try! JSONDecoder().decode(BrainItem.self, from: Data(json.stringify().utf8))
}

func petTimer(_ status: String, label: String = "Deep work", endsAt: Double? = nil, remainingMs: Double = 600_000) -> BrainTimer {
    BrainTimer(id: "t1", label: label, durationMs: 1_500_000, remainingMs: remainingMs, endsAt: endsAt, status: status, notifiedAt: nil)
}

func petRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
func petPoint(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

/// A PetModel on a recording bridge and a manual clock.
@MainActor
final class PetRig {
    let bridge = PreviewBridge()
    let clock = ManualPetClock()
    let model: PetModel
    var hitRects: [[CGRect]] = []

    init(hour: Int = 10, random: Double = 0, start: Bool = true) {
        model = PetModel(bridge: bridge, clock: clock, random: { random }, hour: { hour })
        if start { model.start() }
    }

    static let centre = CGPoint(x: 130, y: 140)

    var events: BridgeEvents { bridge.events }
    func advance(_ ms: Double) { clock.advance(by: ms) }
    /// Past the hello it says on arrival.
    func pastHello() -> PetRig { advance(6000); return self }

    func task(_ status: TaskStatus, line: String = "Working", id: String = "t1", request: String = "do the thing") -> TaskState {
        var t = TaskState(id: id, request: request, now: clock.now)
        t.status = status
        t.statusLine = line
        return t
    }

    /// A press and release on the creature without moving.
    func click() {
        model.mouseDown(local: Self.centre, screen: CGPoint(x: 500, y: 500))
        model.mouseUp(local: Self.centre)
    }

    func calls(_ name: String) -> Int { bridge.calls.filter { $0 == name }.count }

    /// Lets work queued on the main actor (the bridge's async calls) run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Which kind of view a click at a window point (top-left origin) lands on, with the pet laid out offscreen.
@MainActor
func petViewUnder(_ model: PetModel, _ point: CGPoint) -> String {
    let host = NSHostingView(rootView: PetView(model: model))
    let frame = NSRect(x: 0, y: 0, width: PetLayout.width, height: PetLayout.height)
    // Never ordered in: a window is only needed for the view tree to be built.
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    let flipped = host.isFlipped ? point : CGPoint(x: point.x, y: PetLayout.height - point.y)
    guard let hit = host.hitTest(flipped) else { return "nothing" }
    var view: NSView? = hit
    while let v = view { if v is PetMouseView { return "catcher" }; view = v.superview }
    return hit === host ? "host" : String(describing: type(of: hit))
}

/// A hit test that can be changed from inside an expectation.
final class HitBox {
    var it = PetHitTest()
    func update(cursor: CGPoint, frame: CGRect) -> Bool { it.update(cursor: cursor, frame: frame) }
    func hold(_ on: Bool) -> Bool { it.setInteractive(on) }
}

func petPlan(_ statuses: [String]) -> [PlanStep] {
    let json = JSON.array(statuses.enumerated().map { ["id": .string("\($0.offset)"), "description": "step", "status": .string($0.element)] })
    return try! JSONDecoder().decode([PlanStep].self, from: Data(json.stringify().utf8))
}
