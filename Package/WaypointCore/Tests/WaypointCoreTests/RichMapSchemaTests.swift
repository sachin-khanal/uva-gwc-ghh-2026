// File: RichMapSchemaTests.swift
// Owner: D / U3 (schema 3 contract)
// Purpose: Legacy migration, room geometry, OBJ integrity, and cloud asset publication.
// Frames: Synthetic map-frame meters; no hardware assertions.
// Status: Implemented; requires make test on a Mac. UNVERIFIED ON DEVICE.
import Foundation
import XCTest
@testable import WaypointCore

final class RichMapSchemaTests: XCTestCase {
    private func fixture(_ version: Int) throws -> BuildingMap {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try BuildingMap.from(jsonData: Data(contentsOf: root.appendingPathComponent("docs/map-format/map-v\(version).json")))
    }

    func testEveryDocumentedFormatMigratesAndRoundTrips() throws {
        for version in 1...3 {
            let map = try fixture(version)
            XCTAssertEqual(map.schemaVersion, 3)
            try MapBundle(map: map).validate()
            XCTAssertEqual(try BuildingMap.from(jsonData: map.jsonData()), map)
            if version < 3 { XCTAssertTrue(map.meshAssets.isEmpty); XCTAssertTrue(map.nodes.allSatisfy { $0.extent == nil }) }
        }
    }

    func testFutureAndInvalidFormatAreRejected() throws {
        let map = try fixture(3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: map.jsonData()) as? [String: Any])
        for version in [0, 4] {
            json["schemaVersion"] = version
            XCTAssertThrowsError(try BuildingMap.from(jsonData: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testRoomExtentValidationAndEnrichmentPreserveExistingGeometry() throws {
        let rich = try fixture(3)
        var old = rich
        for i in old.nodes.indices { old.nodes[i].extent = nil }
        XCTAssertEqual(old.merged(with: rich).nodes, rich.nodes)
        XCTAssertEqual(rich.merged(with: old).nodes, rich.nodes)
        var bad = rich
        let i = try XCTUnwrap(bad.nodes.firstIndex { $0.extent != nil })
        bad.nodes[i].extent?.halfExtents.x = -1
        XCTAssertThrowsError(try MapBundle(map: bad).validate())
        bad = rich
        bad.nodes[i].extent?.areaSquareMeters = .infinity
        XCTAssertThrowsError(try MapBundle(map: bad).validate())
    }

    func testOBJBytesManifestAndBundleIntegrity() throws {
        var map = try fixture(3)
        let (asset, bytes) = try OBJEncoder.encode(vertices: [[0,0,0],[1,0,0],[0,1,0]],
            triangles: [[0,1,2]], segmentId: "seg1")
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("f 1 2 3"))
        XCTAssertEqual(asset.byteCount, bytes.count)
        map.meshAssets = [asset]
        let bundle = MapBundle(map: map, meshFiles: [asset.id.uuidString: bytes])
        try bundle.validate()
        let copy = try JSONDecoder().decode(MapBundle.self, from: JSONEncoder().encode(bundle))
        try copy.validate()
        XCTAssertThrowsError(try MapBundle(map: map, meshFiles: [asset.id.uuidString: Data([0])]).validate())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MapStore(rootURL: folder)
        _ = try store.importBundle(bundle)
        XCTAssertEqual(try store.makeBundle(id: map.id).meshFiles?[asset.id.uuidString], bytes)
    }

    func testInvalidMeshIndicesAndBoundsAreRejected() throws {
        XCTAssertThrowsError(try OBJEncoder.encode(vertices: [[0,0,0]], triangles: [[0,1,2]], segmentId: "seg1"))
        XCTAssertThrowsError(try OBJEncoder.encode(vertices: [[.nan,0,0]], triangles: [[0,0,0]], segmentId: "seg1"))
        var map = try fixture(3)
        var asset = MeshAsset(segmentId: "seg1", byteCount: 1, sha256: String(repeating: "0", count: 64),
                              boundsMin: [1,0,0], boundsMax: [0,1,1])
        map.meshAssets = [asset]
        XCTAssertThrowsError(try MapBundle(map: map).validate())
        asset.boundsMin = [0,0,0]; asset.byteCount = Int.max
        map.meshAssets = [asset]
        XCTAssertThrowsError(try MapBundle(map: map).validate())
    }

    func testImportNeverOverwritesStoredFutureFormat() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MapStore(rootURL: folder)
        let map = try fixture(3)
        try store.save(map)
        let path = store.directory(for: map.id).appendingPathComponent("map.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: map.jsonData()) as? [String: Any])
        json["schemaVersion"] = 4
        let futureBytes = try JSONSerialization.data(withJSONObject: json)
        try futureBytes.write(to: path)
        XCTAssertThrowsError(try store.importBundle(MapBundle(map: map)))
        XCTAssertEqual(try Data(contentsOf: path), futureBytes)
    }

    func testRoomExtractionNeedsEnclosingWalls() {
        var walls: [SIMD2<Float>] = []
        for i in -30...30 {
            let v = Float(i) / 10
            walls += [[-3,v],[3,v],[v,-3],[v,3]]
        }
        let room = RoomExtractor.extract(seed: [0,1.4,0], wallPoints: walls, floorY: 0, maxRadius: 5)
        XCTAssertNotNil(room)
        XCTAssertNil(RoomExtractor.extract(seed: [0,1.4,0], wallPoints: [], maxRadius: 5))
        XCTAssertNil(RoomExtractor.extract(seed: [.nan,0,0], wallPoints: walls))
    }
}
