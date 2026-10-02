import Testing
import MerryCore
@testable import MerryUI

@Suite(.serialized) struct PetFaceTests {
    @Test func everyStateHasAMood() {
        let moods = [PetState.idle, .listening, .thinking, .working, .waiting, .finished, .failed].map { Mood.forState($0) }
        #expect(moods == [.idle, .listening, .thinking, .working, .waiting, .proud, .sad])
    }

    @Test func aBlinkShutsOnlyOpenEyes() {
        for mood in Mood.allCases {
            let open = PetFace.features(mood), shut = PetFace.features(mood, blinking: true)
            for (before, after) in [(open.left, shut.left), (open.right, shut.right)] {
                #expect(after == ([.open, .wide, .narrow].contains(before) ? .shut : before), "\(mood)")
            }
        }
        #expect(PetFace.features(.cool).shades && PetFace.features(.cool).left == .hidden)
    }

    @Test func animatedMoodsChangeAndStillOnesDoNot() {
        for mood in Mood.allCases where PetFace.frameMs(mood) == nil {
            #expect(PetFace.features(mood, t: 0).mark == PetFace.features(mood, t: 3).mark, "\(mood)")
            #expect(PetFace.features(mood, t: 0).dots == nil, "\(mood)")
        }
        #expect((0..<4).map { PetFace.features(.working, t: $0).dots } == [0, 1, 2, 3])
        #expect((0..<4).map { PetFace.features(.waiting, t: $0).mark } == ["?", "?", "?", nil])
        #expect(Set((0..<6).map { PetFace.features(.yawn, t: $0).mouth }).count == 3)
    }

    @Test func clocksFitTheFace() {
        #expect(DotText.clock(0) == "00:00")
        #expect(DotText.clock(1) == "00:01")
        #expect(DotText.clock(24 * 60_000 + 37_000) == "24:37")
        #expect(DotText.clock(3_599_001) == "1h00")
        #expect(DotText.clock(65 * 60_000) == "1h05")
        let layout = DotText.layout("12:05")
        #expect(layout.cols == 17 && layout.cells.filter(\.colon).count == 5)
    }

    @Test func statusesReadPlainly() {
        #expect(StatusMark.forTask(.awaitingUser).kind == .ask && StatusMark.forTask(.awaitingUser).label == "Needs you")
        #expect(StatusMark.forTask(.succeeded).kind == .done)
        #expect(StatusMark.forTask(.cancelled).label == "Stopped")
        for kind in [StatusKind.ready, .working, .ask, .paused, .done, .failed, .stopped] {
            #expect(StatusMark.glyph(kind).count == 5 && StatusMark.glyph(kind).allSatisfy { $0.count == 5 })
        }
    }

    @Test func whatItSaysFollowsTheMoment() {
        defer { Personality.random = { Double.random(in: 0..<1) } }
        Personality.random = { 0 }
        #expect(Personality.hello(hour: 8).mood == .wave && Personality.hello(hour: 8) != Personality.hello(hour: 2))
        #expect(Personality.onStart("find my passport scan").mood == .determined)
        #expect(Personality.onStart("what is in this folder?").mood == .thinking)
        #expect(Personality.checkIn(seconds: 40, done: 3, total: 5, turn: 0).text.hasPrefix("3 of 5"))
        #expect(Personality.checkIn(seconds: 40, done: 0, total: 5, turn: 0).mood == .shy)
        #expect(Personality.successMood(actions: 9, seconds: 30) == .celebrate)
        #expect(Personality.successMood(actions: 1, seconds: 2) == .cool)
        #expect(Personality.successMood(actions: 4, seconds: 30) == .starstruck)
        #expect(Personality.successMood(actions: 0, seconds: 1) == .proud)
        #expect(Personality.nudge().action?.open == true)
        #expect(Personality.afterSuccess() != nil)
        Personality.random = { 0.9 }
        #expect(Personality.afterSuccess() == nil)
        #expect(Personality.undone(3).text.contains("3") && Personality.undone(0).mood == .oops)
        #expect(Personality.fed(4).text.contains("4"))
        #expect(Personality.ate(3).mood == .celebrate && Personality.ate(1).mood == .happy)
        #expect(Personality.surprises.count == 7)
        #expect(Personality.idleRemark(hour: 15, activeMinutes: 120, turn: 0).mood == .shy)
        #expect(Personality.idleRemark(hour: 15, activeMinutes: 5, turn: 0).action?.compose == "Organize my Downloads folder")
    }
}
