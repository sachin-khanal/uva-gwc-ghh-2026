//
// File:     Tests/WaypointCoreTests/ModelTests.swift
// Purpose:  Locks down the shared data contract: JSON round-trip, the committed sample map still
//           decodes, merge rules, and MapStore/MapBundle persistence. If one of these fails after
//           your change, you altered the contract - tell the team (docs/WORKLOG.md).
//
import XCTest
import simd
@testable import WaypointCore

/// Loads /Samples/rice-hall-sample.json relative to this source file (works under `swift test`).
func loadSampleMap(file: StaticString = #filePath) throws -> BuildingMap {
    var url = URL(fileURLWithPath: "\(file)")
    for _ in 0..<5 { url.deleteLastPathComponent() } // -> repo root
    let data = try Data(contentsOf: url.appendingPathComponent("Samples/rice-hall-sample.json"))
    return try BuildingMap.from(jsonData: data)
}

final class ModelTests: XCTestCase {

    func testSampleMapDecodes() throws {
        let map = try loadSampleMap()
        XCTAssertEqual(map.nodes.count, 9)
        XCTAssertEqual(map.edges.count, 8)
        XCTAssertEqual(map.marker?.name, "waypoint-marker-start")
        XCTAssertEqual(map.destinations.map(\.label).compactMap { $0 }.sorted(),
                       ["Door to lobby", "Room 204", "Room 206", "Stairs up"])
    }

    func testJSONRoundTrip() throws {
        let map = try loadSampleMap()
        let again = try BuildingMap.from(jsonData: try map.jsonData())
        XCTAssertEqual(map, again)
    }

    func testMergeAddsNewAndKeepsExisting() {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [0, 0, -2])
        let c = MapNode(kind: .room, label: "Room 1", position: [1, 0, -2])
        let mine = BuildingMap(name: "mine", version: 3, nodes: [a, b],
                               edges: [MapEdge(from: a.id, to: b.id, distance: 2)])
        var theirsB = b; theirsB.label = "THEIR EDIT" // same id: mine must win
        let theirs = BuildingMap(id: mine.id, name: "theirs", version: 5, nodes: [a, theirsB, c],
                                 edges: [MapEdge(from: b.id, to: a.id, distance: 9), // same pair reversed
                                         MapEdge(from: b.id, to: c.id, distance: 1)])
        let merged = mine.merged(with: theirs)
        XCTAssertEqual(merged.nodes.count, 3)
        XCTAssertNil(merged.node(id: b.id)?.label)          // our copy won
        XCTAssertEqual(merged.edges.count, 2)               // reversed duplicate not added
        XCTAssertEqual(merged.edges.first?.distance, 2)     // our edge kept
        XCTAssertEqual(merged.version, 6)                   // max(3,5)+1
        XCTAssertEqual(merged.name, "mine")
    }

    func testMapStoreSaveLoadListDelete() throws {
        let store = MapStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-test-\(UUID().uuidString)"))
        let map = try loadSampleMap()
        XCTAssertEqual(try store.listMaps().count, 0)
        try store.save(map)
        XCTAssertEqual(try store.load(id: map.id), map)
        XCTAssertEqual(try store.listMaps().count, 1)
        XCTAssertNil(try store.loadWorldMap(mapId: map.id, segmentId: "seg1"))
        try store.saveWorldMap(Data([1, 2, 3]), mapId: map.id, segmentId: "seg1")
        XCTAssertEqual(try store.loadWorldMap(mapId: map.id, segmentId: "seg1"), Data([1, 2, 3]))
        try store.delete(id: map.id)
        XCTAssertThrowsError(try store.load(id: map.id))
    }

    func testValidationRejectsHostileBundles() throws {
        let good = try loadSampleMap()
        XCTAssertNoThrow(try MapBundle(map: good).validate())

        var shortcut = good // edge claims 1 m between nodes that are ~12 m apart
        shortcut.edges.append(MapEdge(from: good.nodes[0].id, to: good.nodes[4].id, distance: 1))
        XCTAssertThrowsError(try MapBundle(map: shortcut).validate())

        var dangling = good
        dangling.edges.append(MapEdge(from: good.nodes[0].id, to: UUID(), distance: 1))
        XCTAssertThrowsError(try MapBundle(map: dangling).validate())

        var nan = good
        nan.nodes[0].position = [.nan, 0, 0]
        XCTAssertThrowsError(try MapBundle(map: nan).validate())

        var dupes = good
        dupes.nodes.append(good.nodes[0])
        XCTAssertThrowsError(try MapBundle(map: dupes).validate())

        let huge = MapBundle(map: good, worldMaps: ["s": Data(count: MapBundle.maxWorldMapBytes + 1)])
        XCTAssertThrowsError(try huge.validate())
    }

    func testImportRefusesNewEdgeBetweenExistingNodes() throws {
        let store = MapStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-sec-\(UUID().uuidString)"))
        let map = try loadSampleMap()
        try store.save(map)

        // Geometrically plausible edge (distance matches positions) but a NEW link between two
        // places we already trust: must be refused when merging.
        var spliced = map
        let from = map.nodes[0], to = map.nodes[2] // corridor nodes 6 m apart, not directly linked
        spliced.edges.append(MapEdge(from: from.id, to: to.id, distance: simd_distance(from.position, to.position)))
        XCTAssertThrowsError(try store.importBundle(MapBundle(map: spliced))) { error in
            guard case MapStoreError.rejected = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(try store.load(id: map.id).edges.count, map.edges.count) // untouched

        // A legitimate extension (new node + edge to it) is still accepted.
        var extended = map
        let newNode = MapNode(kind: .room, label: "Room 208", position: [1.5, 0, -6])
        extended.nodes.append(newNode)
        extended.edges.append(MapEdge(from: map.nodes[2].id, to: newNode.id, distance: 1.5))
        XCTAssertNoThrow(try store.importBundle(MapBundle(map: extended)))
        XCTAssertEqual(try store.load(id: map.id).nodes.count, map.nodes.count + 1)
    }

    func testSegmentIdAlphabet() {
        for ok in ["seg1", "A-b_9", String(repeating: "x", count: 64)] { XCTAssertTrue(SegmentID.isValid(ok), ok) }
        for bad in ["", "../x", "a/b", "..", "a%2e", "a b", "seg1.", "é", String(repeating: "x", count: 65), "a\\b", "seg\n"] {
            XCTAssertFalse(SegmentID.isValid(bad), bad.debugDescription)
        }
    }

    func testValidationRejectsPathTraversalSegments() throws {
        var map = try loadSampleMap()
        map.nodes[0].segmentId = "../../escape"
        XCTAssertThrowsError(try MapBundle(map: map).validate())

        let good = try loadSampleMap()
        XCTAssertThrowsError(try MapBundle(map: good, worldMaps: ["../evil": Data([1])]).validate())
        XCTAssertThrowsError(try MapBundle(map: good, worldMaps: ["a/b": Data([1])]).validate())
    }

    func testStoreNeverWritesOutsideItsFolderForHostileSegments() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("wp-trav-\(UUID().uuidString)")
        let store = MapStore(rootURL: sandbox.appendingPathComponent("Maps"))
        let map = try loadSampleMap()
        try store.save(map)

        XCTAssertThrowsError(try store.saveWorldMap(Data([1]), mapId: map.id, segmentId: "../../../pwned"))
        XCTAssertThrowsError(try store.loadWorldMap(mapId: map.id, segmentId: "../map"))
        // An import carrying a hostile world-map key is refused wholesale and writes nothing.
        let hostile = MapBundle(map: map, worldMaps: ["../../pwned": Data([6, 6, 6])])
        XCTAssertThrowsError(try store.importBundle(hostile))

        let files = (FileManager.default.enumerator(atPath: sandbox.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(files.contains { $0.contains("pwned") }, "nothing may be created from a hostile segment id: \(files)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.deletingLastPathComponent().appendingPathComponent("pwned.arworldmap").path))
    }

    func testBundleImportCreatesAndMerges() throws {
        let sender = MapStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-send-\(UUID().uuidString)"))
        let receiver = MapStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-recv-\(UUID().uuidString)"))
        let map = try loadSampleMap()
        try sender.save(map)
        try sender.saveWorldMap(Data([9, 9]), mapId: map.id, segmentId: "seg1")

        let bundleURL = try sender.writeBundleFile(id: map.id)
        let imported = try receiver.importBundle(data: Data(contentsOf: bundleURL))
        XCTAssertEqual(imported.id, map.id)
        XCTAssertEqual(try receiver.loadWorldMap(mapId: map.id, segmentId: "seg1"), Data([9, 9]))

        // Importing again must merge (version bumps) and must not duplicate nodes.
        let again = try receiver.importBundle(data: Data(contentsOf: bundleURL))
        XCTAssertEqual(again.nodes.count, map.nodes.count)
        XCTAssertEqual(again.version, map.version + 1)
    }
}
