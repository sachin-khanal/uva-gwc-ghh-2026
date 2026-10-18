//
// File:     Tests/WaypointCoreTests/ObjExportTests.swift
// Purpose:  OBJ export for the web viewer: format, manifest (size, SHA-256, bounds), size budget, local storage and cloud publishing.
//
import XCTest
@testable import WaypointCore

private let userId = "11111111-2222-3333-4444-555555555555"

private func grid(_ n: Int, spacing: Float = 0.05) -> IndexedMesh {
    var m = IndexedMesh()
    for z in 0...n { for x in 0...n { m.vertices.append(SIMD3(Float(x) * spacing, 0, Float(z) * spacing)) } }
    for z in 0..<n { for x in 0..<n {
        let a = UInt32(z * (n + 1) + x), b = a + 1, c = a + UInt32(n + 1), d = c + 1
        m.indices += [a, c, b, b, c, d]
    } }
    return m
}

final class ObjExportTests: XCTestCase {

    func testEncodeIsOneBasedTriangleObj() {
        let mesh = IndexedMesh(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1.5)], indices: [0, 1, 2])
        let text = String(decoding: ObjExport.encode(mesh), as: UTF8.self)
        XCTAssertTrue(text.contains("v 1.0 0.0 0.0\n"))
        XCTAssertTrue(text.contains("v 0.0 0.0 1.5\n"))
        XCTAssertTrue(text.hasSuffix("f 1 2 3\n"))
    }

    func testBadTrianglesAreSkipped() {
        let mesh = IndexedMesh(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)], indices: [0, 1, 2, 0, 0, 1, 0, 1, 9])
        let faces = String(decoding: ObjExport.encode(mesh), as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("f ") }
        XCTAssertEqual(faces.count, 1)
    }

    func testManifestDescribesTheBytes() throws {
        let out = try ObjExport.make(grid(10), segmentId: "seg1")
        XCTAssertEqual(out.asset.byteCount, out.data.count)
        XCTAssertEqual(out.asset.sha256, ObjExport.sha256Hex(out.data))
        XCTAssertEqual(out.asset.sha256.count, 64)
        XCTAssertEqual(out.asset.format, "obj")
        XCTAssertEqual(out.asset.coordinateFrame, "map")
        XCTAssertEqual(out.asset.boundsMin, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(out.asset.boundsMax, SIMD3<Float>(0.5, 0, 0.5))
        XCTAssertNil(out.asset.storageOwner)
    }

    func testKnownSHA256() {
        XCTAssertEqual(ObjExport.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testBigMeshIsSimplifiedToTheBudget() throws {
        let big = grid(300, spacing: 0.01) // 90k vertices, 180k triangles, about 4 MB as text
        let out = try ObjExport.make(big, segmentId: "seg1", maxBytes: 500_000)
        XCTAssertLessThanOrEqual(out.data.count, 500_000)
        XCTAssertGreaterThan(out.triangles, 0)
        XCTAssertLessThan(out.triangles, big.triangleCount)
    }

    func testRefusesEmptyNonFiniteAndUnsafe() {
        XCTAssertThrowsError(try ObjExport.make(IndexedMesh(), segmentId: "seg1")) { XCTAssertEqual($0 as? ObjExport.ExportError, .emptyMesh) }
        XCTAssertThrowsError(try ObjExport.make(grid(2), segmentId: "../x")) { XCTAssertEqual($0 as? ObjExport.ExportError, .unsafeSegment) }
        var bad = grid(2); bad.vertices[0].x = .nan
        XCTAssertThrowsError(try ObjExport.make(bad, segmentId: "seg1"))
    }

    // MARK: storage

    private func storeWithSample() throws -> (MapStore, BuildingMap) {
        let store = MapStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("wp-obj-\(UUID().uuidString)"))
        let map = try loadSampleMap()
        try store.save(map)
        return (store, map)
    }

    func testAttachWritesFileThenManifestAndSurvivesReload() throws {
        let (store, map) = try storeWithSample()
        let seg = map.nodes[0].segmentId
        let out = try ObjExport.make(grid(5), segmentId: seg)
        let saved = try store.attachMesh(out.asset, data: out.data, mapId: map.id)
        XCTAssertEqual(saved.meshAssets?.count, 1)
        XCTAssertEqual(try store.load(id: map.id).meshAssets?.first?.id, out.asset.id)
        XCTAssertEqual(store.loadMesh(mapId: map.id, assetId: out.asset.id), out.data)
    }

    func testAttachRejectsMismatchedBytesAndUnknownSegment() throws {
        let (store, map) = try storeWithSample()
        let out = try ObjExport.make(grid(5), segmentId: map.nodes[0].segmentId)
        XCTAssertThrowsError(try store.attachMesh(out.asset, data: Data("tampered".utf8), mapId: map.id))
        let stray = try ObjExport.make(grid(5), segmentId: "nosuchseg")
        XCTAssertThrowsError(try store.attachMesh(stray.asset, data: stray.data, mapId: map.id))
        XCTAssertNil(try store.load(id: map.id).meshAssets)
        XCTAssertNil(store.loadMesh(mapId: map.id, assetId: stray.asset.id), "nothing is written when validation fails")
    }

    // MARK: cloud

    func testPushUploadsMeshBeforeRowThenListsItWithTheOwner() async throws {
        let (store, map) = try storeWithSample()
        try store.saveWorldMap(Data([1]), mapId: map.id, segmentId: "seg1")
        let out = try ObjExport.make(grid(5), segmentId: map.nodes[0].segmentId)
        try store.attachMesh(out.asset, data: out.data, mapId: map.id)
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: Data(#"{"access_token":"t","refresh_token":"r","expires_in":3600,"user":{"id":"\#(userId)"}}"#.utf8)) : HTTPResponse(status: 200)
        }
        let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "ANON"),
                                    transport: t, sessionStore: InMemorySessionStore())
        try await SyncEngine(client: client, store: store).push(mapId: map.id, share: false)

        let data = t.requests.filter { !$0.url.path.hasPrefix("/auth/") }.map { $0.url.path }
        XCTAssertEqual(data.count, 4)
        XCTAssertTrue(data[0].hasPrefix("/storage/v1/object/worldmaps/"))
        XCTAssertEqual(data[1], "/storage/v1/object/meshes/\(userId)/\(map.id.uuidString.lowercased())/\(out.asset.id.uuidString.lowercased()).obj")
        XCTAssertEqual(data[2], "/rest/v1/rpc/extend_building")
        XCTAssertEqual(data[3], "/rest/v1/rpc/publish_mesh_assets")
        let extend = t.requests.first { $0.url.path == "/rest/v1/rpc/extend_building" }!
        XCTAssertFalse(String(decoding: extend.body ?? Data(), as: UTF8.self).contains("meshAssets"), "the row carries no mesh list")
        let list = t.requests.first { $0.url.path == "/rest/v1/rpc/publish_mesh_assets" }!
        XCTAssertTrue(String(decoding: list.body ?? Data(), as: UTF8.self).contains(userId), "storageOwner is the signed-in user")
    }

    func testPushSkipsAMeshWhoseFileIsMissingOrChanged() async throws {
        let (store, map) = try storeWithSample()
        try store.saveWorldMap(Data([1]), mapId: map.id, segmentId: "seg1")
        let out = try ObjExport.make(grid(5), segmentId: map.nodes[0].segmentId)
        try store.attachMesh(out.asset, data: out.data, mapId: map.id)
        try Data("changed".utf8).write(to: store.meshURL(mapId: map.id, assetId: out.asset.id))
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: Data(#"{"access_token":"t","refresh_token":"r","expires_in":3600,"user":{"id":"\#(userId)"}}"#.utf8)) : HTTPResponse(status: 200)
        }
        let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "ANON"),
                                    transport: t, sessionStore: InMemorySessionStore())
        try await SyncEngine(client: client, store: store).push(mapId: map.id, share: false)
        let paths = t.requests.map { $0.url.path }
        XCTAssertFalse(paths.contains { $0.contains("/meshes/") || $0.hasSuffix("publish_mesh_assets") })
    }

    // MARK: upload must not race the background 3D export (found 2026-10-18: a real floor went up without its mesh)

    private func engine(_ store: MapStore) -> (SyncEngine, MockTransport) {
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: Data(#"{"access_token":"t","refresh_token":"r","expires_in":3600,"user":{"id":"\#(userId)"}}"#.utf8)) : HTTPResponse(status: 200, body: Data("{}".utf8))
        }
        let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "ANON"),
                                    transport: t, sessionStore: InMemorySessionStore())
        return (SyncEngine(client: client, store: store), t)
    }

    func testPushIsRefusedWhileTheMeshIsStillBeingBuiltThenWorks() async throws {
        let (store, map) = try storeWithSample()
        try store.saveWorldMap(Data([1]), mapId: map.id, segmentId: "seg1")
        store.markMeshPending(mapId: map.id)
        XCTAssertTrue(store.isMeshPending(mapId: map.id))
        let (sync, t) = engine(store)
        do { try await sync.push(mapId: map.id, share: false); XCTFail("must refuse while the 3D scan is being built") }
        catch CloudError.meshNotReady { /* expected */ }
        XCTAssertTrue(t.requests.isEmpty, "nothing is sent while waiting")

        let out = try ObjExport.make(grid(5), segmentId: map.nodes[0].segmentId)
        try store.attachMesh(out.asset, data: out.data, mapId: map.id)
        store.clearMeshPending(mapId: map.id)
        XCTAssertFalse(store.isMeshPending(mapId: map.id))
        let report = try await sync.push(mapId: map.id, share: false)
        XCTAssertEqual(report, SyncEngine.PushReport(meshesPublished: 1, meshesSkipped: 0))
    }

    func testStaleMeshMarkerDoesNotBlockUploadsForever() throws {
        let (store, map) = try storeWithSample()
        store.markMeshPending(mapId: map.id)
        XCTAssertTrue(store.isMeshPending(mapId: map.id, maxAge: 600, now: Date()))
        XCTAssertFalse(store.isMeshPending(mapId: map.id, maxAge: 600, now: Date().addingTimeInterval(601)), "a crashed export must not block forever")
        XCTAssertFalse(store.isMeshPending(mapId: UUID()), "no marker, not pending")
    }

    func testPushReportsAMeshItCouldNotSend() async throws {
        let (store, map) = try storeWithSample()
        try store.saveWorldMap(Data([1]), mapId: map.id, segmentId: "seg1")
        let out = try ObjExport.make(grid(5), segmentId: map.nodes[0].segmentId)
        try store.attachMesh(out.asset, data: out.data, mapId: map.id)
        try Data("changed".utf8).write(to: store.meshURL(mapId: map.id, assetId: out.asset.id))
        let (sync, _) = engine(store)
        let report = try await sync.push(mapId: map.id, share: false)
        XCTAssertEqual(report, SyncEngine.PushReport(meshesPublished: 0, meshesSkipped: 1), "the caller can now tell the map went up WITHOUT its 3D scan")
    }
}
