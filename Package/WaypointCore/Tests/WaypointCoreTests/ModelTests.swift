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

// MARK: - Deleting a recording (added 2026-10-17)

final class MapDeletionTests: XCTestCase {

    private func tempStore() -> (MapStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wp-del-\(UUID().uuidString)")
        return (MapStore(rootURL: root), root)
    }

    /// Deleting must take the ARWorldMap binaries with it, not just map.json. They are by far the
    /// biggest files, so leaving them behind would quietly fill the phone.
    func testDeleteRemovesTheWorldMapsToo() throws {
        let (store, root) = tempStore()
        var map = BuildingMap(name: "Rice Hall")
        map.nodes = [MapNode(kind: .corridor, position: .zero)]
        try store.save(map)
        try store.saveWorldMap(Data(repeating: 7, count: 2048), mapId: map.id, segmentId: "seg1")
        try store.saveWorldMap(Data(repeating: 9, count: 2048), mapId: map.id, segmentId: "seg2")
        XCTAssertNotNil(try store.loadWorldMap(mapId: map.id, segmentId: "seg1"))

        try store.delete(id: map.id)

        XCTAssertTrue(try store.listMaps().isEmpty)
        XCTAssertNil(try store.loadWorldMap(mapId: map.id, segmentId: "seg1"))
        XCTAssertNil(try store.loadWorldMap(mapId: map.id, segmentId: "seg2"))
        let leftovers = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(leftovers.contains { $0.contains(map.id.uuidString) },
                       "nothing belonging to the map may survive: \(leftovers)")
    }

    func testDeletingOneMapLeavesTheOthersAlone() throws {
        let (store, _) = tempStore()
        let keep = BuildingMap(name: "Keep", nodes: [MapNode(kind: .corridor, position: .zero)])
        let drop = BuildingMap(name: "Drop", nodes: [MapNode(kind: .corridor, position: .zero)])
        try store.save(keep)
        try store.save(drop)
        try store.saveWorldMap(Data([1]), mapId: keep.id, segmentId: "seg1")

        try store.delete(id: drop.id)

        XCTAssertEqual(try store.listMaps().map(\.name), ["Keep"])
        XCTAssertNotNil(try store.loadWorldMap(mapId: keep.id, segmentId: "seg1"))
    }

    /// Deleting something that is not there is not an error: two taps on Delete, or a map already
    /// removed on another screen, must not throw at the user.
    func testDeletingAnUnknownMapIsHarmless() throws {
        let (store, _) = tempStore()
        XCTAssertNoThrow(try store.delete(id: UUID()))
        let map = BuildingMap(name: "x", nodes: [MapNode(kind: .corridor, position: .zero)])
        try store.save(map)
        XCTAssertNoThrow(try store.delete(id: map.id))
        XCTAssertNoThrow(try store.delete(id: map.id), "second delete is a no-op")
    }

    func testADeletedMapCanBeSavedAgain() throws {
        let (store, _) = tempStore()
        let map = BuildingMap(name: "Rice Hall", nodes: [MapNode(kind: .corridor, position: .zero)])
        try store.save(map)
        try store.delete(id: map.id)
        XCTAssertNoThrow(try store.save(map), "re-importing the same map id must still work")
        XCTAssertEqual(try store.listMaps().count, 1)
    }
}

// MARK: - Keyframes: recognising a place to relocalize faster (2026-10-17)

final class KeyframeTests: XCTestCase {

    /// Descriptors are opaque bytes here; the test supplies its own distance, exactly as Vision does
    /// in the app. One byte per descriptor keeps the arithmetic obvious.
    private func frame(_ byte: UInt8, at x: Float, _ z: Float, yaw: Float = 0) -> Keyframe {
        Keyframe(position: SIMD3(x, 0, z), yaw: yaw, descriptor: Data([byte]))
    }

    private func absoluteDistance(_ a: Data, _ b: Data) -> Float? {
        guard let x = a.first, let y = b.first else { return nil }
        return abs(Float(x) - Float(y))
    }

    func testFindsTheClosestLookingPlace() throws {
        let index = KeyframeIndex(keyframes: [frame(10, at: 0, 0), frame(50, at: 20, 0), frame(90, at: 40, 0)])
        let match = try XCTUnwrap(index.best(matching: Data([52]), distance: absoluteDistance))
        XCTAssertEqual(match.keyframe.position.x, 20)
        XCTAssertEqual(match.distance, 2, accuracy: 1e-5)
    }

    /// The safety rule. A corridor photographs much the same from several places; if two DIFFERENT
    /// places match nearly as well, we must say "I don't know" rather than hand a blind user a
    /// confident wrong position.
    func testRefusesToGuessBetweenTwoPlacesThatLookAlike() {
        let index = KeyframeIndex(keyframes: [frame(50, at: 0, 0), frame(52, at: 30, 0)])
        XCTAssertNil(index.best(matching: Data([51]), distance: absoluteDistance),
                     "both ends of the corridor look the same: refuse")
    }

    /// Neighbouring keyframes of the SAME spot naturally score alike and must not count as ambiguity.
    func testNeighbouringKeyframesOfTheSameSpotDoNotBlockAMatch() throws {
        let index = KeyframeIndex(keyframes: [frame(50, at: 0, 0), frame(52, at: 1.5, 0)])
        let match = try XCTUnwrap(index.best(matching: Data([50]), distance: absoluteDistance),
                                  "1.5 m apart is the same place")
        XCTAssertEqual(match.keyframe.position.x, 0)
    }

    func testNothingCloseEnoughIsNoMatch() {
        let index = KeyframeIndex(keyframes: [frame(10, at: 0, 0)])
        XCTAssertNil(index.best(matching: Data([200]), maxDistance: 18, distance: absoluteDistance))
    }

    func testUncomparableDescriptorsAreSkippedNotCrashed() throws {
        let index = KeyframeIndex(keyframes: [Keyframe(position: .zero, yaw: 0, descriptor: Data()),
                                              frame(10, at: 20, 0)])
        let match = try XCTUnwrap(index.best(matching: Data([11]), distance: absoluteDistance))
        XCTAssertEqual(match.keyframe.position.x, 20)
    }

    // MARK: Pose recovery

    /// Standing where the volunteer stood, facing the same way, the transform must put map points
    /// back where they belong.
    func testPoseRecoveryRoundTrips() {
        let keyframe = Keyframe(position: SIMD3(3, 0, -4), yaw: .pi / 2, descriptor: Data([1]))
        // The user is at an arbitrary place in the ARKit world frame, facing the same way.
        let cameraWorld = Geometry.translationMatrix(SIMD3(10, 0, 7)) * Geometry.rotationY(.pi / 2)
        let mapToWorld = keyframe.mapToWorldTransform(cameraWorld: cameraWorld)
        let recovered = Geometry.transformPoint(mapToWorld, keyframe.position)
        XCTAssertEqual(recovered.x, 10, accuracy: 1e-4)
        XCTAssertEqual(recovered.z, 7, accuracy: 1e-4)
    }

    // MARK: Spacing

    func testKeyframesAreNotRecordedOnTopOfEachOther() {
        let index = KeyframeIndex(keyframes: [frame(1, at: 0, 0)])
        XCTAssertFalse(index.shouldRecord(at: SIMD3(1, 0, 0), spacing: 2.5))
        XCTAssertTrue(index.shouldRecord(at: SIMD3(3, 0, 0), spacing: 2.5))
    }

    // MARK: Format compatibility - the thing that nearly broke every existing map

    /// A map written before keyframes existed has no `keyframes` key at all. Swift's synthesized
    /// decoder REQUIRES a key even when the property has a default, so this must stay covered.
    func testMapsWithoutKeyframesStillDecode() throws {
        let json = """
        {"id":"5A3E0000-0000-4000-8000-0000000000D1","name":"old","version":1,
         "nodes":[],"edges":[]}
        """
        let map = try BuildingMap.from(jsonData: Data(json.utf8))
        XCTAssertTrue(map.keyframes.isEmpty)
        XCTAssertEqual(map.name, "old")
    }

    func testKeyframesSurviveARoundTrip() throws {
        let map = BuildingMap(name: "t", nodes: [], edges: [],
                              keyframes: [Keyframe(position: SIMD3(1, 0, 2), yaw: 0.5, descriptor: Data([7, 8, 9]))])
        let decoded = try BuildingMap.from(jsonData: try map.jsonData())
        XCTAssertEqual(decoded.keyframes, map.keyframes)
    }
}

// MARK: - Keyframes survive a merge, and hostile ones are refused (found 2026-10-17)

final class KeyframeMergeAndValidationTests: XCTestCase {

    private func keyframe(_ byte: UInt8, at x: Float = 0) -> Keyframe {
        Keyframe(position: SIMD3(x, 0, 0), yaw: 0, descriptor: Data([byte]))
    }

    /// The bug: `merged(with:)` handled nodes, edges and marker but not keyframes, so an extension
    /// scan - or any import into a map already on disk - silently discarded the incoming ones.
    func testMergingKeepsKeyframesFromBothSides() {
        let mine = BuildingMap(name: "m", nodes: [], edges: [], keyframes: [keyframe(1, at: 0)])
        let theirs = BuildingMap(id: mine.id, name: "m", nodes: [], edges: [],
                                 keyframes: [keyframe(2, at: 5)])
        let merged = mine.merged(with: theirs)
        XCTAssertEqual(merged.keyframes.count, 2, "both sides' fingerprints survive")
    }

    func testMergingDoesNotDuplicateTheSameKeyframe() {
        let shared = keyframe(1)
        let mine = BuildingMap(name: "m", nodes: [], edges: [], keyframes: [shared])
        let theirs = BuildingMap(id: mine.id, name: "m", nodes: [], edges: [], keyframes: [shared])
        XCTAssertEqual(mine.merged(with: theirs).keyframes.count, 1)
    }

    // MARK: Validation

    private func bundle(_ keyframes: [Keyframe]) -> MapBundle {
        MapBundle(map: BuildingMap(name: "m",
                                   nodes: [MapNode(kind: .corridor, position: .zero)],
                                   edges: [], keyframes: keyframes))
    }

    /// A non-finite pose would flow straight into `mapToWorld` and put the user nowhere.
    func testAKeyframeWithANonFinitePoseIsRefused() {
        XCTAssertThrowsError(try bundle([Keyframe(position: SIMD3(.nan, 0, 0), yaw: 0,
                                                  descriptor: Data([1]))]).validate())
        XCTAssertThrowsError(try bundle([Keyframe(position: .zero, yaw: .infinity,
                                                  descriptor: Data([1]))]).validate())
    }

    func testAnOversizedDescriptorIsRefused() {
        let huge = Data(repeating: 0, count: MapBundle.maxKeyframeDescriptorBytes + 1)
        XCTAssertThrowsError(try bundle([Keyframe(position: .zero, yaw: 0, descriptor: huge)]).validate())
    }

    func testTooManyKeyframesAreRefused() {
        let many = (0...MapBundle.maxKeyframes).map { _ in keyframe(1) }
        XCTAssertThrowsError(try bundle(many).validate())
    }

    func testAReasonableKeyframePasses() {
        XCTAssertNoThrow(try bundle([keyframe(1)]).validate())
        XCTAssertNoThrow(try bundle([]).validate())
    }
}
