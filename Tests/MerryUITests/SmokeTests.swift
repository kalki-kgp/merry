import Testing
@testable import MerryUI

@Test func moduleLoads() {
    #expect(!MerryUI.version.isEmpty)
}
