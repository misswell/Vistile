import XCTest
@testable import VistileCore

final class StableRailSelectionTests: XCTestCase {
    private func identity(_ index: Int) -> WindowIdentity {
        WindowIdentity(processID: 100, processStartIdentity: 1, windowID: UInt32(index + 1))
    }

    func testRepeatedSelectionPreservesEveryHomeAndCountsUniqueWindows() {
        let slots = (0..<4).map { RailSlotID(displayID: 1, rail: .top, ordinal: $0) }
        var placement = WorkbenchPlacement()
        for (index, slot) in slots.enumerated() { XCTAssertTrue(placement.place(identity(index), at: slot)) }
        let homes = placement.occupants
        for index in [0, 3, 1, 2, 0, 2] {
            XCTAssertTrue(placement.swapMain(with: slots[index]))
            XCTAssertEqual(placement.main, identity(index))
            XCTAssertEqual(placement.occupants, homes)
            XCTAssertEqual(placement.memberCount, 4)
            XCTAssertEqual(placement.slot(of: identity(index)), slots[index])
            XCTAssertTrue(placement.maintainsInvariants)
        }
        let revision = placement.revision
        XCTAssertFalse(placement.swapMain(with: slots[2]))
        XCTAssertEqual(placement.revision, revision)
    }

    func testClosingSelectedWindowVacatesOnlyItsOwnSlot() {
        let a = RailSlotID(displayID: 1, rail: .top, ordinal: 0)
        let b = RailSlotID(displayID: 1, rail: .side, ordinal: 0)
        var placement = WorkbenchPlacement(main: identity(0), occupants: [a: identity(0), b: identity(1)])
        XCTAssertTrue(placement.vacate(identity(0)))
        XCTAssertNil(placement.main)
        XCTAssertNil(placement.occupant(at: a))
        XCTAssertEqual(placement.occupant(at: b), identity(1))
        XCTAssertEqual(placement.memberCount, 1)
    }
}
