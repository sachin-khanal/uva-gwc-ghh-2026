//
// File:     StairsTests.swift
// Module:   WaypointCoreTests
// Purpose:  Format 4's stairs metadata, and the health checks that stop a stairwell being unusable for
//           changing floor. The two ends of one staircase live in SEPARATE maps (one per floor) and are
//           matched by NAME, so a missing or contradictory direction is the difference between a
//           traversable building and a dead end.
//
import XCTest
@testable import WaypointCore

final class StairsMetadataTests: XCTestCase {

    private func stairs(_ label: String, _ direction: StairsDirection?) -> MapNode {
        MapNode(kind: .stairs, label: label, position: [0, 0, 0],
                stairs: direction.map { StairsInfo(direction: $0) })
    }

    private func map(_ nodes: [MapNode]) -> BuildingMap {
        // Two corridor nodes and an edge, so the map is not flagged as too small / disconnected.
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .room, label: "Room 1", position: [3, 0, 0])
        var m = BuildingMap(name: "Rice Hall", nodes: [a, b] + nodes,
                            edges: [MapEdge(from: a.id, to: b.id, distance: 3)])
        m.edges += nodes.map { MapEdge(from: a.id, to: $0.id, distance: 2, hazard: .stairs) }
        return m
    }

    // MARK: The direction pairing rule

    func testOppositeDirectionsPair() {
        XCTAssertTrue(StairsDirection.up.pairs(with: .down))
        XCTAssertTrue(StairsDirection.down.pairs(with: .up))
    }

    /// Two ends that both go up cannot be ends of the SAME staircase.
    func testTheSameDirectionDoesNotPair() {
        XCTAssertFalse(StairsDirection.up.pairs(with: .up))
        XCTAssertFalse(StairsDirection.down.pairs(with: .down))
    }

    /// A mid-flight landing goes both ways, so it pairs with anything.
    func testBothPairsWithEverything() {
        for d in StairsDirection.allCases {
            XCTAssertTrue(StairsDirection.both.pairs(with: d), "\(d)")
            XCTAssertTrue(d.pairs(with: .both), "\(d)")
        }
    }

    // MARK: Health checks

    func testStairsWithoutADirectionAreFlagged() {
        let warnings = MapHealth.check(map([stairs("North Stairwell", nil)]))
        guard case .some(.stairsWithoutDirection(let names)) = warnings.first(where: {
            if case .stairsWithoutDirection = $0 { return true } else { return false }
        }) else { return XCTFail("\(warnings)") }
        XCTAssertEqual(names, ["North Stairwell"])
    }

    func testStairsWithADirectionAreNotFlagged() {
        let warnings = MapHealth.check(map([stairs("North Stairwell", .up)]))
        XCTAssertFalse(warnings.contains { if case .stairsWithoutDirection = $0 { return true } else { return false } },
                       "\(warnings)")
    }

    /// Both ends of "North Stairwell" claim to go up: they cannot be one staircase, and a sighted
    /// volunteer can still fix it.
    func testContradictoryDirectionsUnderOneNameAreFlagged() {
        let warnings = MapHealth.check(map([stairs("North Stairwell", .up), stairs("North Stairwell", .up)]))
        XCTAssertTrue(warnings.contains { if case .stairsDirectionsDisagree = $0 { return true } else { return false } },
                      "\(warnings)")
    }

    /// Up and down under one name is exactly right - that IS the two ends of a staircase.
    func testOppositeEndsUnderOneNameAreFine() {
        let warnings = MapHealth.check(map([stairs("North Stairwell", .up), stairs("North Stairwell", .down)]))
        XCTAssertFalse(warnings.contains { if case .stairsDirectionsDisagree = $0 { return true } else { return false } },
                       "\(warnings)")
    }

    /// Different stairwells are not compared with each other.
    func testDifferentStairwellsAreIndependent() {
        let warnings = MapHealth.check(map([stairs("North Stairwell", .up), stairs("South Stairwell", .up)]))
        XCTAssertFalse(warnings.contains { if case .stairsDirectionsDisagree = $0 { return true } else { return false } },
                       "\(warnings)")
    }

    // MARK: Format 4

    func testStairsInfoSurvivesAJsonRoundTrip() throws {
        var node = MapNode(kind: .stairs, label: "North Stairwell", position: [1, 0, 2])
        node.stairs = StairsInfo(direction: .down, railings: .both, stepCount: 14)
        let map = BuildingMap(name: "Rice Hall", nodes: [node])
        let back = try BuildingMap.from(jsonData: map.jsonData())
        XCTAssertEqual(back.nodes[0].stairs, StairsInfo(direction: .down, railings: .both, stepCount: 14))
    }

    /// A map with no stairs metadata must not grow the key.
    func testAMapWithoutStairsInfoDoesNotGrowTheKey() throws {
        let json = String(decoding: try BuildingMap(name: "x",
                                                    nodes: [MapNode(kind: .corridor, position: [0, 0, 0])]).jsonData(),
                          as: UTF8.self)
        XCTAssertFalse(json.contains("\"stairs\""), json)
    }

    func testFormat4FixtureCarriesStairsInfo() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("docs/map-format/map-v4.json"))
        let map = try BuildingMap.from(jsonData: data)
        XCTAssertEqual(map.schemaVersion, MapSchema.current)
        let stairsNode = map.nodes.first { $0.stairs != nil }
        XCTAssertEqual(stairsNode?.stairs?.direction, .up)
        XCTAssertEqual(stairsNode?.stairs?.railings, .right)
        XCTAssertEqual(stairsNode?.stairs?.stepCount, 14)
    }

    /// Every older fixture still decodes, with no stairs metadata.
    func testOlderFixturesStillDecodeWithoutStairsInfo() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        for name in ["map-v1.json", "map-v2.json", "map-v3.json"] {
            let data = try Data(contentsOf: url.appendingPathComponent("docs/map-format/\(name)"))
            let map = try BuildingMap.from(jsonData: data)
            XCTAssertEqual(map.schemaVersion, MapSchema.current, name)
            XCTAssertTrue(map.nodes.allSatisfy { $0.stairs == nil }, name)
        }
    }

    func testIsEmptyMeansNothingWasRecorded() {
        XCTAssertTrue(StairsInfo().isEmpty)
        XCTAssertFalse(StairsInfo(direction: .up).isEmpty)
        XCTAssertFalse(StairsInfo(railings: .neither).isEmpty)
    }
}
