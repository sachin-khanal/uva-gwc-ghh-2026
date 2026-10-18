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

    /// An area must say WHERE it is. "Scan area 2 of 2" gave the volunteer nothing to choose on, and
    /// picking an area they were not standing in asked ARKit to recognise a different part of the
    /// building - which never succeeds (device report 2026-10-18).
    func testAnAreaNamesThePlacesInsideIt() {
        let seg1 = "seg_" + String(repeating: "a", count: 32)
        let seg2 = "seg_" + String(repeating: "b", count: 32)
        let map = BuildingMap(name: "Rice", nodes: [
            MapNode(kind: .corridor, position: [0, 0, 0], segmentId: seg1),
            MapNode(kind: .room, label: "Start", position: [1, 0, 0], segmentId: seg1),
            MapNode(kind: .stairs, label: "Rear Stairwell", position: [2, 0, 0], segmentId: seg1),
            MapNode(kind: .corridor, position: [9, 0, 0], segmentId: seg2),
            MapNode(kind: .room, label: "Men's Bathroom", position: [9, 0, 1], segmentId: seg2),
        ])
        let options = ExtendChoices.options(maps: [map]) { _, _ in true }
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options[0].isOriginal)
        XCTAssertEqual(options[0].placeNames, ["Rear Stairwell", "Start"])
        XCTAssertEqual(options[0].pointCount, 3)
        XCTAssertFalse(options[1].isOriginal)
        XCTAssertEqual(options[1].placeNames, ["Men's Bathroom"])
    }

    /// An area with nothing labelled still says something useful about itself.
    func testAnUnlabelledAreaFallsBackToItsSize() {
        let seg = "seg_" + String(repeating: "c", count: 32)
        let map = BuildingMap(name: "Rice", nodes: [
            MapNode(kind: .corridor, position: [0, 0, 0], segmentId: seg),
            MapNode(kind: .corridor, position: [1, 0, 0], segmentId: seg),
        ])
        let options = ExtendChoices.options(maps: [map]) { _, _ in true }
        XCTAssertEqual(options.first?.whereItIs, "2 points, nothing labelled")
    }
}
