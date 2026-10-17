//
// File:     Tests/WaypointCoreTests/ExtendChoicesTests.swift
// Purpose:  The new Scanner's "Extend a map" offers only scan areas whose saved world map exists on this phone, and a pending extension
//           cannot be finished.
//
import XCTest
@testable import WaypointCore

final class ExtendChoicesTests: XCTestCase {

    private func map(_ name: String, segments: [String]) -> BuildingMap {
        BuildingMap(name: name, nodes: segments.map { MapNode(kind: .corridor, position: [0, 0, 0], segmentId: $0) })
    }

    func testOnlySegmentsWithAWorldMapFileAreOffered() {
        let rice = map("Rice Hall", segments: ["seg1", "seg2"]), sample = map("SAMPLE", segments: ["seg1"])
        let options = ExtendChoices.options(maps: [rice, sample]) { id, seg in id == rice.id && seg == "seg2" }
        XCTAssertEqual(options.map(\.segmentId), ["seg2"])
        XCTAssertEqual(options.first?.mapName, "Rice Hall")
        XCTAssertEqual(options.first?.areaTitle, "Scan area 2 of 2")
    }

    func testSingleAreaMapsAreCalledScannedArea_AndOrderIsByName() {
        let b = map("B Hall", segments: ["s"]), a = map("A Hall", segments: ["s"])
        let options = ExtendChoices.options(maps: [b, a]) { _, _ in true }
        XCTAssertEqual(options.map(\.mapName), ["A Hall", "B Hall"])
        XCTAssertEqual(options.first?.areaTitle, "Scanned area")
        XCTAssertEqual(Set(options.map(\.id)).count, 2)
    }

    func testNothingOfferedWithoutWorldMapsAndUnsafeSegmentIdsAreSkipped() {
        let m = map("X", segments: ["ok", "../evil"])
        XCTAssertTrue(ExtendChoices.options(maps: [m]) { _, _ in false }.isEmpty)
        XCTAssertEqual(ExtendChoices.options(maps: [m]) { _, _ in true }.map(\.segmentId), ["ok"])
    }

    func testPendingExtensionBlocksFinishingBeforeAnythingElse() {
        let gate = FinishGate.evaluate(quality: .mapped, labelledTagCount: 3, extensionPending: true)
        XCTAssertEqual(gate.reason, "Find your position in the saved area first, then walk the new part.")
        XCTAssertTrue(FinishGate.evaluate(quality: .mapped, labelledTagCount: 3, extensionPending: false).isReady)
        XCTAssertFalse(FinishGate.evaluate(quality: .mapped, labelledTagCount: 0, extensionPending: false).isReady)
    }
}
