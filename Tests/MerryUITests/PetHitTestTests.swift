import Testing
import MerryCore
@testable import MerryUI

@Suite struct PetHitTestTests {
    let frame = petRect(1000, 600, 260, 190)

    @Test func solidOnlyWhileTheCursorIsOverAReportedRect() {
        let test = HitBox()
        #expect(!test.it.solid)
        test.it.setRects(PetLogic.hitRects(creature: PetLayout.creature, bubble: petRect(40, 50, 180, 38)))
        // Empty air in the window's corner.
        #expect(!test.update(cursor: petPoint(1005, 605), frame: frame))
        // On the creature (window 130,140 -> screen 1130,740).
        #expect(test.update(cursor: petPoint(1130, 740), frame: frame))
        // On the bubble.
        #expect(test.update(cursor: petPoint(1100, 660), frame: frame))
        // Between them.
        #expect(!test.update(cursor: petPoint(1050, 700), frame: frame))
        // Outside the window altogether.
        #expect(!test.update(cursor: petPoint(10, 10), frame: frame))
    }

    @Test func edgesAreInclusive() {
        let test = HitBox()
        test.it.setRects([petRect(10, 20, 30, 40)])
        #expect(test.update(cursor: petPoint(1010, 620), frame: frame))
        #expect(test.update(cursor: petPoint(1040, 660), frame: frame))
        #expect(!test.update(cursor: petPoint(1040.5, 660), frame: frame))
        #expect(!test.update(cursor: petPoint(1009.5, 620), frame: frame))
    }

    @Test func heldStaysSolidWhateverTheCursorDoes() {
        let test = HitBox()
        test.it.setRects([petRect(84, 100, 92, 86)])
        #expect(test.hold(true))
        #expect(test.it.held)
        #expect(test.update(cursor: petPoint(0, 0), frame: frame))
        // Letting go does not itself turn it see-through; the next sample decides.
        #expect(test.hold(false))
        #expect(!test.it.held)
        #expect(!test.update(cursor: petPoint(0, 0), frame: frame))
        #expect(!test.hold(false))
    }

    @Test func rectsThatAreNotNumbersAreDroppedAndOnlyFourKept() {
        let test = HitBox()
        test.it.setRects([petRect(.nan, 0, 1, 1), petRect(0, 0, .infinity, 1)] + (0..<6).map { petRect(Double($0), 0, 1, 1) })
        #expect(test.it.rects == (0..<4).map { petRect(Double($0), 0, 1, 1) })
    }

    @Test func theCursorIsMeasuredFromThePetsFace() {
        // Centre across, 62% of the way down, as the reference's followCursor.
        #expect(PetHitTest.cursorOffset(cursor: petPoint(1130, 717.8), frame: frame) == petPoint(0, 0))
        #expect(PetHitTest.cursorOffset(cursor: petPoint(1000, 600), frame: frame) == petPoint(-130, -118))
        #expect(PetHitTest.cursorOffset(cursor: petPoint(1500, 900), frame: frame) == petPoint(370, 182))
        // Halves round up, as Math.round does.
        #expect(PetHitTest.cursorOffset(cursor: petPoint(1130.5, 718.3), frame: frame) == petPoint(1, 1))
        #expect(PetHitTest.cursorOffset(cursor: petPoint(1129.5, 717.2), frame: frame) == petPoint(0, -1))
    }

    @Test func theViewPadsTheCreatureAndTheBubble() {
        let creature = PetLayout.creature
        #expect(creature.minX == 84 && creature.width == 92)
        #expect(abs(creature.maxY - 186) < 0.001 && abs(creature.height - 92.0 * 112 / 120) < 0.001)
        let rects = PetLogic.hitRects(creature: creature, bubble: petRect(40, 52, 180, 38))
        #expect(rects.count == 2)
        #expect(rects[0] == creature.insetBy(dx: -14, dy: -14))
        #expect(rects[1] == petRect(36, 48, 188, 46))
        #expect(PetLogic.hitRects(creature: creature, bubble: nil).count == 1)
        #expect(PetLogic.rectsKey(rects) == "70,86,120,114;36,48,188,46")
        // A fraction of a point is not a change worth reporting.
        #expect(PetLogic.rectsKey([petRect(36.2, 48.4, 188.1, 45.6)]) == "36,48,188,46")
    }

    @Test func topLeftAndAppKitCoordinatesConvertBothWays() {
        let appKit = petRect(100, 50, 260, 190)
        let topLeft = PetScreenSpace.rect(appKit, primaryHeight: 900)
        #expect(topLeft == petRect(100, 660, 260, 190))
        #expect(PetScreenSpace.rect(topLeft, primaryHeight: 900) == appKit)
        #expect(PetScreenSpace.point(petPoint(10, 880), primaryHeight: 900) == petPoint(10, 20))
        // A display above the primary one has negative y in top-left terms.
        #expect(PetScreenSpace.rect(petRect(0, 900, 1920, 1080), primaryHeight: 900) == petRect(0, -1080, 1920, 1080))
    }

    @Test func theNearestDisplayIsTheOneUnderThePoint() {
        let displays = [petRect(0, 0, 1440, 900), petRect(1440, 0, 1920, 1080)]
        #expect(PetScreenSpace.displayNearest(petPoint(700, 400), displays: displays) == displays[0])
        #expect(PetScreenSpace.displayNearest(petPoint(2000, 1000), displays: displays) == displays[1])
        #expect(PetScreenSpace.displayNearest(petPoint(-50, 2000), displays: displays) == displays[0])
        #expect(PetScreenSpace.displayNearest(petPoint(0, 0), displays: []) == .zero)
    }

    @Test func itStartsBottomRightUnlessItWasPutSomewhereElse() {
        let work = petRect(0, 25, 1440, 800)
        #expect(PetPlacement.initial(savedX: -1, savedY: -1, workArea: work) == petPoint(1140, 595))
        #expect(PetPlacement.initial(savedX: 300, savedY: 200, workArea: work) == petPoint(300, 200))
        #expect(PetPlacement.initial(savedX: 0, savedY: -1, workArea: work) == petPoint(0, 595))
        #expect(PetPlacement.recentred(workArea: work) == petPoint(1240, 595))
    }
}
