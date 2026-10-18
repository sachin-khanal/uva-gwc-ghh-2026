//
// File:     Tests/WaypointCoreTests/MapExtrasTests.swift
// Purpose:  Format-3 optional fields: room extents and meshAssets are carried through load/save/merge unchanged and are validated on import
//           (security review 2026-10-18: a hostile extent could fake "You have arrived"; meshAssets must be well-formed).
//
import XCTest
import simd
@testable import WaypointCore

final class MapExtrasTests: XCTestCase {

    private func map(extent: RoomExtent? = nil, kind: NodeKind = .room, assets: [MeshAsset]? = nil) -> BuildingMap {
        let a = MapNode(kind: .corridor, position: [0, 0, 0], segmentId: "seg1")
        let r = MapNode(kind: kind, label: "Room 1", position: [3, 0, 0], segmentId: "seg1", extent: extent)
        return BuildingMap(name: "x", nodes: [a, r], edges: [MapEdge(from: a.id, to: r.id, distance: 3)], meshAssets: assets)
    }
    private let goodExtent = RoomExtent(center: [4, 0, 0], halfExtents: [2, 1.5], yaw: 0.3, areaSquareMeters: 10, heightMeters: 2.6)
    private func asset(_ tweak: (inout MeshAsset) -> Void = { _ in }) -> MeshAsset {
        var a = MeshAsset(segmentId: "seg1", byteCount: 1_000, sha256: String(repeating: "ab", count: 32), boundsMin: [0, 0, 0], boundsMax: [5, 3, 5])
        tweak(&a); return a
    }
    private func validates(_ m: BuildingMap) -> String? {
        do { try MapBundle(map: m).validate(); return nil } catch MapStoreError.rejected(let why) { return why } catch { return "\(error)" }
    }

    func testGoodExtentAndAssetsPass() {
        XCTAssertNil(validates(map(extent: goodExtent, assets: [asset()])))
    }

    func testMeshAssetsRoundTripAndAreAbsentWhenNil() throws {
        let m = map(extent: goodExtent, assets: [asset { $0.storageOwner = UUID() }])
        let back = try BuildingMap.from(jsonData: m.jsonData())
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.nodes[1].extent?.heightMeters, 2.6)
        let plain = String(decoding: try map().jsonData(), as: UTF8.self)
        XCTAssertFalse(plain.contains("meshAssets"), "a map without 3D surfaces must not grow a meshAssets key")
    }

    func testMeshAssetsSurviveAnAppLoadAndSave() throws {
        // The alignment fix: U3's web viewer writes meshAssets; the app must not drop them when it re-saves the map.
        let json = String(decoding: try map(assets: [asset()]).jsonData(), as: UTF8.self)
        let resaved = String(decoding: try BuildingMap.from(jsonData: Data(json.utf8)).jsonData(), as: UTF8.self)
        XCTAssertEqual(json, resaved)
        XCTAssertTrue(resaved.contains("meshAssets"))
    }

    func testMergeUnionsMeshAssetsById() {
        let a = asset(), b = asset()
        let mine = map(assets: [a]), theirs = map(assets: [a, b])
        XCTAssertEqual(Set(mine.merged(with: theirs).meshAssets?.map(\.id) ?? []), [a.id, b.id])
        XCTAssertEqual(mine.merged(with: map()).meshAssets, [a])
        XCTAssertEqual(map().merged(with: theirs).meshAssets?.count, 2)
    }

    func testHostileExtentsAreRejected() {
        let bad: [(String, RoomExtent)] = [
            ("huge", RoomExtent(center: [4, 0, 0], halfExtents: [500, 500], yaw: 0, areaSquareMeters: 100)),
            ("nan", RoomExtent(center: [.nan, 0, 0], halfExtents: [2, 2], yaw: 0, areaSquareMeters: 4)),
            ("infinite yaw", RoomExtent(center: [4, 0, 0], halfExtents: [2, 2], yaw: .infinity, areaSquareMeters: 4)),
            ("zero size", RoomExtent(center: [4, 0, 0], halfExtents: [0, 2], yaw: 0, areaSquareMeters: 1)),
            ("area bigger than the rectangle", RoomExtent(center: [4, 0, 0], halfExtents: [1, 1], yaw: 0, areaSquareMeters: 50)),
            ("zero area", RoomExtent(center: [4, 0, 0], halfExtents: [2, 2], yaw: 0, areaSquareMeters: 0)),
            ("far from its node", RoomExtent(center: [400, 0, 0], halfExtents: [2, 2], yaw: 0, areaSquareMeters: 8)),
            ("bad height", RoomExtent(center: [4, 0, 0], halfExtents: [2, 2], yaw: 0, areaSquareMeters: 8, heightMeters: -1)),
        ]
        for (name, e) in bad { XCTAssertNotNil(validates(map(extent: e)), "should reject: \(name)") }
        XCTAssertNotNil(validates(map(extent: goodExtent, kind: .door)), "only rooms have a floor area")
    }

    func testMalformedMeshAssetsAreRejected() {
        let cases: [(String, MeshAsset)] = [
            ("unknown scan", asset { $0.segmentId = "other" }),
            ("unsafe segment", asset { $0.segmentId = "../x" }),
            ("format", asset { $0.format = "usdz" }),
            ("frame", asset { $0.coordinateFrame = "world" }),
            ("zero bytes", asset { $0.byteCount = 0 }),
            ("too big", asset { $0.byteCount = 40_000_001 }),
            ("short hash", asset { $0.sha256 = "abc" }),
            ("uppercase hash", asset { $0.sha256 = String(repeating: "AB", count: 32) }),
            ("non-hex hash", asset { $0.sha256 = String(repeating: "zz", count: 32) }),
            ("inverted bounds", asset { $0.boundsMin = [9, 0, 0] }),
            ("nan bounds", asset { $0.boundsMax = [.nan, 1, 1] }),
        ]
        for (name, a) in cases { XCTAssertNotNil(validates(map(assets: [a])), "should reject: \(name)") }
        let dup = asset()
        XCTAssertNotNil(validates(map(assets: [dup, dup])), "duplicate id")
        XCTAssertNotNil(validates(map(assets: (0..<101).map { _ in asset() })), "more than 100")
        XCTAssertNotNil(validates(map(assets: [asset { $0.byteCount = 40_000_000 }, asset { $0.byteCount = 40_000_000 }, asset { $0.byteCount = 40_000_000 }])), "total over 80 MB")
    }

    func testWebViewerFixtureStyleMapStillValidates() throws {
        // The format-3 fixture (extent + meshAssets) is the contract shared with web/ and tools/validate_map.py.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let map = try BuildingMap.from(jsonData: Data(contentsOf: url.appendingPathComponent("docs/map-format/map-v3.json")))
        XCTAssertNoThrow(try MapBundle(map: map).validate())
        XCTAssertFalse(map.meshAssets?.isEmpty ?? true, "the v3 fixture must carry a meshAssets entry")
    }

    func testImportRefusesAMergeThatBreaksTheMeshFileLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MapStore(rootURL: root)
        var first = map(assets: (0..<60).map { _ in asset() })
        XCTAssertNil(validates(first))
        _ = try store.importBundle(MapBundle(map: first))
        // a second, individually valid copy of the same building with 60 DIFFERENT files: 120 in total, over the cap of 100
        var second = first
        second.meshAssets = (0..<60).map { _ in asset() }
        XCTAssertNil(validates(second))
        XCTAssertThrowsError(try store.importBundle(MapBundle(map: second))) { error in
            guard case MapStoreError.rejected = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.load(id: first.id).meshAssets?.count, 60, "the stored map must be unchanged")
        first.meshAssets = nil
    }
}
