import Testing
import MerryCore
@testable import MerryUI

@MainActor
@Suite struct PetPresenceTests {
    /// Every scripted scenario asks the same of the window, step for step, as the reference.
    @Test func matchesTheOriginalStepForStep() {
        let fixture = Fixture.load("pet-presence")
        let scenarios = fixture.list("scenarios")
        #expect(scenarios.count >= 20)
        for scenario in scenarios {
            let rig = PresenceRig(mode: PetMode(rawValue: scenario.str("mode"))!, visible: scenario.flag("visible"), start: fixture.num("start"))
            let trace = scenario.list("trace")
            for (i, step) in scenario.list("steps").enumerated() {
                rig.run(step)
                let where_ = "\(scenario.str("name")) step \(i) \(step.stringify())"
                #expect(rig.take() == trace[i].strings("events"), "events: \(where_)")
                #expect(rig.window.isVisible == trace[i].flag("visible"), "visible: \(where_)")
                #expect(rig.presence.wanted() == trace[i].flag("wanted"), "wanted: \(where_)")
            }
        }
    }

    @Test func alwaysOnTheDesktopNeverHides() {
        let rig = PresenceRig(mode: .desktop)
        rig.presence.update()
        #expect(rig.take() == ["show", "presence:true"])
        rig.presence.setState(.working)
        rig.presence.setState(.finished)
        rig.clock.advance(by: 600_000)
        rig.presence.setState(.idle)
        rig.clock.advance(by: 600_000)
        #expect(rig.window.isVisible && rig.take().isEmpty)
    }

    @Test func menuBarOnlyNeverShows() {
        let rig = PresenceRig(mode: .menubar)
        rig.presence.setState(.working)
        rig.presence.setAttention(true)
        rig.presence.showFor(5000)
        rig.presence.setPanelOpen(true)
        rig.dwell(1439, 800, 600)
        #expect(!rig.window.isVisible && rig.take().isEmpty)
    }

    @Test func peekingHidesWhenIdleAndComesOutForWork() {
        let rig = PresenceRig(mode: .peek)
        rig.presence.setState(.idle)
        #expect(!rig.window.isVisible)
        for state in [PetState.thinking, .working, .waiting] {
            let each = PresenceRig(mode: .peek)
            each.presence.setState(state)
            #expect(each.take() == ["show", "presence:true"], "\(state)")
        }
    }

    @Test func peekingComesOutForATimerOrADueReminder() {
        let rig = PresenceRig(mode: .peek)
        rig.presence.setBrain(BrainSnapshot(timer: petTimer("running", endsAt: rig.clock.now + 60_000)))
        #expect(rig.take() == ["show", "presence:true"])
        rig.presence.setBrain(BrainSnapshot())
        rig.clock.advance(by: PetPresence.exitMs)
        #expect(rig.take() == ["presence:false", "hide"])
        // Not due yet: nothing. Due: out it comes.
        let reminder = petReminder("a", title: "Call", dueAt: rig.clock.now + 1000)
        rig.presence.setBrain(BrainSnapshot(items: [reminder]))
        #expect(rig.take().isEmpty)
        rig.clock.advance(by: 1000)
        rig.presence.setBrain(BrainSnapshot(items: [reminder]))
        #expect(rig.take() == ["show", "presence:true"])
    }

    @Test func itStaysSixSecondsAfterATaskThenSaysItIsLeavingAndHides() {
        let rig = PresenceRig(mode: .peek)
        rig.presence.setState(.working)
        rig.presence.setState(.finished)
        _ = rig.take()
        rig.clock.advance(by: PetPresence.lingerMs - 1)
        #expect(rig.presence.wanted() && rig.take().isEmpty)
        rig.clock.advance(by: 21)
        // It says it is leaving, so the view can slide out, before the window goes.
        #expect(rig.take() == ["presence:false"] && rig.window.isVisible)
        rig.clock.advance(by: PetPresence.exitMs - 1)
        #expect(rig.window.isVisible)
        rig.clock.advance(by: 1)
        #expect(rig.take() == ["hide"] && !rig.window.isVisible)
    }

    @Test func restingOnTheLowerRightEdgeForAQuarterSecondCallsIt() {
        let rig = PresenceRig(mode: .peek)
        rig.sample(1439, 800)
        rig.clock.advance(by: 249)
        rig.sample(1439, 800)
        #expect(!rig.window.isVisible)
        rig.clock.advance(by: 1)
        rig.sample(1439, 800)
        #expect(rig.take() == ["show", "presence:true"])
    }

    @Test func aPointerPassingByDoesNotCallIt() {
        let rig = PresenceRig(mode: .peek)
        rig.sample(1439, 800)
        rig.clock.advance(by: 200)
        rig.sample(1200, 800)
        rig.clock.advance(by: 30)
        rig.sample(1439, 800)
        rig.clock.advance(by: 200)
        rig.sample(1439, 800)
        #expect(!rig.window.isVisible && rig.take().isEmpty)
    }

    @Test func theTopOfTheEdgeAndTheCornerDoNotCallIt() {
        // The band is from 260 above the bottom to 8 above it, within 3 of the right edge.
        for (x, y, called) in [(1439.0, 100.0, false), (1439, 639, false), (1439, 640, true), (1439, 892, true), (1439, 893, false),
                               (1439, 899, false), (1436, 800, false), (1437, 800, true)] {
            let rig = PresenceRig(mode: .peek)
            rig.dwell(x, y, 600)
            #expect(rig.window.isVisible == called, "\(x),\(y)")
        }
    }

    @Test func itStaysWhileThePointerIsOnItAndGoesAMomentAfter() {
        let rig = PresenceRig(mode: .peek)
        rig.dwell(1439, 800, 300)
        #expect(rig.window.isVisible)
        // On the pet (and up to 40 points around it) keeps it for as long as you like.
        for _ in 0..<200 { rig.sample(1200, 700); rig.clock.advance(by: 30) }
        #expect(rig.window.isVisible)
        rig.sample(1100, 630)
        rig.clock.advance(by: 30)
        #expect(rig.window.isVisible)
        _ = rig.take()
        // Away: it goes 1.2 seconds later.
        rig.sample(500, 300)
        rig.clock.advance(by: PetPresence.leaveMs - 31)
        #expect(rig.window.isVisible && rig.take().isEmpty)
        rig.clock.advance(by: 100)
        #expect(rig.take() == ["presence:false"])
        rig.clock.advance(by: PetPresence.exitMs)
        #expect(rig.take() == ["hide"])
    }

    @Test func aDragOrDropHoldsIt() {
        let rig = PresenceRig(mode: .peek)
        rig.held = true
        rig.presence.update()
        #expect(rig.window.isVisible)
        rig.clock.advance(by: 60_000)
        #expect(rig.window.isVisible)
        rig.held = false
        rig.presence.update()
        rig.clock.advance(by: PetPresence.exitMs)
        #expect(!rig.window.isVisible)
    }

    @Test func hiddenByHandItWaitsForANewTaskOrAlert() {
        let rig = PresenceRig(mode: .peek)
        rig.presence.setState(.working)
        rig.presence.hide()
        rig.clock.advance(by: PetPresence.exitMs)
        #expect(!rig.window.isVisible)
        // Still the same job: stays away, and the edge does not call it either.
        rig.presence.setState(.working)
        rig.dwell(1439, 800, 600)
        #expect(!rig.window.isVisible)
        rig.presence.setState(.idle)
        rig.presence.setState(.thinking)
        #expect(rig.window.isVisible)
    }

    @Test func onDemandFollowsTheOpenPrompt() {
        let rig = PresenceRig(mode: .ondemand)
        rig.presence.setPanelOpen(true)
        #expect(rig.take() == ["show", "presence:true"])
        rig.presence.showFor(5000)
        rig.presence.setPanelOpen(false)
        rig.clock.advance(by: PetPresence.exitMs)
        #expect(rig.take() == ["presence:false", "hide"])
        // The edge is a peek-only gesture.
        rig.dwell(1439, 800, 600)
        #expect(!rig.window.isVisible)
    }

    @Test func wantedAgainWhileLeavingItSlidesBackIn() {
        let rig = PresenceRig(mode: .peek)
        rig.presence.setAttention(true)
        rig.presence.setAttention(false)
        #expect(rig.take() == ["show", "presence:true", "presence:false"])
        rig.clock.advance(by: 100)
        rig.presence.setState(.working)
        #expect(rig.take() == ["presence:true"])
        rig.clock.advance(by: 1000)
        #expect(rig.window.isVisible && rig.take().isEmpty)
    }
}
